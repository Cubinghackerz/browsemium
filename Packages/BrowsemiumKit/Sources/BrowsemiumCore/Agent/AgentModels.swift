import Foundation

/// Hard limits for an external-agent task. One place, so the gate, the
/// transport and the tests cannot drift apart.
public enum AgentLimits {
    public static let maxTabs = 4
    public static let maxOrigins = 8
    public static let lifetime: TimeInterval = 15 * 60
    public static let maxCalls = 100
    public static let maxTypedBytes = 8_000
    public static let maxReferenceLength = 100
    public static let maxRequestIDLength = 128
    public static let maxReadCharacters = 60_000
    public static let maxScreenshotBytes = 3_500_000
    public static let maxSnapshotElements = 200
    public static let maxAuditEntries = 200
    /// An unanswered native confirmation declines itself after this long.
    public static let approvalTimeout: TimeInterval = 120
}

/// Exact origin authority: scheme, host and port compared as a whole. There is
/// no wildcard, suffix match, path, or URL credential, and anything that does
/// not round-trip to the same canonical string is refused rather than guessed.
public struct AgentOrigin: Hashable, Codable, Sendable, CustomStringConvertible {
    public let description: String
    public let scheme: String
    public let host: String

    public init(_ url: URL) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              parts.user == nil, parts.password == nil,
              var host = parts.percentEncodedHost?.lowercased(), !host.isEmpty else {
            throw AgentError.invalidOrigin
        }
        // Foundation reports an IPv6 literal with or without brackets
        // depending on the OS release; compare the bare address.
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        let isIPv6 = host.contains(":")
        guard Self.isAcceptableHost(host, isIPv6: isIPv6) else { throw AgentError.invalidOrigin }
        if let port = parts.port, !(1...65535).contains(port) { throw AgentError.invalidOrigin }

        var value = "\(scheme)://" + (isIPv6 ? "[\(host)]" : host)
        let defaultPort = scheme == "https" ? 443 : 80
        if let port = parts.port, port != defaultPort { value += ":\(port)" }
        self.description = value
        self.scheme = scheme
        self.host = host
    }

    public init(string: String) throws {
        guard let url = URL(string: string) else { throw AgentError.invalidOrigin }
        try self.init(url)
        // A path, query, fragment or non-canonical spelling is not an origin.
        guard description == string else { throw AgentError.invalidOrigin }
    }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        try self.init(string: value)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    private static func isAcceptableHost(_ host: String, isIPv6: Bool) -> Bool {
        guard host.utf8.count <= 253 else { return false }
        if isIPv6 {
            return host.unicodeScalars.allSatisfy { "0123456789abcdef:.".unicodeScalars.contains($0) }
        }
        // ASCII letters, digits and hyphens in non-empty labels. Unicode,
        // percent-escapes, spaces and a trailing dot are refused, so two
        // spellings of one host can never be told apart by this check.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63
                && label.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }
}

public enum AgentCapability: String, Codable, CaseIterable, Sendable {
    case read, navigate, interact, screenshot
}

/// What the person approved in the native grant. Everything that decides which
/// profile store, origins and tools a task may touch lives here and is fixed at
/// creation; no tool argument can change it.
public struct AgentTask: Identifiable, Sendable {
    public let id: UUID
    public let spaceID: SpaceID
    public let clientID: UUID
    public let clientName: String
    public let title: String
    public let profileID: UUID
    /// The WebKit data store of `profileID`, resolved by the native grant. The
    /// gate hands only this value to the actuator.
    public let dataStoreID: UUID
    public let origins: Set<AgentOrigin>
    public let capabilities: Set<AgentCapability>

    public init(
        clientID: UUID,
        clientName: String,
        title: String,
        profileID: UUID,
        dataStoreID: UUID,
        origins: Set<AgentOrigin>,
        capabilities: Set<AgentCapability>
    ) throws {
        let cleanTitle = Self.displayText(title)
        let cleanName = Self.displayText(clientName)
        guard let cleanTitle, cleanTitle.count <= 160,
              let cleanName, cleanName.count <= 100,
              (1...AgentLimits.maxOrigins).contains(origins.count),
              capabilities.isSuperset(of: [.read, .navigate]) else {
            throw AgentError.invalidArguments
        }
        self.id = UUID()
        self.spaceID = SpaceID()
        self.clientID = clientID
        self.clientName = cleanName
        self.title = cleanTitle
        self.profileID = profileID
        self.dataStoreID = dataStoreID
        self.origins = origins
        self.capabilities = capabilities
    }

