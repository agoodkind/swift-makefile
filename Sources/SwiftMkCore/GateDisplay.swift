//
//  GateDisplay.swift
//  SwiftMkCore
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-07-06.
//  Copyright © 2026, all rights reserved.
//

import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

// MARK: - GateItem

public struct GateItem {
  public let name: String
  public let run: () -> Bool

  public init(name: String, run: @escaping () -> Bool) {
    self.name = name
    self.run = run
  }
}

// MARK: - GateDisplay

enum GateDisplay {
  private static let spinnerFrames = [
    "running .",
    "running ..",
    "running ...",
    "running ..",
  ]

  static func runGates(title: String, items: [GateItem]) -> [String] {
    if Env.get("SWIFT_MK_LOG_LEVEL").lowercased() == "debug" {
      return runRaw(items: items)
    }
    if isTerminal() {
      return runTTY(title: title, items: items)
    }
    return runStreamed(title: title, items: items)
  }

  private static func runRaw(items: [GateItem]) -> [String] {
    Output.debug("gate-display: running gates without captured display")
    var failedNames: [String] = []
    for item in items where !item.run() {
      failedNames.append(item.name)
    }
    if !failedNames.isEmpty {
      let noun = failedNames.count == 1 ? "check" : "checks"
      Output.log("\n\(failedNames.count) \(noun) failed: \(failedNames.joined(separator: ", "))")
    }
    return failedNames
  }

  private static func runStreamed(title: String, items: [GateItem]) -> [String] {
    let width = nameWidth(items: items)
    Output.emitStandardOutput(title + "\n")
    let steps = execute(items: items) { step, _ in
      Output.emitStandardOutput(GateReport.stepRow(width: width, step: step) + "\n")
    }
    Output.emitStandardOutput(reportTail(steps: steps) + "\n")
    return failedNames(steps: steps)
  }

  private static func runTTY(title: String, items: [GateItem]) -> [String] {
    guard !items.isEmpty else {
      Output.emitStandardOutput(GateReport.render(title: title, steps: []) + "\n")
      return []
    }
    let width = nameWidth(items: items)
    let liveRows = LiveGateRows(rows: initialRows(items: items, width: width))
    Output.emitStandardOutput(title + "\n" + liveRows.snapshot().joined(separator: "\n") + "\n")

    let tickerGroup = DispatchGroup()
    tickerGroup.enter()
    let ticker = Thread {
      liveRows.runTicker()
      tickerGroup.leave()
    }
    ticker.start()

    let steps = execute(
      items: items,
      beforeStep: { index in
        liveRows.setRunning(index: index, row: runningRow(items[index], width: width, frame: 0))
      },
      afterStep: { step, index in
        liveRows.resolve(index: index, row: GateReport.stepRow(width: width, step: step))
      })

    liveRows.stop()
    tickerGroup.wait()
    // The live rows are already resolved to their final stepRow form on screen, so
    // print only the findings-and-footer tail beneath them, reusing the same tail
    // the streamed path emits. The earlier version cleared the live block and
    // reprinted the whole report, which showed the gate box twice whenever the
    // cursor math drifted (a wrapped row, interleaved subprocess output). Emitting
    // the tail below the resolved rows renders one block unconditionally.
    Output.emitStandardOutput(reportTail(steps: steps) + "\n")
    return failedNames(steps: steps)
  }

  private static func execute(
    items: [GateItem],
    beforeStep: (Int) -> Void = { _ in
      // Streamed output has no live-row update before each step.
    },
    afterStep: (GateStepResult, Int) -> Void
  ) -> [GateStepResult] {
    var steps: [GateStepResult] = []
    for (index, item) in items.enumerated() {
      beforeStep(index)
      let step = runCaptured(item)
      steps.append(step)
      afterStep(step, index)
    }
    return steps
  }

  private static func runCaptured(_ item: GateItem) -> GateStepResult {
    Output.debug("gate-display: running captured gate \(item.name)")
    Output.beginCapture()
    let passed = item.run()
    let captured = Output.endCapture()
    return GateStepResult(
      name: item.name,
      status: passed ? .ok : .failed,
      note: nil,
      findings: passed ? [] : findingLines(from: captured),
      remediation: nil)
  }

