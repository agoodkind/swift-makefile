//
//  TemplateRendererTests.swift
//  SwiftMkRenderCoreTests
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-24.
//  Copyright © 2026, all rights reserved.
//

import Testing

@testable import SwiftMkRenderCore

// MARK: - TemplateRenderer Tests

@Test
func renderReplacesEveryPlaceholder() throws {
  let renderedText = try TemplateRenderer.render(
    templateText: "BUILD=[[BUILD_CMD]]\nTEST=[[TEST_CMD]]\n",
    values: [
      "BUILD_CMD": "swift build",
      "TEST_CMD": "swift test",
    ]
  )

  #expect(renderedText == "BUILD=swift build\nTEST=swift test\n")
}

@Test
func renderFailsWhenValueIsMissing() throws {
  #expect(throws: TemplateRendererError.missingValue("BUILD_CMD")) {
    try TemplateRenderer.render(
      templateText: "BUILD=[[BUILD_CMD]]",
      values: [:]
    )
  }
}