    /// Text the person will read in a native prompt. It comes from the client,
    /// so control and bidirectional-override characters are refused rather than
    /// rendered, and a blank value is not a name.
    static func displayText(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let refused = CharacterSet.controlCharacters
            .union(CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}\u{200E}\u{200F}"))
        guard trimmed.unicodeScalars.allSatisfy({ !refused.contains($0) }) else { return nil }
        return trimmed
    }
}

public enum AgentTaskState: String, Codable, Sendable {
    /// Waiting for the person's native confirmation.
    case waiting
    case ready
    case reading
    case acting
    /// The person took over. Pages stay; the agent has no access.
    case paused
    /// Ended on its own: budget spent, deadline reached, or the client said so.
    case finished
    /// Ended by the person, a lock, a profile change or a disconnect.
    case stopped

    public var hasAuthority: Bool {
        switch self {
        case .waiting, .ready, .reading, .acting: true
        case .paused, .finished, .stopped: false
        }
    }
}

public struct AgentElement: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let role: String
    public let name: String
    public let origin: AgentOrigin
    public let fingerprint: String
    public let isEditable: Bool
    public let isSensitive: Bool

    public init(
        id: String,
        role: String,
        name: String,
        origin: AgentOrigin,
        fingerprint: String,
        isEditable: Bool,
        isSensitive: Bool
    ) {
        self.id = id
        self.role = role
        self.name = name
        self.origin = origin
        self.fingerprint = fingerprint
        self.isEditable = isEditable
        self.isSensitive = isSensitive
    }
}

public struct AgentPageSnapshot: Codable, Equatable, Sendable {
    public let title: String
    public let origin: AgentOrigin
    public let elements: [AgentElement]
    public let isTruncated: Bool

    public init(title: String, origin: AgentOrigin, elements: [AgentElement], isTruncated: Bool = false) {
        self.title = title
        self.origin = origin
        self.elements = elements
        self.isTruncated = isTruncated
    }
}

public enum AgentPageAction: Equatable, Sendable {
    case click(AgentElement)
    case type(AgentElement, String)

    public var element: AgentElement {
        switch self {
        case .click(let element), .type(let element, _): element
        }
    }
}

public struct AgentTabInfo: Codable, Equatable, Sendable {
    public let id: UUID
    public let origin: String?

    public init(id: UUID, origin: String?) {
        self.id = id
        self.origin = origin
    }
}

/// A read-only picture of a task for status calls and the activity bar. It
/// carries no page content and no typed values.
public struct AgentStatusSnapshot: Codable, Equatable, Sendable {
    public let taskID: UUID
    public let title: String
    public let state: AgentTaskState
    public let expiresAt: Date?
    public let callsRemaining: Int
    public let tabs: [AgentTabInfo]
    public let permittedOrigins: [String]
    public let capabilities: [AgentCapability]

    public init(
        taskID: UUID,
        title: String,
        state: AgentTaskState,
        expiresAt: Date?,
        callsRemaining: Int,
        tabs: [AgentTabInfo],
        permittedOrigins: [String],
        capabilities: [AgentCapability]
    ) {
        self.taskID = taskID
        self.title = title
        self.state = state
        self.expiresAt = expiresAt
        self.callsRemaining = callsRemaining
        self.tabs = tabs
        self.permittedOrigins = permittedOrigins
        self.capabilities = capabilities
    }
}

public enum AgentError: Error, LocalizedError, Sendable, Equatable {
    case invalidArguments
    case invalidOrigin
    /// No grant, wrong client, out-of-scope origin or tab, or access revoked.
    case denied
    /// The person declined or did not answer a native confirmation.
    case declined
    case expired
    case busy
    case staleElement
    case sensitiveField
    case tabLimit
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .invalidArguments: "The tool arguments are not valid."
        case .invalidOrigin: "Use an exact HTTP or HTTPS origin without credentials."
        case .denied: "This task does not have permission for that action."
        case .declined: "The person declined this action."
        case .expired: "The task grant ended. Request a new task."
        case .busy: "Another action is running. Wait for its result."
        case .staleElement: "The page changed. Take a new snapshot before acting."
        case .sensitiveField: "Password, payment, one-time-code and file fields cannot be used."
        case .tabLimit: "A task can own at most four tabs."
        case .unavailable: "The task page is not available."
        }
    }
}
