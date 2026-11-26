// Async client for the backend routes the apps use. Only the iPhone calls it; the watch relays through the phone.
// The patient API is intended for a trusted network.
import Foundation

public enum APIError: Error, Equatable, Sendable {
    /// The calm voice is not configured (HTTP 503). Fall back to haptic breathing alone.
    case voiceUnavailable
    case notFound
    case http(status: Int, body: String)
    case notHTTP
}

public struct APIClient: Sendable {
    public let baseURL: URL
    private let session: URLSession
    private let patientDeviceKey: String?

    public init(baseURL: URL, session: URLSession = .shared, patientDeviceKey: String? = nil) {
        self.baseURL = baseURL
        self.session = session
        self.patientDeviceKey = patientDeviceKey
    }

    // MARK: Scoring

    /// Passive watch window.
    public func postWindow(_ w: MotionWindow, uploadId: String? = nil) async throws -> ScoreResult {
        var req = request("POST", "v1/windows")
        req.setValue(uploadId, forHTTPHeaderField: "X-Watch-Upload-Id")
        let (data, _) = try await perform(withBody(req, w))
        return try JSONDecoder.tremor.decode(ScoreResult.self, from: data)
    }

    /// The 30-second phone test. Same scorer as `postWindow`.
    public func postPhoneTest(_ w: MotionWindow) async throws -> ScoreResult {
        try await send("POST", "v1/phone-test", body: w)
    }

    // MARK: Patient data

    public func postDose(patientId: String, _ d: DoseEvent) async throws {
        try await sendNoContent("POST", "v1/patients/\(patientId.pathEscaped)/doses", body: d)
    }

    public func timeline(patientId: String) async throws -> Timeline {
        try await send("GET", "v1/patients/\(patientId.pathEscaped)/timeline")
    }

    public func baseline(patientId: String) async throws -> Baseline {
        try await send("GET", "v1/patients/\(patientId.pathEscaped)/baseline")
    }

    // MARK: Consent

    public func giveConsent(patientId: String) async throws -> Consent {
        try await send("POST", "v1/patients/\(patientId.pathEscaped)/consent")
    }

    public func withdrawConsent(patientId: String, consentId: String) async throws {
        try await sendNoContent("DELETE", "v1/patients/\(patientId.pathEscaped)/consent/\(consentId.pathEscaped)")
    }

    public struct ApprovedLink: ContractModel, Sendable {
        public let linkId: String
        public let patientSecret: String

        enum CodingKeys: String, CodingKey, CaseIterable {
            case linkId = "link_id", patientSecret = "patient_secret"
        }
        public static let schemaName = "LinkApproved"
        public static var wireKeys: [String] { keys(CodingKeys.self) }
    }

    private struct LinkApproval<Record: Encodable>: Encodable {
        let patientId: String
        let code: String
        let record: Record?
    }

    public func approveLink<Record: Encodable & Sendable>(patientId: String, code: String, record: Record?) async throws -> ApprovedLink {
        let body = LinkApproval(patientId: patientId, code: code, record: record)
        let req = try withSharingBody(request("POST", "v1/links/approve"), body)
        let (data, _) = try await perform(req)
        return try JSONDecoder.tremor.decode(ApprovedLink.self, from: data)
    }

    public func updateLinkRecord<Record: Encodable & Sendable>(linkId: String, patientSecret: String, record: Record) async throws {
        var req = request("PUT", "v1/links/\(linkId.pathEscaped)/record")
        req.setValue(patientSecret, forHTTPHeaderField: "X-Patient-Secret")
        _ = try await perform(withSharingBody(req, record))
    }

    public func revokeLink(linkId: String, patientSecret: String) async throws {
        var req = request("DELETE", "v1/links/\(linkId.pathEscaped)")
        req.setValue(patientSecret, forHTTPHeaderField: "X-Patient-Secret")
        _ = try await perform(req)
    }

    // MARK: Calm Mode

    public func evaluateCalm(patientId: String, _ r: CalmEvaluateRequest) async throws -> CalmDecision {
        try await send("POST", "v1/patients/\(patientId.pathEscaped)/calm/evaluate", body: r)
    }

    public func postCalmOutcome(patientId: String, _ o: CalmOutcome) async throws {
        try await sendNoContent("POST", "v1/patients/\(patientId.pathEscaped)/calm/outcome", body: o)
    }

    /// MP3 audio of the breathing guide. Throws `.voiceUnavailable` when the server has no voice key.
    public func calmScript(lang: Lang) async throws -> Data {
        var c = URLComponents(url: baseURL.appending(path: "v1/calm/script"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "lang", value: lang.rawValue)]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "GET"
        let (data, _) = try await perform(req)
        return data
    }

    // MARK: Plumbing

    private func request(_ method: String, _ path: String) -> URLRequest {
        var req = URLRequest(url: baseURL.appending(path: path))
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue(patientDeviceKey, forHTTPHeaderField: "X-Patient-Device-Key")
        return req
    }

    private func send<R: Decodable>(_ method: String, _ path: String) async throws -> R {
        let (data, _) = try await perform(request(method, path))
        return try JSONDecoder.tremor.decode(R.self, from: data)
    }

    private func send<B: Encodable, R: Decodable>(_ method: String, _ path: String, body: B) async throws -> R {
        let (data, _) = try await perform(withBody(request(method, path), body))
        return try JSONDecoder.tremor.decode(R.self, from: data)
    }

    private func sendNoContent(_ method: String, _ path: String) async throws {
        _ = try await perform(request(method, path))
    }

    private func sendNoContent<B: Encodable>(_ method: String, _ path: String, body: B) async throws {
        _ = try await perform(withBody(request(method, path), body))
    }

    private func withBody<B: Encodable>(_ req: URLRequest, _ body: B) throws -> URLRequest {
        try withBody(req, body, encoder: .tremor)
    }

    private func withSharingBody<B: Encodable>(_ req: URLRequest, _ body: B) throws -> URLRequest {
        let encoder = JSONEncoder.tremor
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try withBody(req, body, encoder: encoder)
    }

    private func withBody<B: Encodable>(_ req: URLRequest, _ body: B, encoder: JSONEncoder) throws -> URLRequest {
        var req = req
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(body)
        return req
    }

    private func perform(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.notHTTP }
        switch http.statusCode {
        case 200..<300: return (data, http)
        case 404: throw APIError.notFound
        case 503: throw APIError.voiceUnavailable
        default: throw APIError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
    }
}

extension String {
    var pathEscaped: String { addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? self }
}
