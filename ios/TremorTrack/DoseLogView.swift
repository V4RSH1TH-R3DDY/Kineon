// Log a dose with its time and anything that might affect tremor that day.
import SwiftUI
import TremorKit

struct DoseLogView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lastDoseLabel") private var label = "Levodopa"
    @State private var takenAt = Date()
    @State private var tags: Set<DoseTag> = []
    @State private var saving = false
    @State private var queued = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Medicine") {
                    if !model.medical.medications.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(model.medical.medications) { m in
                                    let name = [m.name, m.strength].filter { !$0.isEmpty }.joined(separator: " ")
                                    Button(name) { label = name }
                                        .buttonStyle(.glass)
                                        .tint(label == name ? .indigo : nil)
                                        .controlSize(.small)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                    TextField("Name", text: $label)
                    DatePicker("Taken at", selection: $takenAt, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                }
                Section {
                    ForEach(DoseTag.allCases, id: \.self) { tag in
                        Toggle(tag.title, systemImage: tag.icon, isOn: Binding(
                            get: { tags.contains(tag) },
                            set: { if $0 { tags.insert(tag) } else { tags.remove(tag) } }))
                    }
                } header: { Text("Today I had") } footer: {
                    Text("These show next to your readings, so your doctor can see what else was going on.")
                }
                if queued {
                    Label("Saved. It will upload when the server is reachable.", systemImage: "icloud.slash")
                        .foregroundStyle(.orange)
                }
            }
            .navigationTitle("Log a dose")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(saving || label.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .sensoryFeedback(.success, trigger: saving) { old, new in old && !new }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() async {
        saving = true
        let ok = await model.logDose(DoseEvent(takenAt: takenAt, label: label.trimmingCharacters(in: .whitespaces),
                                               tags: DoseTag.allCases.filter(tags.contains)))
        saving = false
        if ok { dismiss() } else { queued = true; try? await Task.sleep(for: .seconds(1.5)); dismiss() }
    }
}

extension DoseTag {
    var title: String {
        switch self { case .caffeine: "Coffee or tea"; case .stress: "Stress"; case .sleepPoor: "Poor sleep" }
    }
    var icon: String {
        switch self { case .caffeine: "cup.and.saucer.fill"; case .stress: "bolt.heart"; case .sleepPoor: "moon.zzz" }
    }
}
