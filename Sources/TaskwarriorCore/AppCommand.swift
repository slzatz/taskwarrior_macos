import Foundation

/// A command line the app answers itself instead of running `task`. `help` is also a
/// taskwarrior command; typed in full, `task help` still runs that one. `clear` is no command
/// to taskwarrior, where alone it would search descriptions; `clear next` still does.
public enum AppCommand: Sendable, Equatable {
    /// The app's keyboard and command reference.
    case help
    /// The current listing again without its typed filter (`ListingView.cleared`).
    case clear

    public init?(line: String) {
        switch ShellTokenizer.tokenize(line) {
        case ["help"], ["h"], ["?"]: self = .help
        case ["clear"]: self = .clear
        default: return nil
        }
    }
}
