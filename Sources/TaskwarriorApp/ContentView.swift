import SwiftUI
import TaskwarriorCore

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            TerminalTextView(
                runs: model.display,
                generation: model.displayGeneration,
                fontSize: model.fontSize,
                preserveScroll: model.displayIsRefresh
            )
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                model.displaySizeChanged(size)
            }

            Divider()
            LogPane()
            Divider()

            CommandField(
                text: $model.commandText,
                fontSize: model.fontSize,
                history: model.history,
                focusRequest: model.focusRequest,
                onSubmit: { model.submit() }
            )
            .padding(8)
        }
        .frame(minWidth: 520, minHeight: 320)
        .background(Color(nsColor: TerminalPalette.headerBackground))
        .preferredColorScheme(.dark)
        .alert(
            model.pendingConfirmation?.title ?? "Confirm",
            isPresented: Binding(
                get: { model.pendingConfirmation != nil },
                set: { if !$0 { model.pendingConfirmation = nil } }
            ),
            presenting: model.pendingConfirmation
        ) { confirmation in
            Button("Cancel", role: .cancel) { model.focusCommandField() }
            Button("Run", role: .destructive) {
                confirmation.proceed()
                model.focusCommandField()
            }
        } message: { confirmation in
            Text(confirmation.message)
        }
    }
}

/// Command output and status: the most recent message is always visible in the
/// header row; expanding shows the scrollable history.
struct LogPane: View {
    @Environment(AppModel.self) private var model

    private var logFontSize: Double { max(model.fontSize - 1, 9) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    model.logExpanded.toggle()
                } label: {
                    Image(systemName: model.logExpanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(Color(nsColor: TerminalPalette.dimForeground))
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                .help(model.logExpanded ? "Hide output" : "Show output")

                Text(model.statusLine.isEmpty ? "Output" : model.statusLine)
                    .font(.system(size: logFontSize, design: .monospaced))
                    .foregroundStyle(model.statusIsError ? Color.red : Color(nsColor: TerminalPalette.dimForeground))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if model.isRunning {
                    ProgressView().controlSize(.small)
                }
                Text(model.currentContext.isEmpty || model.currentContext == "none" ? "no context" : "context: \(model.currentContext)")
                    .font(.system(size: logFontSize, design: .monospaced))
                    .foregroundStyle(Color(nsColor: TerminalPalette.dimForeground))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: TerminalPalette.headerBackground))

            if model.logExpanded {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(model.log) { entry in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("› " + entry.command)
                                        .font(.system(size: logFontSize, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(entry.isError ? Color.red : Color(nsColor: TerminalPalette.dimForeground))
                                    if !entry.runs.isEmpty {
                                        Text(TerminalStyle.attributedString(entry.runs, fontSize: logFontSize))
                                            .textSelection(.enabled)
                                    }
                                }
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(entry.id)
                            }
                        }
                        .padding(8)
                    }
                    .frame(height: 150)
                    .background(Color(nsColor: TerminalPalette.logBackground))
                    .onChange(of: model.log.count) {
                        if let last = model.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                    .onAppear {
                        if let last = model.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }

}
