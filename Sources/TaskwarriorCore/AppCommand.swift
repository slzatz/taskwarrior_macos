import Foundation

/// A command line the app answers itself instead of running `task`. `help` is also a
/// taskwarrior command; typed in full, `task help` still runs that one.
public enum AppCommand: Sendable, Equatable {
    /// The app's keyboard and command reference.
    case help

    public init?(line: String) {
        switch ShellTokenizer.tokenize(line) {
        case ["help"], ["h"], ["?"]: self = .help
        default: return nil
        }
    }
}
