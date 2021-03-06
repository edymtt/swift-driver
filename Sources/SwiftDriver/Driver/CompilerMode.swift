//===--------------- CompilerMode.swift - Swift Compiler Mode -------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
/// The mode of the compiler.
@_spi(Testing) public enum CompilerMode: Equatable {
  /// A standard compilation, using multiple frontend invocations and -primary-file.
  case standardCompile

  /// A batch compilation, using multiple frontend invocations with
  /// multiple -primary-file options per invocation.
  case batchCompile(BatchModeInfo)

  /// A compilation using a single frontend invocation without -primary-file.
  case singleCompile

  /// Invoke the REPL.
  case repl

  /// Compile and execute the inputs immediately.
  case immediate

  /// Compile a Clang module (.pcm).
  case compilePCM
}

/// Information about batch mode, which is used to determine how to form
/// the batches of jobs.
@_spi(Testing) public struct BatchModeInfo: Equatable {
  let seed: Int?
  let count: Int?
  let sizeLimit: Int?
}

extension CompilerMode {
  /// Whether this compilation mode uses -primary-file to specify its inputs.
  public var usesPrimaryFileInputs: Bool {
    switch self {
    case .immediate, .repl, .singleCompile, .compilePCM:
      return false

    case .standardCompile, .batchCompile:
      return true
    }
  }

  /// Whether this compilation mode compiles the whole target in one job.
  public var isSingleCompilation: Bool {
    switch self {
    case .immediate, .repl, .standardCompile, .batchCompile:
      return false

    case .singleCompile, .compilePCM:
      return true
    }
  }

  public var isStandardCompilationForPlanning: Bool {
    switch self {
      case .immediate, .repl, .compilePCM:
        return false
      case .batchCompile, .standardCompile, .singleCompile:
        return true
    }
  }

  // Whether this compilation mode supports the use of bridging pre-compiled
  // headers.
  public var supportsBridgingPCH: Bool {
    switch self {
    case .batchCompile, .singleCompile, .standardCompile, .compilePCM:
      return true
    case .immediate, .repl:
      return false
    }
  }
}

extension CompilerMode: CustomStringConvertible {
    public var description: String {
      switch self {
      case .standardCompile:
        return "standard compilation"
      case .batchCompile:
        return "batch compilation"
      case .singleCompile:
        return "whole module optimization"
      case .repl:
        return "read-eval-print-loop compilation"
      case .immediate:
        return "immediate compilation"
      case .compilePCM:
        return "compile Clang module (.pcm)"
      }
  }
}
