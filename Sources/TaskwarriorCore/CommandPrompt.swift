import Foundation

/// The `:` that starts the command line while it is being edited, as vim's does. It is the
/// field's text, not a label beside it, but never reaches the model: `AppModel.commandText`
/// holds the line without it, so history, submit and taskwarrior never see a colon.
public enum CommandPrompt {
    public static let prompt = ":"

    /// The line typed after the prompt. Any further leading colons go too (`::next` from a
    /// vim habit), since no taskwarrior command line starts with one.
    public static func line(fromField text: String) -> String {
        String(text.drop(while: { $0 == ":" }))
    }

    /// What the field shows for `line` while it is being edited.
    public static func field(for line: String) -> String {
        prompt + line
    }
}
