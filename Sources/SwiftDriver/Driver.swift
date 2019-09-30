import TSCBasic
import TSCUtility

/// The Swift driver.
public struct Driver {

  enum Error: Swift.Error {
    case invalidDriverName(String)
    case invalidInput(String)
  }

  /// The kind of driver.
  public let driverKind: DriverKind

  /// The option table we're using.
  let optionTable: OptionTable

  /// The set of parsed options.
  var parsedOptions: ParsedOptions

  /// The working directory for the driver, if there is one.
  public let workingDirectory: AbsolutePath?

  /// The set of input files
  public let inputFiles: [InputFile]

  /// The type of the primary output generated by the compiler.
  public let compilerOutputType: FileType?

  /// The type of the primary output generated by the linker.
  public let linkerOutputType: LinkOutputType?

  /// Create the driver with the given arguments.
  public init(args: [String]) throws {
    // FIXME: Determine if we should run as subcommand.

    self.driverKind = try Self.determineDriverKind(args: args)
    self.optionTable = OptionTable()
    self.parsedOptions = try optionTable.parse(Array(args.dropFirst()))

    // Compute the working directory.
    workingDirectory = try parsedOptions.getLastArgument(.working_directory).map { workingDirectoryArg in
      let cwd = localFileSystem.currentWorkingDirectory
      return try cwd.map{ AbsolutePath(workingDirectoryArg.asSingle, relativeTo: $0) } ?? AbsolutePath(validating: workingDirectoryArg.asSingle)
    }

    // Apply the working directory to the parsed options.
    if let workingDirectory = self.workingDirectory {
      try Self.applyWorkingDirectory(workingDirectory, to: &self.parsedOptions)
    }

    // Classify and collect all of the input files.
    self.inputFiles = try Self.collectInputFiles(&self.parsedOptions)

    // Figure out the primary outputs from the driver.
    (self.compilerOutputType, self.linkerOutputType) = Self.determinePrimaryOutputs(&parsedOptions, driverKind: driverKind)
  }

  /// Determine the driver kind based on the command-line arguments.
  public static func determineDriverKind(
    args: [String],
    cwd: AbsolutePath? = localFileSystem.currentWorkingDirectory
  ) throws -> DriverKind {
    // Get the basename of the driver executable.
    let execPath = try cwd.map{ AbsolutePath(args[0], relativeTo: $0) } ?? AbsolutePath(validating: args[0])
    var driverName = execPath.basename

    // Determine driver kind based on the first argument.
    if args.count > 1 {
      let driverModeOption = "--driver-mode="
      if args[1].starts(with: driverModeOption) {
        driverName = String(args[1].dropFirst(driverModeOption.count))
      } else if args[1] == "-frontend" {
        return .frontend
      } else if args[1] == "-modulewrap" {
        return .moduleWrap
      }
    }

    switch driverName {
    case "swift":
      return .interactive
    case "swiftc":
      return .batch
    case "swift-autolink-extract":
      return .autolinkExtract
    case "swift-indent":
      return .indent
    default:
      throw Error.invalidDriverName(driverName)
    }
  }

  /// Compute the compiler mode based on the options.
  public mutating func computeCompilerMode() -> CompilerMode {
    // Some output flags affect the compiler mode.
    if let outputOption = parsedOptions.getLast(in: .modes) {
      switch outputOption.option! {
      case .emit_pch, .emit_imported_modules, .index_file:
        return .singleCompile

      case .repl, .deprecated_integrated_repl, .lldb_repl:
        return .repl

      default:
        // Output flag doesn't determine the compiler mode.
        break
      }
    }

    if driverKind == .interactive {
      return parsedOptions.hasAnyInput ? .immediate : .repl
    }

    let requiresSingleCompile = parsedOptions.contains(.whole_module_optimization)

    // FIXME: Handle -enable-batch-mode and -disable-batch-mode flags.

    if requiresSingleCompile {
      return .singleCompile
    }

    return .standardCompile
  }

  /// Run the driver.
  public mutating func run() throws {
    // We just need to invoke the corresponding tool if the kind isn't Swift compiler.
    guard driverKind.isSwiftCompiler else {
      let swiftCompiler = try getSwiftCompilerPath()
      return try exec(path: swiftCompiler.pathString, args: ["swift"] + parsedOptions.commandLine)
    }

    if parsedOptions.contains(.help) || parsedOptions.contains(.help_hidden) {
      optionTable.printHelp(usage: driverKind.usage, title: driverKind.title, includeHidden: parsedOptions.contains(.help_hidden))
      return
    }

    switch computeCompilerMode() {
    case .standardCompile:
      break
    case .singleCompile:
      break
    case .repl:
      break
    case .immediate:
      break
    }
  }

