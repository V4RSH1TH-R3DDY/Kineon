// First run, in the style of Apple's welcome screens: a short welcome, then a native form for setup.
import SwiftUI
import TremorKit

struct OnboardingView: View {
    @State private var path: [Step] = []
    enum Step: Hashable { case setup }

    var body: some View {
        NavigationStack(path: $path) {
            Welcome { path.append(.setup) }
                .navigationDestination(for: Step.self) { _ in SetupForm() }
        }
    }
}

private struct Welcome: View {
    let next: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "waveform.path")
                        .font(.system(size: 52, weight: .semibold))
                        .foregroundStyle(.teal)
                    Text("Welcome to Kineon").font(.largeTitle.weight(.bold))
                    Text("Measure your tremor through the day, so your neurologist sees more than one short visit.")
                        .font(.title3).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 22) {
                    Feature(symbol: "applewatch", title: "Measured on your wrist",
                            text: "Your Apple Watch reads movement 50 times a second, all day.")
                    Feature(symbol: "hand.raised", title: "Everyday movement isn't counted",
                            text: "Brushing, walking and eating are set aside. Only tremor is scored.")
                    Feature(symbol: "pills", title: "Doses next to readings",
                            text: "Log each dose with one tap and see how your tremor follows it.")
                    Feature(symbol: "lock.shield", title: "You decide who sees it",
                            text: "Share a signed report with your clinic, and stop sharing any time.")
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 48)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button(action: next) {
                    Text("Continue").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                Disclaimer()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct Feature: View {
    let symbol: String, title: String, text: String
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.teal).frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SetupForm: View {
    @Environment(AppModel.self) private var model
    @State private var check: AppModel.ConnectionCheck?
    @State private var checking = false
    @State private var share = true
    @State private var finishing = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField("http://192.168.1.10:8000", text: $model.serverText)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onChange(of: model.serverText) { check = nil }
                Button {
                    Task { checking = true; check = await model.testConnection(); checking = false }
                } label: {
                    HStack {
                        Text("Test Connection")
                        Spacer()
                        if checking { ProgressView() }
                        else if let check {
                            Image(systemName: check.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(check.ok ? .green : .red)
                        }
                    }
                }
                .disabled(checking || model.server == nil)
            } header: {
                Text("Clinic server")
            } footer: {
                if let check, !check.ok { Text(check.message) }
                else if model.server == nil, !model.serverText.isEmpty { Text("Enter the full address, starting with http://") }
                else { Text("The address your clinic gave you.") }
            }

            Section {
                TextField("Patient ID", text: $model.patientIdText)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: {
                Text("Patient ID")
            } footer: {
                Text(model.patientIdText.isEmpty ? "Readings are saved under this ID." : (model.patientProblem ?? "Readings are saved under this ID."))
            }

            Section {
                Toggle("Share with my clinic", isOn: $share)
            } footer: {
                Text("Your clinic can download a signed report of your readings. You can turn this off at any time in Settings.")
            }
        }
        .navigationTitle("Set Up")
        .navigationBarTitleDisplayMode(.large)
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { finishing = true; await model.finishSetup(shareWithClinic: share); finishing = false }
            } label: {
                Group {
                    if finishing { ProgressView() } else { Text("Done").font(.headline) }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(model.server == nil || model.patientId == nil || finishing)
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
    }
}
