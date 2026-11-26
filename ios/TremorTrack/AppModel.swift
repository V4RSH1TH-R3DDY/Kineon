// The iPhone app's state: setup, the latest reading, the patient's usual level, and the upload queue.
// Every window from the watch comes through here: it is posted to the backend, or queued on disk if that fails,
// and the score goes back to the watch.
import Foundation
import Observation
import TremorKit

@MainActor @Observable
final class AppModel {
    // MARK: Setup (persisted)

    var serverText: String { didSet { defaults.set(serverText, forKey: "serverURL") } }
    var patientIdText: String { didSet { defaults.set(patientIdText, forKey: "patientId"); pushToWatch() } }
    private(set) var consentId: String? { didSet { defaults.set(consentId, forKey: "consentId") } }
    private(set) var isSetUp: Bool { didSet { defaults.set(isSetUp, forKey: "setupDone") } }
    /// The signed-in person. Demo sign-in: kept on this iPhone only, nothing is verified.
    private(set) var account: Account? {
        didSet { defaults.set(account.flatMap { try? JSONEncoder().encode($0) }, forKey: "account") }
    }

    var server: URL? { SetupInput.serverURL(serverText) }
    var patientProblem: String? { SetupInput.patientIdProblem(patientIdText) }
    var patientId: String? { patientProblem == nil ? SetupInput.patientId(patientIdText) : nil }
    var api: APIClient? { server.map { APIClient(baseURL: $0) } }

    /// Medical details, kept on this iPhone only.
    private(set) var medical = MedicalInfo.load()

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

    let watch = PhoneWatchLink()
    /// Live accelerometer recording on the Tremor tab.
    let live = LiveTremor()

    private let defaults = UserDefaults.standard
    private let outboxURL = URL.applicationSupportDirectory.appending(path: "outbox.json")
    private var draining = false
    private var strap = StrapMonitor()

    init() {
        serverText = defaults.string(forKey: "serverURL") ?? "http://192.168.1.10:8000"
        patientIdText = defaults.string(forKey: "patientId") ?? ""
        consentId = defaults.string(forKey: "consentId")
        isSetUp = defaults.bool(forKey: "setupDone")
        account = defaults.data(forKey: "account").flatMap { try? JSONDecoder().decode(Account.self, from: $0) }
        try? FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        outbox = Outbox.load(from: outboxURL)
        watch.onWindow = { [weak self] w in Task { await self?.ingest(w) } }
        watch.onDose = { [weak self] d in Task { await self?.logDose(d) } }
        watch.onActivated = { [weak self] in self?.pushToWatch() }
        live.onWindow = { [weak self] w in await self?.ingestLive(w) ?? (nil, false) }
    }

    var usual: Double? { baseline?.medianScore }

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

    func finishSetup(shareWithClinic: Bool) async {
        isSetUp = true
        pushToWatch()
        await Alerts.shared.requestPermission()
        if shareWithClinic { _ = await setSharing(true) }
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
        consentId = nil
    }

    // MARK: Consent

    var isSharing: Bool { consentId != nil }

    /// Gives or withdraws consent for the clinic to export this patient's data. Returns false if the server said no.
    func setSharing(_ on: Bool) async -> Bool {
        guard let api, let patientId else { return false }
        do {
            if on {
                consentId = try await api.giveConsent(patientId: patientId).consentId
            } else if let id = consentId {
                do { try await api.withdrawConsent(patientId: patientId, consentId: id) } catch APIError.notFound {}
                consentId = nil
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: Readings

    func ingest(_ w: MotionWindow) async {
        var w = w
        if let patientId { w.patientId = patientId }
        lastWatchWindowAt = .now
        windowsReceived += 1
        do {
            let r = try await post(.window(w))
            show(r, at: w.startedAt, source: .watch)
            // Strap alerts are for what is happening now, not for all-day data collected hours later.
            if let r, Date().timeIntervalSince(w.startedAt) < 120, let alert = strap.check(r.reason) {
                Alerts.shared.post(id: "strap", title: alert.title, body: alert.body)
            }
            await drain()
        } catch {
            enqueue(.window(w))
        }
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
        await drain()
        await refreshTimeline()
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
        guard let api, let patientId else { return }
        do {
            async let b = api.baseline(patientId: patientId)
            async let t = api.timeline(patientId: patientId)
            baseline = try await b
            timeline = try await t
            serverReachable = true
            pushToWatch()
            if latest == nil, let p = timeline?.points.max(by: { $0.at < $1.at }) {
                latest = p.result; latestAt = p.at; latestSource = nil
                pushToWatch()
            }
        } catch APIError.notFound {
            // No readings yet for this patient.
            serverReachable = true
            timeline = nil
        } catch {
            serverReachable = false
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