  /// Returns the path to the Swift binary.
  func getSwiftCompilerPath() throws -> AbsolutePath {
    // FIXME: This is very preliminary. Need to figure out how to get the actual Swift executable path.
    let path = try Process.checkNonZeroExit(
      arguments: ["xcrun", "-sdk", "macosx", "--find", "swift"]).spm_chomp()
    return AbsolutePath(path)
  }
}

/// Input and output file handling.
extension Driver {
  /// Apply the given working directory to all paths in the parsed options.
  private static func applyWorkingDirectory(_ workingDirectory: AbsolutePath,
                                            to parsedOptions: inout ParsedOptions) throws {
    parsedOptions.forEachModifying { parsedOption in
      // Only translate input arguments and options whose arguments are paths.
      if let option = parsedOption.option {
        if !option.attributes.contains(.argumentIsPath) { return }
      } else if !parsedOption.isInput {
        return
      }

      let translatedArgument: ParsedOption.Argument
      switch parsedOption.argument {
      case .none:
        return

      case .single(let arg):
        if arg == "-" {
          translatedArgument = parsedOption.argument
        } else {
          translatedArgument = .single(AbsolutePath(arg, relativeTo: workingDirectory).pathString)
        }

      case .multiple(let args):
        translatedArgument = .multiple(args.map { arg in
          AbsolutePath(arg, relativeTo: workingDirectory).pathString
        })
      }

      parsedOption = .init(option: parsedOption.option, argument: translatedArgument)
    }
  }

  /// Collect all of the input files from the parsed options, translating them into input files.
  private static func collectInputFiles(_ parsedOptions: inout ParsedOptions) throws -> [InputFile] {
    return try parsedOptions.allInputs.map { input in
      // Standard input is assumed to be Swift code.
      if input == "-" {
        return InputFile(file: .standardInput, type: .swift)
      }

      // Resolve the input file.
      let file: File
      let fileExtension: String
      if let absolute = try? AbsolutePath(validating: input) {
        file = .absolute(absolute)
        fileExtension = absolute.extension ?? ""
      } else {
        let relative = try RelativePath(validating: input)
        fileExtension = relative.extension ?? ""
        file = .relative(relative)
      }

      // Determine the type of the input file based on its extension.
      // If we don't recognize the extension, treat it as an object file.
      // FIXME: The object-file default is carried over from the existing
      // driver, but seems odd.
      let fileType = FileType(rawValue: fileExtension) ?? FileType.object

      return InputFile(file: file, type: fileType)
    }
  }

  /// Determine the primary compiler and linker output kinds.
  private static func determinePrimaryOutputs(
    _ parsedOptions: inout ParsedOptions,
    driverKind: DriverKind
  ) -> (FileType?, LinkOutputType?) {
    // By default, the driver does not link its output. However, this will be updated below.
    var compilerOutputType: FileType? = (driverKind == .interactive ? nil : .object)
    var linkerOutputType: LinkOutputType? = nil

    if let outputOption = parsedOptions.getLast(in: .modes) {
      switch outputOption.option! {
      case .emit_executable:
        // FIXME: Check for -static, which is not allowed per
        // diag::error_static_emit_executable_disallowed
        linkerOutputType = .executable
        compilerOutputType = .object

      case .emit_library:
        linkerOutputType = parsedOptions.hasArgument(.static) ? .staticLibrary : .dynamicLibrary
        compilerOutputType = .object

      case .emit_object:
        compilerOutputType = .object

      case .emit_assembly:
        compilerOutputType = .assembly

      case .emit_sil:
        compilerOutputType = .sil

      case .emit_silgen:
        compilerOutputType = .raw_sil

      case .emit_sib:
        compilerOutputType = .sib

      case .emit_sibgen:
        compilerOutputType = .raw_sib

      case .emit_ir:
        compilerOutputType = .llvmIR

      case .emit_bc:
        compilerOutputType = .llvmBitcode

      case .dump_ast:
        compilerOutputType = .ast

      case .emit_pch:
        compilerOutputType = .pch

      case .emit_imported_modules:
        compilerOutputType = .importedModules

      case .index_file:
        compilerOutputType = .indexData

      case .update_code:
        compilerOutputType = .remap
        linkerOutputType = nil

      case .parse, .resolve_imports, .typecheck, .dump_parse, .emit_syntax,
           .print_ast, .dump_type_refinement_contexts, .dump_scope_maps,
           .dump_interface_hash, .dump_type_info, .verify_debug_info:
        compilerOutputType = nil

      case .i:
        // FIXME: diagnose this
        break

      case .repl, .deprecated_integrated_repl, .lldb_repl:
        compilerOutputType = nil

      default:
        fatalError("unhandled output mode option")
      }
    } else if (parsedOptions.hasArgument(.emit_module, .emit_module_path)) {
      compilerOutputType = .swiftModule
    } else if (driverKind != .interactive) {
      linkerOutputType = .executable
    }

    return (compilerOutputType, linkerOutputType)
  }
}
