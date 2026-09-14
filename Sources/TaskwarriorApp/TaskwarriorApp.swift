import SwiftUI
import AppKit

@main
struct TaskwarriorApp: App {
    @State private var model = AppModel()

    init() {
        // Lets `swift run` (no app bundle) still show a window and menu bar.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Taskwarrior", id: "main") {
            ContentView()
                .environment(model)
                .task {
                    await model.bootstrap()
                    await DebugHooks.run(with: model)
                }
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 980, height: 640)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Increase Font Size") { model.adjustFontSize(by: 1) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Decrease Font Size") { model.adjustFontSize(by: -1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Reset Font Size") { model.resetFontSize() }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
                Button(model.logExpanded ? "Hide Output Pane" : "Show Output Pane") { model.logExpanded.toggle() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("Task") {
                Button("Refresh View") { model.refreshCurrentView() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Focus Command Field") { model.focusCommandField() }
                    .keyboardShortcut("l", modifiers: .command)
                Divider()
                Button("Clear Output") { model.clearLog() }
                    .keyboardShortcut("k", modifiers: .command)
            }
        }
    }
}
