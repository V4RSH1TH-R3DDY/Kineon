// Sign-in screen: name plus email or phone, or Apple / Google.
// Demo only: the account is kept on this iPhone and nothing is verified. Real sign-in needs a backend with
// accounts, the paid Apple Developer Program (Sign in with Apple) and a Google OAuth client ID.
import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var model
    @State private var by: By = .email
    @State private var name = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var provider: Account.Method?
    @FocusState private var focus: Field?

    enum By: String, CaseIterable, Identifiable { case email = "Email", phone = "Phone"; var id: Self { self } }
    enum Field { case name, contact }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                form
                divider
                providers
                Text("Demo sign-in: your details stay on this iPhone. There's no password or code yet.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
            .padding(.horizontal, 24)
            .padding(.top, 56)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .headerWash()
        .sheet(item: $provider) { p in ProviderSheet(method: p) { model.signIn($0) } }
    }

    private var header: some View {
        VStack(spacing: 14) {
            IconTile(symbol: "waveform.path", tint: .teal, size: 84)
                .shadow(color: .teal.opacity(0.35), radius: 16, y: 8)
            Text("Kineon").font(.largeTitle.weight(.bold))
            Text("Sign in to track your tremor and share it with your neurologist.")
                .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private var form: some View {
        VStack(spacing: 14) {
            Picker("Sign in with", selection: $by) {
                ForEach(By.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: by) { focus = nil }

            VStack(spacing: 0) {
                field("person", "Full name", text: $name)
                    .textContentType(.name).textInputAutocapitalization(.words)
                    .focused($focus, equals: .name).submitLabel(.next)
                    .onSubmit { focus = .contact }
                Divider().padding(.leading, 48)
                Group {
                    if by == .email {
                        field("envelope", "Email address", text: $email)
                            .textContentType(.emailAddress).keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } else {
                        field("phone", "Phone number", text: $phone)
                            .textContentType(.telephoneNumber).keyboardType(.phonePad)
                    }
                }
                .focused($focus, equals: .contact).submitLabel(.go)
                .onSubmit(submit)
            }
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18, style: .continuous))

            if let problem, !(by == .email ? email : phone).isEmpty {
                Text(problem).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: submit) {
                Text("Continue").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(problem != nil)
        }
    }

    private func field(_ symbol: String, _ prompt: String, text: Binding<String>) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
            TextField(prompt, text: text)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
    }

    private var divider: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
            Text("or").font(.footnote).foregroundStyle(.secondary)
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
    }

    private var providers: some View {
        VStack(spacing: 12) {
            ProviderButton(method: .apple) { provider = .apple }
            ProviderButton(method: .google) { provider = .google }
        }
    }

    private var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter your name." }
        return by == .email ? Validate.email(email) : Validate.phone(phone)
    }

    private func submit() {
        guard problem == nil else { return }
        let contact = by == .email ? email.trimmingCharacters(in: .whitespaces) : phone.trimmingCharacters(in: .whitespaces)
        model.signIn(Account(name: name.trimmingCharacters(in: .whitespaces), contact: contact,
                             method: by == .email ? .email : .phone))
    }
}

extension Account.Method: Identifiable { var id: Self { self } }

enum Validate {
    static func email(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        let parts = t.split(separator: "@")
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !parts[1].hasSuffix("."), !t.contains(" ") else {
            return "Enter a valid email address."
        }
        return nil
    }

    static func phone(_ s: String) -> String? {
        let digits = s.filter(\.isNumber)
        return (10...15).contains(digits.count) ? nil : "Enter a phone number with 10 to 15 digits."
    }
}

/// "Continue with Apple" (black, or white in dark mode) and "Continue with Google" (outlined), as in their guidelines.
private struct ProviderButton: View {
    let method: Account.Method
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if method == .apple {
                    Image(systemName: "apple.logo").font(.title3)
                } else {
                    Text("G").font(.title3.weight(.bold))
                        .foregroundStyle(LinearGradient(colors: [.blue, .red, .yellow, .green],
                                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                Text("Continue with \(method.title)").font(.headline)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .foregroundStyle(fg)
            .background(bg, in: .capsule)
            .overlay { if method == .google { Capsule().stroke(Color(.separator), lineWidth: 1) } }
        }
        .buttonStyle(.plain)
    }

    private var fg: Color { method == .apple ? (scheme == .dark ? .black : .white) : .primary }
    private var bg: Color { method == .apple ? (scheme == .dark ? .white : .black) : Color(.secondarySystemGroupedBackground) }
}

/// Stands in for the Apple or Google sign-in sheet until real sign-in is set up.
private struct ProviderSheet: View {
    let method: Account.Method
    let done: (Account) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var email = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Full name", text: $name).textContentType(.name)
                    TextField("Email address", text: $email)
                        .textContentType(.emailAddress).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    Text("Demo: \(method.title) sign-in isn't connected yet, so enter the name and email it would share.")
                }
            }
            .navigationTitle("\(method.title) (Demo)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue", systemImage: "checkmark") {
                        done(Account(name: name.trimmingCharacters(in: .whitespaces),
                                     contact: email.trimmingCharacters(in: .whitespaces), method: method))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || Validate.email(email) != nil)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
