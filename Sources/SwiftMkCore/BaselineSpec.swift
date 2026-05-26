import Foundation

/// The finding stream and baseline file a gate or count compares, together with
/// the label, exclude pattern, and scope pattern that select rows from each.
public struct BaselineSpec: Sendable {
    public let findingsPath: String
    public let baselinePath: String
    public let label: String
    public let excludePattern: String
    public let scopePattern: String

    public init(
        findingsPath: String,
        baselinePath: String,
        label: String,
        excludePattern: String = "",
        scopePattern: String = ""
    ) {
        self.findingsPath = findingsPath
        self.baselinePath = baselinePath
        self.label = label
        self.excludePattern = excludePattern
        self.scopePattern = scopePattern
    }
}

/// Inputs for rewriting a baseline file from the current findings.
public struct BaselineWriteRequest: Sendable {
    public let title: String
    public let oldBaselinePath: String
    public let findingsPath: String
    public let label: String
    public let outputPath: String
    public let mode: BaselineMode
    public let scopePattern: String
    public let now: String

    public init(
        title: String,
        oldBaselinePath: String,
        findingsPath: String,
        label: String,
        outputPath: String,
        mode: BaselineMode,
        scopePattern: String,
        now: String
    ) {
        self.title = title
        self.oldBaselinePath = oldBaselinePath
        self.findingsPath = findingsPath
        self.label = label
        self.outputPath = outputPath
        self.mode = mode
        self.scopePattern = scopePattern
        self.now = now
    }
}
