import Foundation
import SwiftMkRenderCore

struct RenderContext: Decodable {
    let values: [String: String]
}

@main
enum SwiftMkRenderCLI {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("swift-mk-render: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 2 else {
            throw CLIError.usage
        }

        let templatePath = arguments[1]
        let inputData = FileHandle.standardInput.readDataToEndOfFile()
        let context = try JSONDecoder().decode(RenderContext.self, from: inputData)
        let templateText = try String(contentsOfFile: templatePath, encoding: .utf8)
        let renderedText = try TemplateRenderer.render(
            templateText: templateText,
            values: context.values
        )
        FileHandle.standardOutput.write(Data(renderedText.utf8))
    }
}

private enum CLIError: Error, CustomStringConvertible {
    case usage

    var description: String {
        switch self {
        case .usage:
            return "usage: swift-mk-render <template-path>"
        }
    }
}
