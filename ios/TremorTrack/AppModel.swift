// The iPhone app's state: setup, the latest reading, the patient's usual level, and the upload queue.
// Watch windows are saved before upload. Scored readings stay in the phone's history and go back to the watch.
import Foundation
import CryptoKit
import Observation
import TremorKit

@MainActor @Observable
final class AppModel {
    // MARK: Setup (persisted)

    var serverText: String {
        didSet {
            defaults.set(serverText, forKey: "serverURL")
            if oldValue != serverText { loadReadingHistory(); pushToWatch() }
        }
    }
    var patientIdText: String {
        didSet {
            defaults.set(patientIdText, forKey: "patientId")
            if oldValue != patientIdText { loadReadingHistory(); pushToWatch() }
        }
    }
    private(set) var isSetUp: Bool { didSet { defaults.set(isSetUp, forKey: "setupDone") } }
    /// The signed-in person. Demo sign-in: kept on this iPhone only, nothing is verified.
    private(set) var account: Account? {
        didSet { defaults.set(account.flatMap { try? JSONEncoder().encode($0) }, forKey: "account") }
    }

    var server: URL? { SetupInput.serverURL(serverText) }
    var patientProblem: String? { SetupInput.patientIdProblem(patientIdText) }
    var patientId: String? { patientProblem == nil ? SetupInput.patientId(patientIdText) : nil }
    var api: APIClient? { server.map { APIClient(baseURL: $0, patientDeviceKey: patientDeviceKey) } }

    /// The original medical details remain on this iPhone.
    private(set) var medical = MedicalInfo.load()
    private var approvals: [DoctorApproval] = []
    private let approvalsURL = URL.applicationSupportDirectory.appending(path: "doctor-approvals.json")

    // MARK: Live state

    private(set) var latest: ScoreResult?
    private(set) var latestAt: Date?
    private(set) var latestSource: Source?
    private(set) var baseline: Baseline?
    private(set) var timeline: Timeline?
    /// Nil until the first request; then whether the last request reached the server.
    private(set) var serverReachable: Bool?
    private(set) var windowsReceived = 0
    private(set) var lastWatchWindowAt: Date?
    private(set) var outbox: Outbox
    private(set) var watchUploads = 0
    private(set) var watchStorageFailed = false

    let watch = PhoneWatchLink()
    /// Live accelerometer recording on the Tremor tab.
    let live = LiveTremor()

    private let defaults = UserDefaults.standard
    private let patientDeviceKey: String = {
        let defaults = UserDefaults.standard
        if let key = defaults.string(forKey: "patientDeviceKey") { return key }
        let key = UUID().uuidString + UUID().uuidString
        defaults.set(key, forKey: "patientDeviceKey")
        return key
    }()
    private let outboxURL = URL.applicationSupportDirectory.appending(path: "outbox.json")
    private var draining = false
    private var drainingWatch = false
    private var strap = StrapMonitor()

    init() {
        serverText = defaults.string(forKey: "serverURL") ?? "http://192.168.1.10:8000"
        patientIdText = defaults.string(forKey: "patientId") ?? ""
        isSetUp = defaults.bool(forKey: "setupDone")
        account = defaults.data(forKey: "account").flatMap { try? JSONDecoder().decode(Account.self, from: $0) }
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        outbox = Outbox.load(from: outboxURL)
        if let data = try? Data(contentsOf: approvalsURL),
           let saved = try? JSONDecoder().decode([DoctorApproval].self, from: data) {
            approvals = saved
        }
        loadReadingHistory()
        watch.onWindow = { [weak self] w in Task { await self?.ingest(w) } }
        watch.onDose = { [weak self] d in Task { await self?.logDose(d) } }
        watch.onActivated = { [weak self] in self?.pushToWatch() }
        live.onWindow = { [weak self] w in await self?.ingestLive(w) ?? (nil, false) }
    }

    var usual: Double? { baseline?.medianScore }
    var pendingUploads: Int { outbox.count + watchUploads }

    // MARK: Setup

    struct ConnectionCheck: Equatable { let ok: Bool; let message: String }

