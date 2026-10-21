import AppKit
import SwiftUI
import TaskwarriorCore

/// Developer hooks driven by environment variables (see README, "Scripted runs"):
///   TASKWARRIOR_APP_SCRIPT   commands separated by ";;", run after startup; `@report <name>`,
///                            `@project <name>|-` and `@context <name>` act as the header menus do;
///                            `@edit <id>` opens the row's description editor, `@edit <id> <text>` commits it;
///                            `@keys <vim notation>` types into the window, e.g. `@keys ciwfoo<Esc><CR>` (also `<Up>`, `<Down>`)
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
            case "edit": edit(value, model: model)
            case "keys": await typeKeys(value)
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

    /// `<id>` opens the description editor as `e` does; `<id> <text>` commits as Return does.
    @MainActor
    private static func edit(_ value: String, model: AppModel) {
        let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
        guard let number = parts.first.flatMap(Int.init),
              let task = model.tasks?.first(where: { $0.number == number }) else {
            FileHandle.standardError.write(Data("script: no task \(value) in the list\n".utf8))
            return
        }
        if parts.count > 1 {
            model.setDescription(parts[1], of: task)
        } else {
            model.editingUUID = task.uuid
        }
    }

    /// Posts the keys as real key-down events, so they take the path typing does (key monitors,
    /// then the first responder). Waits first for a view opened by the line before to take focus.
    @MainActor
    private static func typeKeys(_ notation: String) async {
        try? await Task.sleep(for: .milliseconds(300))
        // To the help sheet while it is open, as typing would.
        guard let main = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil }) else { return }
        let window = main.attachedSheet ?? main
        // The editor has no Up/Down; they pass through as the characters AppKit gives those keys.
        let notation = notation.replacingOccurrences(of: "<Up>", with: "\u{F700}").replacingOccurrences(of: "<Down>", with: "\u{F701}")
        for key in ViLineEditor.keys(notation) {
            let (characters, keyCode, flags): (String, UInt16, NSEvent.ModifierFlags) = switch key {
            case .char("\u{F700}"): ("\u{F700}", 126, [.function, .numericPad])
            case .char("\u{F701}"): ("\u{F701}", 125, [.function, .numericPad])
            case .char(let c): (String(c), 0xFFFF, [])
            case .ctrl(let c): (String(c), 0xFFFF, .control)
            case .escape: ("\u{1b}", 53, [])
            case .enter: ("\r", 36, [])
            case .backspace: ("\u{7f}", 51, [])
            case .left: ("\u{F702}", 123, [])
            case .right: ("\u{F703}", 124, [])
            case .home: ("\u{F729}", 115, [])
            case .end: ("\u{F72B}", 119, [])
            }
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil,
                                               characters: characters, charactersIgnoringModifiers: characters,
                                               isARepeat: false, keyCode: keyCode) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
        try? await Task.sleep(for: .milliseconds(300))
    }

    @MainActor
    static func snapshot(to path: String, model: AppModel) {
        // The help sheet is a window of its own, attached to the main one.
        guard let main = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil }),
              case let window = main.attachedSheet ?? main,
              let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            FileHandle.standardError.write(Data("snapshot: no window\n".utf8))
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        if ProcessInfo.processInfo.environment["TASKWARRIOR_APP_DUMP"] == "1" {
            var out = "window frame: \(window.frame) contentView: \(view.frame) appearance: \(window.effectiveAppearance.name.rawValue)\n"
            out += "first responder: \(main.firstResponder.map { String(describing: type(of: $0)) } ?? "none")"
            if let sheet = main.attachedSheet {
                func scrollView(in view: NSView) -> NSScrollView? {
                    view as? NSScrollView ?? view.subviews.lazy.compactMap(scrollView).first
                }
                let origin = sheet.contentView.flatMap(scrollView)?.contentView.bounds.origin.y ?? -1
                out += "  sheet open, scrolled to \(origin)\n"
            } else {
                out += "\n"
            }
            let selected = model.selectedUUID.map { uuid in model.tasks?.first { $0.uuid == uuid }.map { "id \($0.number)" } ?? uuid }
            out += "selected: \(selected ?? "none")  command line: \(model.commandText.debugDescription)\n"
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
        var png = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:])
        if main.attachedSheet != nil {
            // The sheet's window draws blank into a bitmap, so draw the help itself.
            let renderer = ImageRenderer(content: HelpContent().padding(12).frame(width: 720)
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
            renderer.scale = 2
            png = renderer.nsImage?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?
                .representation(using: .png, properties: [:])
        }
        guard let png else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
