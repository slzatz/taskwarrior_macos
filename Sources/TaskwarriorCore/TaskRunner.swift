import Foundation

public struct TaskResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public var succeeded: Bool { exitCode == 0 }
    /// stdout, falling back to stderr when stdout is empty (e.g. "No matches.").
    public var primaryOutput: String { stdout.isEmpty ? stderr : stdout }
    public var combinedOutput: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: stdout.hasSuffix("\n") || stdout.isEmpty ? "" : "\n")
    }
}

public enum TaskRunnerError: Error, LocalizedError {
    case executableNotFound
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound: return "Could not find the 'task' executable."
        case .launchFailed(let reason): return "Could not run task: \(reason)"
        }
    }
}

/// Runs the taskwarrior binary. Synchronous; call from a background task.
public struct TaskRunner: Sendable {
    public let executable: URL
    /// `rc.name=value` overrides applied to every invocation, before the user's own tokens.
    public var baseOverrides: [String]

    public init(executable: URL, baseOverrides: [String] = []) {
        self.executable = executable
        self.baseOverrides = baseOverrides
    }

    public func run(_ arguments: [String], overrides: [String] = []) throws -> TaskResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = baseOverrides + overrides + arguments
        process.environment = ProcessInfo.processInfo.environment
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw TaskRunnerError.launchFailed(error.localizedDescription)
        }

        // Drain both pipes concurrently so a chatty stderr cannot deadlock stdout.
        let group = DispatchGroup()
        var stdoutData = Data()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        return TaskResult(
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }

    /// Finds the `task` binary. GUI apps launched from Finder get a minimal PATH,
    /// so well-known locations are checked before falling back to a login shell.
    public static func locate(preferred: String? = nil) -> URL? {
        var candidates: [String] = []
        if let preferred, !preferred.isEmpty { candidates.append(preferred) }
        candidates += [
            "/opt/homebrew/bin/task",
            "/usr/local/bin/task",
            "/opt/local/bin/task",
            "/usr/bin/task",
            NSHomeDirectory() + "/.local/bin/task",
            NSHomeDirectory() + "/.cargo/bin/task",
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { String($0) + "/task" }
        }
        let fm = FileManager.default
        for candidate in candidates where fm.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        // Last resort: ask the user's login shell.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v task"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        shell.standardInput = FileHandle.nullDevice
        if (try? shell.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            shell.waitUntilExit()
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, fm.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}
