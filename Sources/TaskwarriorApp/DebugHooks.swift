import AppKit
import SwiftUI
import TaskwarriorCore

/// Developer hooks driven by environment variables (see README, "Scripted runs"):
///   TASKWARRIOR_APP_SCRIPT   commands separated by ";;", run after startup; `@report <name>`,
///                            `@project <name>|-` and `@context <name>` act as the header menus do
///   TASKWARRIOR_APP_SNAPSHOT path of a PNG to write once the script has finished
///   TASKWARRIOR_APP_QUIT     "1" to quit after the script / snapshot
/// Combine with TASKDATA / TASKRC to point taskwarrior at a scratch database.
enum DebugHooks {
    static var script: [String] {
        guard let raw = ProcessInfo.processInfo.environment["TASKWARRIOR_APP_SCRIPT"], !raw.isEmpty else { return [] }
        return raw.components(separatedBy: ";;").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static var snapshotPath: String? { ProcessInfo.processInfo.environment["TASKWARRIOR_APP_SNAPSHOT"] }
    static var quitAfter: Bool { ProcessInfo.processInfo.environment["TASKWARRIOR_APP_QUIT"] == "1" }
    static var isActive: Bool { !script.isEmpty || snapshotPath != nil || quitAfter }

    @MainActor
    static func run(with model: AppModel) async {
        guard isActive else { return }
        for line in script {
            guard line.hasPrefix("@") else {
                model.run(line: line)
                continue
            }
            // A menu works on the listing the previous line produced.
            await model.waitUntilIdle()
            let parts = line.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
            let value = parts.count > 1 ? parts[1] : ""
            switch parts.first {
            case "report": model.showReport(value)
            case "project": model.showProject(value == "-" ? nil : value)
            case "context": model.switchContext(value)
            default: FileHandle.standardError.write(Data("script: unknown \(line)\n".utf8))
            }
        }
        await model.waitUntilIdle()
        // Give SwiftUI/AppKit a moment to lay out the final content.
        try? await Task.sleep(for: .milliseconds(600))
        if let path = snapshotPath { snapshot(to: path, model: model) }
        if quitAfter {
            model.pendingConfirmation = nil
            try? await Task.sleep(for: .milliseconds(200))
            exit(0)
        }
    }

    @MainActor
    static func snapshot(to path: String, model: AppModel) {
        guard let window = NSApp.windows.first(where: { $0.isVisible }),
              let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            FileHandle.standardError.write(Data("snapshot: no window\n".utf8))
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        if ProcessInfo.processInfo.environment["TASKWARRIOR_APP_DUMP"] == "1" {
            var out = "window frame: \(window.frame) contentView: \(view.frame) appearance: \(window.effectiveAppearance.name.rawValue)\n"
            func walk(_ v: NSView, depth: Int) {
                let pad = String(repeating: "  ", count: depth)
                out += "\(pad)\(type(of: v)) frame=\(v.frame)\n"
                if let tv = v as? NSTextView {
                    out += "\(pad)  visibleRect=\(tv.visibleRect) text=\(String(tv.string.prefix(160)).debugDescription)\n"
                }
                if depth < 6 { v.subviews.forEach { walk($0, depth: depth + 1) } }
            }
            walk(view, depth: 0)
            func names(_ nodes: [ProjectNode]) -> String {
                nodes.map { $0.children.isEmpty ? $0.name : "\($0.name)[\(names($0.children))]" }.joined(separator: " ")
            }
            let reports = model.reportChoices
            out += "menus: reports=\(reports.main) variants=\(reports.variants) contexts=\(model.contexts) projects=\(names(model.projectChoices))\n"
            FileHandle.standardError.write(Data(out.utf8))
        }
        guard let png = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
