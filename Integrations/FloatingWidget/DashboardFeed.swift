import Darwin
import Foundation

struct DashboardFeed: Sendable {
    private struct ServerSettings: Decodable {
        let enabled: Bool
        let host: String
        let port: Int
        let token: String

        var localHost: String {
            let trimmed = self.host.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.lowercased() == "localhost" ? "127.0.0.1" : trimmed
        }
    }

    private enum FeedError: LocalizedError {
        case setup, localOnly, rejected, unavailable

        var errorDescription: String? {
            switch self {
            case .setup: "Enable the HTTP server in CodexBar Settings → Advanced."
            case .localOnly: "Set the CodexBar HTTP server bind address to 127.0.0.1."
            case .rejected: "CodexBar rejected the token. Apply the HTTP server settings again."
            case .unavailable: "Usage feed unavailable. Check that CodexBar is running."
            }
        }
    }

    private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _: URLSession,
            task _: URLSessionTask,
            willPerformHTTPRedirection _: HTTPURLResponse,
            newRequest _: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void)
        {
            completionHandler(nil)
        }
    }

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 40
        configuration.timeoutIntervalForResource = 45
        return URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
    }()

    func snapshot() async throws -> String {
        let settings = try Self.loadSettings()
        guard settings.enabled else { throw FeedError.setup }
        guard settings.localHost == "127.0.0.1" else { throw FeedError.localOnly }
        guard (1...65535).contains(settings.port),
              !settings.token.isEmpty,
              settings.token.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
              let url = URL(string: "http://127.0.0.1:\(settings.port)/dashboard/v1/snapshot")
        else { throw FeedError.setup }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.session.data(for: request)
        } catch {
            try Task.checkCancellation()
            throw FeedError.unavailable
        }

        guard let http = response as? HTTPURLResponse else { throw FeedError.unavailable }
        if http.statusCode == 401 { throw FeedError.rejected }
        guard http.statusCode == 200, let snapshot = String(data: data, encoding: .utf8) else {
            throw FeedError.unavailable
        }
        return snapshot
    }

    private static func loadSettings() throws -> ServerSettings {
        let url = Self.settingsURL()
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw FeedError.setup }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(),
              info.st_mode & 0o777 == 0o600,
              let data = try? file.read(upToCount: 16384),
              let settings = try? JSONDecoder().decode(ServerSettings.self, from: data)
        else { throw FeedError.setup }
        return settings
    }

    private static func settingsURL() -> URL {
        let files = FileManager.default
        let home = files.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        let override = environment["CODEXBAR_CONFIG"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !override.isEmpty {
            let configPath = (override as NSString).expandingTildeInPath
            return URL(fileURLWithPath: configPath).deletingLastPathComponent()
                .appendingPathComponent("http-server.json")
        }

        let xdg = environment["XDG_CONFIG_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let expanded = (xdg as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath {
            return URL(fileURLWithPath: expanded, isDirectory: true)
                .appendingPathComponent("codexbar/http-server.json")
        }

        let current = home.appendingPathComponent(".config/codexbar", isDirectory: true)
        let legacy = home.appendingPathComponent(".codexbar", isDirectory: true)
        let usesLegacy = !files.fileExists(atPath: current.appendingPathComponent("config.json").path)
            && files.fileExists(atPath: legacy.appendingPathComponent("config.json").path)
        return (usesLegacy ? legacy : current).appendingPathComponent("http-server.json")
    }
}
