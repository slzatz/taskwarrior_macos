import Foundation

/// A taskchampion sync server (`sync.server.url`), asked whether it has a version this replica
/// hasn't pulled. The same question taskchamp's probe asks: the child of the replica's base
/// version, one request, nothing applied. No encryption secret is needed, since the answer is
/// read from the status alone.
public struct SyncServer: Equatable, Sendable {
    public var url: URL
    public var clientID: String

    /// From `task _show`'s config; nil for the GCP, AWS and local backends, which the app
    /// doesn't probe. `sync.server.origin` is taskwarrior 3.0's name for the url.
    public init?(config: [String: String]) {
        guard let raw = config["sync.server.url"] ?? config["sync.server.origin"],
              let url = URL(string: raw.trimmingCharacters(in: .whitespaces)), url.scheme != nil,
              let clientID = config["sync.server.client_id"]?.trimmingCharacters(in: .whitespaces),
              UUID(uuidString: clientID) != nil else { return nil }
        self.url = url
        self.clientID = clientID
    }

    /// Whether any sync backend is set up, i.e. whether `task sync` means anything.
    public static func isConfigured(config: [String: String]) -> Bool {
        config.contains { key, value in
            ["sync.server.", "sync.gcp.", "sync.aws.", "sync.local."].contains { key.hasPrefix($0) } && !value.isEmpty
        }
    }

    public func childVersionRequest(of baseVersion: String) -> URLRequest {
        var base = url.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        var request = URLRequest(url: URL(string: "\(base)/v1/client/get-child-version/\(baseVersion)")!)
        request.setValue(clientID, forHTTPHeaderField: "X-Client-Id")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 8
        return request
    }

    /// 200 carries the next version, 404 means there is none; anything else (taskchampion
    /// treats it as an error) says nothing.
    public static func serverAhead(status: Int) -> Bool? {
        switch status {
        case 200: true
        case 404: false
        default: nil
        }
    }

    /// Nil when the server can't be reached or answers unexpectedly.
    public func isAhead(of baseVersion: String) async -> Bool? {
        guard let (_, response) = try? await URLSession.shared.data(for: childVersionRequest(of: baseVersion)),
              let http = response as? HTTPURLResponse else { return nil }
        return Self.serverAhead(status: http.statusCode)
    }
}