    /// Scores one simulated window under a throwaway ID. Proves the network path and the contract end to end.
    func testConnection() async -> ConnectionCheck {
        guard let api else { return ConnectionCheck(ok: false, message: "Enter the full address, starting with http://") }
        let window = SyntheticSignal.window(patientId: "setup-check", source: .phone, tremorHz: 6, tremorAmp: 0.1)
        do {
            _ = try await api.postPhoneTest(window)
            serverReachable = true
            return ConnectionCheck(ok: true, message: "Connected to the server.")
        } catch {
            serverReachable = false
            return ConnectionCheck(ok: false, message: "Could not reach the server: \(error.localizedDescription)")
        }
    }

    func finishSetup() async {
        isSetUp = true
        pushToWatch()
        await Alerts.shared.requestPermission()
        await refresh()
    }

    func resetSetup() {
        isSetUp = false
        latest = nil; latestAt = nil; latestSource = nil; baseline = nil; timeline = nil
        pushToWatch()
    }

    // MARK: Account

    func signIn(_ a: Account) {
        account = a
        if patientIdText.isEmpty { patientIdText = a.suggestedPatientId }
    }

    func rename(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, var a = account else { return }
        a.name = n
        account = a
    }

    func saveMedical(_ m: MedicalInfo) {
        var m = m
        m.updatedAt = .now
        medical = m
        m.save()
    }

    /// Signs out and clears this phone's setup and medical details. Readings and any clinic sharing stay on the server.
    func signOut() {
        account = nil
        medical = MedicalInfo()
        MedicalInfo.erase()
        resetSetup()
        patientIdText = ""
    }

    // MARK: Consent

    struct DoctorApproval: Codable, Identifiable {
        var id: String { link.linkId }
        let link: APIClient.ApprovedLink
        let server: URL
        let patientId: String
        let approvedAt: Date
        var sharedRecord: Bool
    }

    var doctorApprovals: [DoctorApproval] {
        approvals.filter { $0.patientId == patientId && $0.server == server }
    }

    func approveDoctor(code: String) async throws {
        guard let api, let patientId else { throw URLError(.badURL) }
        let record = medical.isEmpty ? nil : medical.sharedRecord
        let link = try await api.approveLink(patientId: patientId, code: code, record: record)
        let approval = DoctorApproval(link: link, server: api.baseURL, patientId: patientId, approvedAt: .now, sharedRecord: record != nil)
        do {
            try saveApprovals(approvals + [approval])
        } catch {
            try? await api.revokeLink(linkId: link.linkId, patientSecret: link.patientSecret)
            throw error
        }
    }

    func updateDoctorRecord(_ approval: DoctorApproval) async throws {
        guard doctorApprovals.contains(where: { $0.id == approval.id }) else { throw URLError(.badURL) }
        try await APIClient(baseURL: approval.server)
            .updateLinkRecord(linkId: approval.id, patientSecret: approval.link.patientSecret, record: medical.sharedRecord)
        var updated = approvals
        if let i = updated.firstIndex(where: { $0.id == approval.id }) {
            updated[i].sharedRecord = true
            try saveApprovals(updated)
        }
    }

    func endDoctorAccess(_ approval: DoctorApproval) async throws {
        do {
            try await APIClient(baseURL: approval.server).revokeLink(linkId: approval.id, patientSecret: approval.link.patientSecret)
        } catch APIError.notFound {}
        try saveApprovals(approvals.filter { $0.id != approval.id })
    }

