// Step 1 screen: proves the app installs, reaches the backend over the LAN, and sees the watch app.
// Replaced by the real setup and home screens in step 3.
import SwiftUI
import TremorKit

struct SetupCheckView: View {
    @Environment(PhoneWatchLink.self) private var watch
    @AppStorage("serverURL") private var serverURL = "http://192.168.1.10:8000"
    @AppStorage("patientId") private var patientId = ""
    @State private var result: String?
    @State private var checking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server address", text: $serverURL, prompt: Text("http://<mac-lan-ip>:8000"))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: serverURL) { result = nil }
                    Button(checking ? "Checking…" : "Test connection") { Task { await check() } }
                        .disabled(checking || server == nil)
                    if let result { Text(result).font(.callout) }
                } header: {
                    Text("Server address")
                } footer: {
                    if server == nil, !serverURL.isEmpty {
                        Text("Enter the full address, starting with http://, for example http://10.20.167.77:8000").foregroundStyle(.red)
                    }
                }
                Section {
                    TextField("Patient ID", text: $patientId, prompt: Text("e.g. aniket-test"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if let server, patientProblem == nil {
                        NavigationLink("30-second phone test") {
                            PhoneTestView(api: APIClient(baseURL: server), patientId: SetupInput.patientId(patientId))
                        }
                    } else {
                        Text("30-second phone test").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Patient ID")
                } footer: {
                    if let patientProblem, !patientId.isEmpty {
                        Text(patientProblem).foregroundStyle(.red)
                    } else {
                        Text("Use the ID your clinic gave you. Readings are saved under it.")
                    }
                }
                Section("Watch") {
                    row("WatchConnectivity", watch.supported)
                    row("Watch paired", watch.paired)
                    row("Watch app installed", watch.watchAppInstalled)
                    row("Watch reachable now", watch.reachable)
                }
            }
            .navigationTitle("TremorTrack+")
        }
    }

    private var server: URL? { SetupInput.serverURL(serverURL) }
    private var patientProblem: String? { SetupInput.patientIdProblem(patientId) }

    private func row(_ label: String, _ ok: Bool) -> some View {
        LabeledContent(label) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(ok ? .green : .secondary)
        }
    }

    /// Scores one simulated window. A real "ok" result proves the network path and the contract end to end.
    private func check() async {
        checking = true
        defer { checking = false }
        guard let url = server else { result = "Enter the full address, starting with http://"; return }
        let window = SyntheticSignal.window(patientId: "setup-check", source: .phone, tremorHz: 6, tremorAmp: 0.1)
        do {
            let r = try await APIClient(baseURL: url).postPhoneTest(window)
            switch ScoreDisplay(r) {
            case let .score(v, _, _): result = "Connected. Simulated signal scored \(v.formatted())."
            case let .notEnoughData(reason): result = "Connected, but the simulated signal was refused: \(reason)"
            }
        } catch {
            result = "Could not reach the server: \(error.localizedDescription)"
        }
    }
}
