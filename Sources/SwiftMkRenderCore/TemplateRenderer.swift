//
//  TemplateRenderer.swift
//  SwiftMkRenderCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-24.
//  Copyright © 2026, all rights reserved.
//

import Foundation

// MARK: - TemplateRendererError

public enum TemplateRendererError: Error, CustomStringConvertible, Equatable {
    case missingValue(String)

    public var description: String {
        switch self {
        case .missingValue(let key):
            return "missing template value for \(key)"
        }
    }
}

// MARK: - TemplateRenderer

public enum TemplateRenderer {
    public static func render(templateText: String, values: [String: String]) throws -> String {
        let pattern = #"\[\[([A-Z0-9_]+)\]\]"#
        let expression = try NSRegularExpression(pattern: pattern)
        let fullRange = NSRange(templateText.startIndex..<templateText.endIndex, in: templateText)
        let matches = expression.matches(in: templateText, range: fullRange)
        var renderedText = templateText

        for match in matches.reversed() {
            guard let keyRange = Range(match.range(at: 1), in: renderedText) else {
                continue
            }
            let key = String(renderedText[keyRange])
            guard let replacement = values[key] else {
                throw TemplateRendererError.missingValue(key)
            }
            guard let replacementRange = Range(match.range(at: 0), in: renderedText) else {
                continue
            }
            renderedText.replaceSubrange(replacementRange, with: replacement)
        }

        return renderedText
    }
}
