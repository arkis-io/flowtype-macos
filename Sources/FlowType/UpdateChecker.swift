import Foundation

struct ReleaseVersion: Comparable, Equatable, CustomStringConvertible {
    let components: [Int]

    init?(_ rawValue: String) {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("v") {
            value.removeFirst()
        }

        let stablePart = value
            .split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let parsed = stablePart.split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard !parsed.isEmpty,
              parsed.count == stablePart.split(separator: ".", omittingEmptySubsequences: false).count else {
            return nil
        }
        components = parsed
    }

    var description: String {
        components.map(String.init).joined(separator: ".")
    }

    static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }
}

struct FlowTypeRelease: Equatable {
    let version: String
    let title: String
    let notes: String
    let webpageURL: URL
}

enum ReleaseCheckOutcome: Equatable {
    case updateAvailable(FlowTypeRelease)
    case upToDate(FlowTypeRelease)
    case feedUnavailable
}

enum ReleaseUpdateError: LocalizedError {
    case invalidCurrentVersion(String)
    case invalidReleaseVersion(String)
    case invalidReleaseURL
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .invalidCurrentVersion(let version):
            return "FlowType's installed version is not valid: \(version)."
        case .invalidReleaseVersion(let version):
            return "The latest GitHub release has an invalid version tag: \(version)."
        case .invalidReleaseURL:
            return "The latest release did not provide a valid GitHub download page."
        case .invalidResponse:
            return "GitHub returned an unreadable update response."
        case .requestFailed(let statusCode):
            return "GitHub could not check for updates (HTTP \(statusCode))."
        }
    }
}

final class ReleaseUpdateChecker {
    private struct GitHubReleasePayload: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case body
            case htmlURL = "html_url"
        }
    }

    private let endpoint: URL
    private let session: URLSession

    init(endpoint: URL, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    func check(currentVersion: String) async throws -> ReleaseCheckOutcome {
        guard let installedVersion = ReleaseVersion(currentVersion) else {
            throw ReleaseUpdateError.invalidCurrentVersion(currentVersion)
        }

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("FlowType/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ReleaseUpdateError.invalidResponse
        }
        if httpResponse.statusCode == 404 {
            return .feedUnavailable
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ReleaseUpdateError.requestFailed(httpResponse.statusCode)
        }

        return try Self.outcome(from: data, currentVersion: installedVersion)
    }

    static func outcome(from data: Data, currentVersion: ReleaseVersion) throws -> ReleaseCheckOutcome {
        let payload: GitHubReleasePayload
        do {
            payload = try JSONDecoder().decode(GitHubReleasePayload.self, from: data)
        } catch {
            throw ReleaseUpdateError.invalidResponse
        }

        guard let availableVersion = ReleaseVersion(payload.tagName) else {
            throw ReleaseUpdateError.invalidReleaseVersion(payload.tagName)
        }
        guard payload.htmlURL.scheme == "https", payload.htmlURL.host == "github.com" else {
            throw ReleaseUpdateError.invalidReleaseURL
        }

        let release = FlowTypeRelease(
            version: availableVersion.description,
            title: payload.name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? "FlowType \(availableVersion)",
            notes: payload.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            webpageURL: payload.htmlURL
        )
        return availableVersion > currentVersion ? .updateAvailable(release) : .upToDate(release)
    }

    static func shouldCheckAutomatically(
        lastCheck: Date?,
        now: Date = Date(),
        interval: TimeInterval = 24 * 60 * 60
    ) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
