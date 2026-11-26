// The Account tab: who is signed in, patient ID, server, sharing consent, watch status, uploads, and log out.
import SwiftUI
import TremorKit

struct AccountView: View {
    @Environment(AppModel.self) private var model
    @State private var check: AppModel.ConnectionCheck?
    @State private var checking = false
    @State private var sharingBusy = false
    @State private var sharingError: String?
    @State private var sharingStatus: String?
    @State private var doctorCode = ""
    @State private var recordToShare: AppModel.DoctorApproval?
    @State private var confirmLogout = false
    /// Debug builds can open Medical Details with the launch argument `-uiMedical YES` (used for screenshots).
    @State private var showMedical = RootView.launchFlag("uiMedical")

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section { ProfileHeader() }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))

                Section {
                    NavigationLink {
                        MedicalDetailsView()
                    } label: {
                        HStack(spacing: 14) {
                            IconTile(symbol: "staroflife.fill", tint: .red, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Medical Details").font(.headline)
                                Text(model.medical.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if let account = model.account {
                    Section {
                        LabeledContent {
                            TextField("Name", text: Binding(get: { account.name }, set: { model.rename($0) }))
                                .multilineTextAlignment(.trailing).textContentType(.name)
                        } label: { tile("Name", "person.text.rectangle.fill", .indigo) }
                        LabeledContent {
                            Text(account.contact).lineLimit(1).truncationMode(.middle)
                        } label: {
                            tile(account.method == .phone ? "Phone" : "Email",
                                 account.method == .phone ? "phone.fill" : "envelope.fill", .blue)
                        }
                        LabeledContent {
                            Text(account.method.title)
                        } label: { tile("Signed in with", methodSymbol(account.method), .gray) }
                        LabeledContent {
                            Text(account.since, format: .dateTime.day().month().year())
                        } label: { tile("Member since", "calendar", .red) }
                    } header: { Text("Account") } footer: {
                        Text("Demo sign-in: these details are kept on this iPhone only.")
                    }
                }

                Section {
                    LabeledContent {
                        TextField("Patient ID", text: $model.patientIdText)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } label: { tile("Patient ID", "number", .teal) }
                    if let p = model.patientProblem { Text(p).font(.footnote).foregroundStyle(.red) }
                } header: { Text("Readings") } footer: { Text("Readings are saved on this iPhone and synced under this patient ID.") }

                Section {
                    LabeledContent {
                        TextField("http://<mac-lan-ip>:8000", text: $model.serverText)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    } label: { tile("Server", "server.rack", .gray) }
                    LabeledContent {
                        HStack(spacing: 6) {
                            Circle().fill(statusTint).frame(width: 8, height: 8)
                            Text(statusText)
                        }
                    } label: { tile("Status", "antenna.radiowaves.left.and.right", .green) }
                    .onChange(of: model.serverText) { check = nil }
                    Button(checking ? "Checking…" : "Test connection") {
                        Task { checking = true; check = await model.testConnection(); checking = false }
                    }
                    .disabled(checking || model.server == nil)
                    if let check {
                        Label(check.message, systemImage: check.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(check.ok ? .green : .red).font(.footnote)
                    }
                } header: { Text("Clinic server") } footer: {
                    Text("Only use a server on a network you trust. It has no sign-in.")
                }

                Section {
                    TextField("Six-digit code", text: $doctorCode)
                        .keyboardType(.numberPad)
                        .onChange(of: doctorCode) { _, value in
                            doctorCode = String(value.filter { "0123456789".contains($0) }.prefix(6))
                        }
                    Button("Approve live sharing") {
                        let code = doctorCode
                        Task {
                            await sharingAction("Approved. Ask your doctor to confirm on their dashboard.") {
                                try await model.approveDoctor(code: code)
                                doctorCode = ""
                            }
                        }
                    }
                    .disabled(sharingBusy || doctorCode.count != 6 || model.patientId == nil || model.server == nil)
                    if let sharingStatus { Text(sharingStatus).font(.footnote) }
                    if let sharingError { Text(sharingError).font(.footnote).foregroundStyle(.red) }
                } header: { Text("Live sharing with a doctor") } footer: {
                    Text("Enter your doctor's code to approve live tremor sharing. After they confirm, your readings and medical details are saved in your clinic file. Ending live sharing leaves the saved file available.")
                }

                if !model.doctorApprovals.isEmpty {
                    Section("Approved requests") {
                        ForEach(model.doctorApprovals) { approval in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(approval.approvedAt, format: .dateTime.month().day().hour().minute())
                                Button(approval.sharedRecord ? "Send updated medical record" : "Share medical record") {
                                    recordToShare = approval
                                }
                                Button("Stop live sharing", role: .destructive) {
                                    Task {
                                        await sharingAction("Live sharing stopped. Your saved file remains available.") {
                                            try await model.endDoctorAccess(approval)
                                        }
                                    }
                                }
                            }
                            .disabled(sharingBusy)
                        }
                    }
                }

                Section("Apple Watch") {
                    row("Watch paired", "applewatch", model.watch.paired)
                    row("Kineon on watch", "app.badge.checkmark", model.watch.watchAppInstalled)
                    row("In range now", "dot.radiowaves.left.and.right", model.watch.reachable)
                }

                Section {
                    LabeledContent { Text("\(model.pendingUploads)") } label: { tile("Waiting to upload", "icloud.and.arrow.up.fill", .orange) }
                    Button("Send now") { Task { await model.sendPending() } }.disabled(model.pendingUploads == 0)
                    if model.watchStorageFailed {
                        Text("A reading could not be saved on this iPhone.").font(.footnote).foregroundStyle(.red)
                    }
                } header: { Text("Uploads") }

                Section {
                    Button(role: .destructive) { confirmLogout = true } label: {
                        Text("Log Out").frame(maxWidth: .infinity)
                    }
                } footer: {
                    Text("Kineon tracks tremor. It doesn't diagnose.")
                }
            }
            .navigationTitle("Account")
            .navigationDestination(isPresented: $showMedical) { MedicalDetailsView() }
            .scrollContentBackground(.hidden)
            .headerWash()
            .confirmationDialog("Log out of Kineon?", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("Log Out", role: .destructive) { model.signOut() }
            } message: {
                Text("Your readings and clinic sharing stay on the server. Medical details on this iPhone are deleted. The watch stops tracking until you sign in again.")
            }
            .alert("Share your medical record?", isPresented: Binding(
                get: { recordToShare != nil },
                set: { if !$0 { recordToShare = nil } }
            ), presenting: recordToShare) { approval in
                Button("Cancel", role: .cancel) {}
                Button("Share record") {
                    Task {
                        await sharingAction("Medical record shared.") {
                            try await model.updateDoctorRecord(approval)
                        }
                    }
                }
            } message: { _ in
                Text("Your doctor will receive the current medical details saved on this iPhone, including medications, allergies and notes.")
            }
        }
    }

    private func sharingAction(_ success: String, _ action: () async throws -> Void) async {
        sharingBusy = true
        sharingError = nil
        sharingStatus = nil
        defer { sharingBusy = false }
        do {
            try await action()
            sharingStatus = success
        } catch APIError.notFound {
            sharingError = "This request could not be found or has expired. Ask your doctor for a new code."
        } catch APIError.http(let status, _) where status == 403 {
            sharingError = "The code was rejected. Check it with your doctor or ask for a new one."
        } catch APIError.http(let status, _) where status == 422 {
            sharingError = "The server could not accept these details. Review your medical record and try again."
        } catch {
            sharingError = "Could not complete the request. Check the connection and try again."
        }
    }

    private func row(_ label: String, _ symbol: String, _ ok: Bool) -> some View {
        LabeledContent {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(ok ? .green : .secondary)
        } label: { tile(label, symbol, .green) }
    }

    private var statusText: String {
        switch model.serverReachable { case true?: "Connected"; case false?: "Not reachable"; case nil: "Checking…" }
    }
    private var statusTint: Color {
        switch model.serverReachable { case true?: .green; case false?: .orange; case nil: .gray }
    }

    private func methodSymbol(_ m: Account.Method) -> String {
        switch m { case .email: "envelope.fill"; case .phone: "phone.fill"; case .apple: "apple.logo"; case .google: "globe" }
    }

    private func tile(_ title: String, _ symbol: String, _ tint: Color) -> some View {
        Label { Text(title) } icon: { IconTile(symbol: symbol, tint: tint, size: 30) }
    }
}

/// The top of Account, as in Apple's own apps: a monogram, the name and contact in plain type, and one strip of
/// figures separated by thin dividers (like the info strip on an App Store page).
private struct ProfileHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Text(model.account?.initials ?? "?")
                .font(.system(size: 34, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 84, height: 84)
                .background(LinearGradient(colors: [Color(white: 0.66), Color(white: 0.52)],
                                           startPoint: .top, endPoint: .bottom), in: .circle)
            VStack(spacing: 2) {
                Text(model.account?.name ?? "Not signed in").font(.title2.weight(.semibold))
                if let c = model.account?.contact { Text(c).font(.subheadline).foregroundStyle(.secondary) }
            }

            HStack(spacing: 0) {
                figure("\(readings)", "Readings")
                Divider().frame(height: 30)
                figure("\(daysTracked)", daysTracked == 1 ? "Day tracked" : "Days tracked")
                Divider().frame(height: 30)
                figure(model.usual.map { "\(Int($0.rounded()))" } ?? "–", "Usual score")
            }
            .padding(.vertical, 12)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var readings: Int { (model.timeline?.points ?? []).filter { $0.result.status == .ok }.count }
    private var daysTracked: Int {
        Set((model.timeline?.points ?? []).map { Calendar.current.startOfDay(for: $0.at) }).count
    }
}