  private static func findingLines(from text: String) -> [String] {
    var lines = text.components(separatedBy: "\n")
    if lines.last?.isEmpty == true {
      lines.removeLast()
    }
    return lines
  }

  private static func reportTail(steps: [GateStepResult]) -> String {
    var output = ""
    for step in steps {
      output += GateReport.findingsBlock(step: step)
    }
    output += GateReport.footer(failedNames: failedNames(steps: steps))
    return output
  }

  private static func failedNames(steps: [GateStepResult]) -> [String] {
    steps.filter { $0.status == .failed }.map(\.name)
  }

  private static func nameWidth(items: [GateItem]) -> Int {
    items.map(\.name.count).max() ?? 0
  }

  private static func initialRows(items: [GateItem], width: Int) -> [String] {
    items.enumerated().map { index, item in
      if index == 0 {
        return runningRow(item, width: width, frame: 0)
      }
      return GateReport.row(width: width, name: item.name, cell: "pending")
    }
  }

  private static func runningRow(_ item: GateItem, width: Int, frame: Int) -> String {
    let cell = spinnerFrames[frame % spinnerFrames.count]
    return GateReport.row(width: width, name: item.name, cell: cell)
  }

  private static func isTerminal() -> Bool {
    isatty(STDOUT_FILENO) != 0
  }

  private static func repaintRows(_ rows: [String]) {
    guard !rows.isEmpty else {
      return
    }
    var sequence = "\u{1B}[\(rows.count)A"
    for row in rows {
      sequence += "\r\u{1B}[2K\(row)\n"
    }
    writeRaw(sequence)
  }

  private static func writeRaw(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
  }

  // MARK: - LiveGateRows

  private final class LiveGateRows: @unchecked Sendable {
    private static let tickInterval: TimeInterval = 0.12
    private static let rowPrefixCharacterCount = 2
    private let lock = NSLock()
    private let condition = NSCondition()
    private let writeLock = NSLock()
    private var rows: [String]
    private var runningIndex: Int?
    private var frameIndex = 0
    private var stopped = false

    init(rows: [String]) {
      self.rows = rows
      runningIndex = rows.isEmpty ? nil : 0
    }

    func snapshot() -> [String] {
      lock.lock()
      defer { lock.unlock() }
      return rows
    }

    func setRunning(index: Int, row: String) {
      let currentRows = updateRows {
        runningIndex = index
        frameIndex = 0
        rows[index] = row
      }
      redraw(currentRows)
    }

    func resolve(index: Int, row: String) {
      let currentRows = updateRows {
        if runningIndex == index {
          runningIndex = nil
        }
        rows[index] = row
      }
      redraw(currentRows)
    }

    func runTicker() {
      while !isStoppedAfterWait() {
        let currentRows = updateRows {
          guard let runningIndex else {
            return
          }
          frameIndex = (frameIndex + 1) % GateDisplay.spinnerFrames.count
          let name = rowName(rows[runningIndex])
          rows[runningIndex] = GateReport.row(
            width: nameWidth(),
            name: name,
            cell: GateDisplay.spinnerFrames[frameIndex])
        }
        redraw(currentRows)
      }
    }

    func stop() {
      condition.lock()
      stopped = true
      condition.signal()
      condition.unlock()
    }

    private func updateRows(_ update: () -> Void) -> [String] {
      lock.lock()
      update()
      let currentRows = rows
      lock.unlock()
      return currentRows
    }

    private func redraw(_ currentRows: [String]) {
      writeLock.lock()
      GateDisplay.repaintRows(currentRows)
      writeLock.unlock()
    }

    private func isStoppedAfterWait() -> Bool {
      condition.lock()
      if !stopped {
        _ = condition.wait(until: Date().addingTimeInterval(Self.tickInterval))
      }
      let result = stopped
      condition.unlock()
      return result
    }

    private func nameWidth() -> Int {
      var width = 0
      for row in rows {
        let name = rowName(row)
        width = max(width, name.count)
      }
      return width
    }

    private func rowName(_ row: String) -> String {
      let trimmed = row.dropFirst(Self.rowPrefixCharacterCount)
      guard let separator = trimmed.range(of: "  ") else {
        return String(trimmed)
      }
      return String(trimmed[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
    }
  }
}
