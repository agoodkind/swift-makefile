//
//  Toolchain+Coverage.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-01.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - Toolchain coverage

extension Toolchain {
  private static let macOSCoverageDestination = "platform=macOS"
  private static let iOSSimulatorCoverageDestination = "generic/platform=iOS Simulator"
  private static let macCatalystCoverageDestination =
    "generic/platform=macOS,variant=Mac Catalyst"

  /// The xcodebuild `-destination` string for a coverage build of the given platform.
  /// The dead-code coverage build derives one entry per (scheme, platform) from the
  /// generated project, and each platform maps to a fixed destination.
  public static func coverageDestination(for platform: CoveragePlatform) -> String {
    switch platform {
    case .macosx:
      return macOSCoverageDestination
    case .iphoneos, .iphonesimulator:
      return iOSSimulatorCoverageDestination
    case .maccatalyst:
      return macCatalystCoverageDestination
    }
  }
}
