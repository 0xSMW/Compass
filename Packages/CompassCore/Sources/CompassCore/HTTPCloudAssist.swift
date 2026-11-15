import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where the cloud model lives. No secrets: the endpoint is configured per build (Info.plist
/// `CompassCloudAssistEndpoint`, from the `COMPASS_CLOUD_ASSIST_ENDPOINT` build setting) and is empty
/// in the repo, so the client is disabled unless someone configures it.
public struct CloudAssistConfiguration: Hashable, Sendable {
    public var endpoint: URL?
    public var timeout: TimeInterval

    public init(endpoint: URL?, timeout: TimeInterval = 20) {
        self.endpoint = endpoint
        self.timeout = timeout
    }

    /// Parses a configured string. Empty, unexpanded (`$(…)`) or non-http(s) values mean "not configured".
    public init(endpointString: String?, timeout: TimeInterval = 20) {
        let trimmed = (endpointString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var url: URL?
        if !trimmed.isEmpty, !trimmed.contains("$("), let u = URL(string: trimmed),
           let scheme = u.scheme?.lowercased(), scheme == "https" || scheme == "http", u.host != nil {
            url = u
        }
        self.init(endpoint: url, timeout: timeout)
    }

    public static let none = CloudAssistConfiguration(endpoint: nil)
}

/// A response the client couldn't use (non-2xx, malformed JSON). Callers fall back to "no summary".
public enum HTTPCloudAssistError: Error, Equatable, Sendable {
    case badStatus(Int)
    case malformedResponse
}

/// The real `CloudAssist`: JSON over HTTPS to a private model endpoint. Only text is sent (never audio).
///
/// Endpoints (POST, `application/json`):
/// - `summarize` `{transcript, goal}` → `{summary}`
/// - `step` `{goal, parts, part, size, recent:[{date, title, moved}]}` → `{title, partID?, size?, hint?}`
/// - `clarify` `{goal}` → `{question: string|null}`
/// - `parts` `{goal}` → `{parts:[{title, symbol}]}`
///
/// Throws `CloudAssistError.disabled` when the Settings switch is off or no endpoint is configured,
/// and `.offline` when the network is unreachable. The on-device fallback is simply no summary / no idea.
public final class HTTPCloudAssist: CloudAssist, @unchecked Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public let configuration: CloudAssistConfiguration
    private let transport: Transport
    private let lock = NSLock()
    private var _switchOn: Bool

    public init(configuration: CloudAssistConfiguration, switchOn: Bool, transport: Transport? = nil) {
        self.configuration = configuration
        self._switchOn = switchOn
        self.transport = transport ?? HTTPCloudAssist.urlSessionTransport
    }

    /// The Settings "Cloud help" switch.
    public var switchOn: Bool {
        get { lock.withLock { _switchOn } }
        set { lock.withLock { _switchOn = newValue } }
    }

    public var isEnabled: Bool { switchOn && configuration.endpoint != nil }

    // MARK: CloudAssist

    public func summarize(transcript: String, goal: Goal?) async throws -> String {
        struct Body: Encodable { var transcript: String; var goal: String? }
        struct Reply: Decodable { var summary: String }
        let reply: Reply = try await post("summarize", Body(transcript: transcript, goal: goal?.text))
        let s = reply.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw HTTPCloudAssistError.malformedResponse }
        return s
    }

    public func suggestStep(goal: Goal, part: GoalPart?, size: StepSize, recent: [Day]) async throws -> StepIdea {
        struct PartBody: Encodable { var id: UUID; var title: String }
        struct Recent: Encodable { var date: String; var title: String?; var moved: Bool }
        struct Body: Encodable { var goal: String; var parts: [PartBody]; var part: PartBody?; var size: String; var recent: [Recent] }
        struct Reply: Decodable { var title: String; var partID: UUID?; var size: String?; var hint: String? }
        let body = Body(
            goal: goal.text,
            parts: goal.activeParts.map { PartBody(id: $0.id, title: $0.title) },
            part: part.map { PartBody(id: $0.id, title: $0.title) },
            size: size.rawValue,
            recent: recent.suffix(14).map { Recent(date: $0.key.description, title: $0.step?.title, moved: $0.moved) }
        )
        let reply: Reply = try await post("step", body)
        let title = reply.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw HTTPCloudAssistError.malformedResponse }
        let partID = reply.partID.flatMap { id in goal.parts.contains { $0.id == id } ? id : nil } ?? part?.id
        return StepIdea(title: title, partID: partID, size: reply.size.flatMap(StepSize.init(rawValue:)) ?? size, hint: reply.hint)
    }

    public func clarifyingQuestion(for goalText: String) async throws -> String? {
        struct Body: Encodable { var goal: String }
        struct Reply: Decodable { var question: String? }
        let reply: Reply = try await post("clarify", Body(goal: goalText))
        let q = reply.question?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (q?.isEmpty ?? true) ? nil : q
    }

    public func proposeParts(for goalText: String) async throws -> [GoalPart] {
        struct Body: Encodable { var goal: String }
        struct PartReply: Decodable { var title: String; var symbol: String? }
        struct Reply: Decodable { var parts: [PartReply] }
        let reply: Reply = try await post("parts", Body(goal: goalText))
        let fallback: [PartSymbol] = [.wealth, .strength, .friends, .flag, .sun, .moon]
        return reply.parts.prefix(6).enumerated().compactMap { i, p in
            let title = p.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return GoalPart(title: title, symbol: p.symbol.flatMap(PartSymbol.init(rawValue:)) ?? fallback[i % fallback.count])
        }
    }

    // MARK: Transport

    func request(_ path: String, body: Data) throws -> URLRequest {
        guard switchOn, let base = configuration.endpoint else { throw CloudAssistError.disabled }
        var req = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: configuration.timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = body
        return req
    }

    private func post<B: Encodable, R: Decodable>(_ path: String, _ body: B) async throws -> R {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let req = try request(path, body: try encoder.encode(body))
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(req)
        } catch let error as URLError {
            throw Self.isOffline(error) ? CloudAssistError.offline : error
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPCloudAssistError.badStatus(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(R.self, from: data)
        } catch {
            throw HTTPCloudAssistError.malformedResponse
        }
    }

    static func isOffline(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            return true
        default:
            return false
        }
    }

    public static let urlSessionTransport: Transport = { request in
        try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let response {
                    continuation.resume(returning: (data ?? Data(), response))
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }
            task.resume()
        }
    }
}