    private func saveApprovals(_ updated: [DoctorApproval]) throws {
        try JSONEncoder().encode(updated).write(to: approvalsURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        approvals = updated
    }

    // MARK: Readings

    func ingest(_ w: MotionWindow) async {
        guard let scope = readingScope, w.patientId == scope.patientId else { return }
        lastWatchWindowAt = max(lastWatchWindowAt ?? .distantPast, w.startedAt)
        windowsReceived += 1
        do {
            try scope.save(w)
            watchUploads = scope.pending.count
            watchStorageFailed = false
        } catch {
            watchStorageFailed = true
            return
        }
        await drainWatch()
    }

    /// A 10-second window from a live recording: scored like any other, queued if the server is down,
    /// and the history reloaded so the live reading appears in it straight away.
    func ingestLive(_ w: MotionWindow) async -> (ScoreResult?, Bool) {
        var w = w
        if let patientId { w.patientId = patientId }
        do {
            let r = try await post(.window(w))
            show(r, at: w.startedAt, source: .phone)
            await refreshTimeline()
            return (r, false)
        } catch {
            enqueue(.window(w))
            return (nil, true)
        }
    }

    /// A phone test result, so it shows on the home screen too.
    func notePhoneTest(_ r: ScoreResult, at: Date) {
        show(r, at: at, source: .phone)
        Task { await refresh() }
    }

    /// Posts a dose, or queues it. Returns true if it reached the server now.
    @discardableResult
    func logDose(_ d: DoseEvent) async -> Bool {
        guard let patientId else { return false }
        do {
            _ = try await post(.dose(patientId: patientId, d))
            await refreshTimeline()
            return true
        } catch {
            enqueue(.dose(patientId: patientId, d))
            return false
        }
    }

    func refresh() async {
        await sendPending()
        await refreshTimeline()
    }

    func sendPending() async {
        await drainWatch()
        await drain()
    }

    private func drainWatch() async {
        guard !drainingWatch, let scope = readingScope else { return }
        drainingWatch = true
        defer {
            drainingWatch = false
            watchUploads = readingScope?.pending.count ?? 0
        }
        let client = APIClient(baseURL: scope.server, patientDeviceKey: patientDeviceKey)
        while readingScope == scope {
            let pending = scope.pending
            if pending.isEmpty { return }
            for file in pending {
                guard readingScope == scope else { return }
                do {
                    let window = try JSONDecoder.tremor.decode(MotionWindow.self, from: Data(contentsOf: file))
                    let result: ScoreResult
                    do {
                        result = try await client.postWindow(window, uploadId: file.deletingPathExtension().lastPathComponent)
                        if readingScope == scope { serverReachable = true }
                    } catch {
                        if readingScope == scope { serverReachable = error is APIError }
                        return
                    }
                    let visible = readingScope == scope
                    var history = (visible ? timeline : scope.loadHistory()) ?? Timeline(patientId: scope.patientId)
                    let point = TimelinePoint(at: window.startedAt, result: result)
                    if !history.points.contains(point) {
                        history.points.append(point)
                        history.points.sort { $0.at < $1.at }
                    }
                    try scope.saveHistory(history)
                    try FileManager.default.removeItem(at: file)
                    if visible {
                        timeline = history
                        watchStorageFailed = false
                        show(result, at: window.startedAt, source: .watch)
                        if Date().timeIntervalSince(window.startedAt) < 120, let alert = strap.check(result.reason) {
                            Alerts.shared.post(id: "strap", title: alert.title, body: alert.body)
                        }
                    }
                } catch {
                    if readingScope == scope { watchStorageFailed = true }
                    return
                }
            }
        }
    }

    /// Retries queued readings oldest first.
    func drain() async {
        guard !draining, !outbox.isEmpty, api != nil else { return }
        draining = true
        defer { draining = false }
        var box = outbox
        let sent = await box.drain { [self] item in _ = try await post(item) }
        outbox = box
        if sent > 0 { outbox.save(to: outboxURL) }
    }

    private func refreshTimeline() async {
        guard let scope = readingScope else { return }
        let api = APIClient(baseURL: scope.server, patientDeviceKey: patientDeviceKey)
        do {
            async let b = api.baseline(patientId: scope.patientId)
            async let t = api.timeline(patientId: scope.patientId)
            let (newBaseline, fetchedHistory) = try await (b, t)
            var history = fetchedHistory
            guard readingScope == scope else { return }
            let serverPoints = Set(history.points.map(\.at))
            let cachedPoints = timeline?.points ?? []
            history.points.append(contentsOf: cachedPoints.filter { !serverPoints.contains($0.at) })
            history.points.sort { $0.at < $1.at }
            baseline = newBaseline
            timeline = history
            do { try scope.saveHistory(history) } catch { watchStorageFailed = true }
            serverReachable = true
            pushToWatch()
            if latest == nil, let p = timeline?.points.max(by: { $0.at < $1.at }) {
                latest = p.result; latestAt = p.at; latestSource = nil
                pushToWatch()
            }
        } catch APIError.notFound {
            if readingScope == scope { serverReachable = true }
        } catch {
            if readingScope == scope { serverReachable = false }
        }
    }

    private var readingScope: ReadingScope? {
        guard let server, let patientId else { return nil }
        return ReadingScope(server: server, patientId: patientId)
    }

    private func loadReadingHistory() {
        latest = nil; latestAt = nil; latestSource = nil; baseline = nil
        timeline = readingScope?.loadHistory()
        watchUploads = readingScope?.pending.count ?? 0
        watchStorageFailed = false
        if let point = timeline?.points.last {
            latest = point.result
            latestAt = point.at
        }
    }

    private func post(_ item: Outbox.Item) async throws -> ScoreResult? {
        guard let api else { throw URLError(.badURL) }
        do {
            switch item {
            case let .window(w): let r = try await api.postWindow(w); serverReachable = true; return r
            case let .dose(pid, d): try await api.postDose(patientId: pid, d); serverReachable = true; return nil
            }
        } catch let e as APIError {
            // The server answered. A rejected item would fail forever, so it is not retried.
            serverReachable = true
            if case .http(let status, _) = e, (400..<500).contains(status) { return nil }
            throw e
        } catch {
            serverReachable = false
            throw error
        }
    }

    private func enqueue(_ item: Outbox.Item) {
        outbox.append(item)
        outbox.save(to: outboxURL)
    }

    private func show(_ r: ScoreResult?, at: Date, source: Source) {
        // All-day windows arrive late and out of order; only a newer reading replaces the one shown.
        guard let r, at >= latestAt ?? .distantPast else { return }
        latest = r; latestAt = at; latestSource = source
        pushToWatch()
    }

    private func pushToWatch() {
        watch.push(PhoneContext(patientId: isSetUp ? patientId : nil, latest: latest, latestAt: latestAt,
                                usual: baseline?.medianScore))
    }
}

private struct ReadingScope: Equatable {
    let server: URL
    let patientId: String

    private var directory: URL {
        let key = SHA256.hash(data: Data("\(server.absoluteString)\n\(patientId)".utf8))
        return URL.applicationSupportDirectory.appending(path: "readings/\(key.map { String(format: "%02x", $0) }.joined())")
    }

    private var historyURL: URL { directory.appending(path: "history.json") }
    private var pendingURL: URL { directory.appending(path: "pending") }

    var pending: [URL] {
        let files = try? FileManager.default.contentsOfDirectory(at: pendingURL, includingPropertiesForKeys: nil)
        return (files ?? []).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func save(_ window: MotionWindow) throws {
        try FileManager.default.createDirectory(at: pendingURL, withIntermediateDirectories: true)
        let file = pendingURL.appending(path: "\(WireDate.format(window.startedAt)).json")
        try JSONEncoder.tremor.encode(window).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func loadHistory() -> Timeline? {
        guard let data = try? Data(contentsOf: historyURL) else { return nil }
        return try? JSONDecoder.tremor.decode(Timeline.self, from: data)
    }

    func saveHistory(_ history: Timeline) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder.tremor.encode(history).write(to: historyURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// A demo account: who is using the app and how they signed in. Not verified by any server.
struct Account: Codable, Equatable {
    enum Method: String, Codable { case email, phone, apple, google
        var title: String { switch self { case .email: "Email"; case .phone: "Phone"; case .apple: "Apple"; case .google: "Google" } }
    }
    var name: String
    var contact: String
    var method: Method
    var since: Date = .now

    var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }

    var initials: String {
        let parts = name.split(separator: " ").prefix(2).compactMap(\.first)
        return parts.isEmpty ? "?" : parts.map { String($0).uppercased() }.joined()
    }

    /// A patient ID from the name, e.g. "Raghu Rao" → "raghu-rao". The user can change it in setup.
    var suggestedPatientId: String {
        let slug = name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
        return slug.split(separator: "-").joined(separator: "-").prefix(40).description
    }
}
