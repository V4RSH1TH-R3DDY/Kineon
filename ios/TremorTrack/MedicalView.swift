// Medical Details: a read-only summary in cards (like Medical ID), with an editor sheet behind "Edit".
import SwiftUI

struct MedicalDetailsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing = false

    var body: some View {
        let m = model.medical
        ScrollView {
            if m.isEmpty {
                ContentUnavailableView {
                    Label("No medical details", systemImage: "staroflife.fill")
                } description: {
                    Text("Add your diagnosis, medication and emergency contacts, so they're ready when your doctor or family needs them.")
                } actions: {
                    Button("Add Medical Details") { editing = true }.buttonStyle(.glassProminent)
                }
                .padding(.top, 60)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    header(m)
                    if hasAbout(m) { aboutCard(m) }
                    if m.diagnosis != nil || !m.symptoms.isEmpty || m.hasDBS { conditionCard(m) }
                    if !m.medications.isEmpty { medicationsCard(m) }
                    if !m.allergies.isEmpty || !m.otherConditions.isEmpty { otherHealthCard(m) }
                    if !m.neurologist.isEmpty || !m.familyDoctor.isEmpty { careTeamCard(m) }
                    if !m.emergencyContacts.isEmpty { emergencyCard(m) }
                    if !m.notes.isEmpty {
                        Card {
                            CardHeader(title: "Notes", symbol: "note.text", tint: .gray)
                            Text(m.notes).font(.body)
                        }
                    }
                    Label("Kept on this iPhone only and encrypted while it's locked. Not sent to the server.",
                          systemImage: "lock.fill")
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .headerWash(.red)
        .navigationTitle("Medical Details")
        .toolbar {
            if !m.isEmpty { Button("Edit") { editing = true } }
        }
        .sheet(isPresented: $editing) { MedicalEditor(draft: model.medical) { model.saveMedical($0) } }
    }

    // MARK: Cards

    private func header(_ m: MedicalInfo) -> some View {
        Card {
            HStack(spacing: 14) {
                IconTile(symbol: "staroflife.fill", tint: .red, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.account?.name ?? "Medical Details").font(.title2.weight(.bold))
                    Text([m.age.map { "\($0) years" }, m.sex?.title, m.bloodType.map { "Blood \($0.rawValue)" }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if let u = m.updatedAt {
                Text("Updated \(u.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func hasAbout(_ m: MedicalInfo) -> Bool {
        m.birthDate != nil || m.heightCm != nil || m.weightKg != nil || m.dominantHand != nil
    }

    private func aboutCard(_ m: MedicalInfo) -> some View {
        Card {
            CardHeader(title: "About You", symbol: "person.fill", tint: .blue)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                      alignment: .leading, spacing: 14) {
                if let b = m.birthDate { fact("Born", b.formatted(.dateTime.day().month(.abbreviated).year())) }
                if let h = m.heightCm { fact("Height", "\(Int(h)) cm") }
                if let w = m.weightKg { fact("Weight", "\(w.formatted(.number.precision(.fractionLength(0...1)))) kg") }
                if let d = m.dominantHand { fact("Writes with", d == .both ? "Both hands" : "\(d.title) hand") }
            }
        }
    }

    private func conditionCard(_ m: MedicalInfo) -> some View {
        Card {
            CardHeader(title: "Condition", symbol: "brain.head.profile", tint: .purple)
            if let d = m.diagnosis {
                Text(d == .other && !m.diagnosisOther.isEmpty ? m.diagnosisOther : d.title).font(.title3.weight(.semibold))
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 14) {
                if let y = m.symptomsSinceYear { fact("Symptoms since", String(y)) }
                if let y = m.diagnosedYear { fact("Diagnosed", String(y)) }
                if let s = m.affectedSide { fact("Side affected", s == .both ? "Both sides" : "\(s.title) side") }
                if let s = m.stage { fact("Stage", "\(s) of 5") }
                if m.hasDBS { fact("Deep brain stimulation", m.dbsSinceYear.map { "Since \(String($0))" } ?? "Yes") }
            }
            if !m.symptoms.isEmpty {
                Text("Symptoms").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                FlowLayout(spacing: 6) {
                    ForEach(MedicalInfo.Symptom.allCases.filter(m.symptoms.contains)) { s in
                        Text(s.title).font(.footnote.weight(.medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.purple.opacity(0.12), in: .capsule)
                            .foregroundStyle(.purple)
                    }
                }
            }
        }
    }

    private func medicationsCard(_ m: MedicalInfo) -> some View {
        Card {
            CardHeader(title: "Medication", symbol: "pills.fill", tint: .indigo)
            ForEach(Array(m.medications.enumerated()), id: \.element.id) { i, med in
                if i > 0 { Divider().padding(.leading, 48) }
                HStack(alignment: .top, spacing: 12) {
                    IconTile(symbol: med.form == .liquid ? "drop.fill" : med.form == .patch ? "bandage.fill" : "pills.fill",
                             tint: .indigo, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text([med.name, med.strength].filter { !$0.isEmpty }.joined(separator: " ")).font(.body.weight(.semibold))
                        Text(med.schedule).font(.subheadline).foregroundStyle(.secondary)
                        if let food = med.withFood {
                            Text(food ? "With food" : "On an empty stomach").font(.caption).foregroundStyle(.secondary)
                        }
                        if !med.notes.isEmpty { Text(med.notes).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }

    private func otherHealthCard(_ m: MedicalInfo) -> some View {
        Card {
            CardHeader(title: "Allergies & Other Conditions", symbol: "allergens", tint: .orange)
            if !m.allergies.isEmpty { fact("Allergies and reactions", m.allergies) }
            if !m.otherConditions.isEmpty { fact("Other conditions", m.otherConditions) }
        }
    }

    private func careTeamCard(_ m: MedicalInfo) -> some View {
        Card {
            CardHeader(title: "Care Team", symbol: "stethoscope", tint: .teal)
            if !m.neurologist.isEmpty { person("Neurologist", m.neurologist.name, m.neurologist.clinic, m.neurologist.phone) }
            if !m.neurologist.isEmpty, !m.familyDoctor.isEmpty { Divider() }
            if !m.familyDoctor.isEmpty { person("Family doctor", m.familyDoctor.name, m.familyDoctor.clinic, m.familyDoctor.phone) }
        }
    }

    private func emergencyCard(_ m: MedicalInfo) -> some View {
        Card {
            CardHeader(title: "Emergency Contacts", symbol: "phone.fill", tint: .red)
            ForEach(Array(m.emergencyContacts.enumerated()), id: \.element.id) { i, c in
                if i > 0 { Divider() }
                person(c.relationship.isEmpty ? "Contact" : c.relationship, c.name, "", c.phone)
            }
        }
    }

    // MARK: Pieces

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.weight(.medium))
        }
    }

    private func person(_ role: String, _ name: String, _ detail: String, _ phone: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(role).font(.caption).foregroundStyle(.secondary)
                Text(name.isEmpty ? phone : name).font(.body.weight(.semibold))
                if !detail.isEmpty { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
            }
            Spacer()
            if let url = Self.callURL(phone) {
                Link(destination: url) {
                    Image(systemName: "phone.fill").font(.body.weight(.semibold))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .tint(.green)
                .accessibilityLabel("Call \(name.isEmpty ? role : name)")
            }
        }
    }

    static func callURL(_ phone: String) -> URL? {
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        return digits.count >= 6 ? URL(string: "tel:\(digits)") : nil
    }
}

/// Wraps chips onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, p) in arrange(width: bounds.width, subviews).points.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += row + spacing; row = 0 }
            points.append(CGPoint(x: x, y: y))
            x += s.width + spacing
            row = max(row, s.height)
            maxX = max(maxX, x - spacing)
        }
        return (points, CGSize(width: maxX, height: y + row))
    }
}

// MARK: - Editor

struct MedicalEditor: View {
    @State var draft: MedicalInfo
    let save: (MedicalInfo) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var original: MedicalInfo?
    @State private var path: [UUID] = []

    private static let years: [Int] = {
        let now = Calendar.current.component(.year, from: .now)
        return Array((now - 70)...now).reversed()
    }()

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                aboutSection
                conditionSection
                medicationSection
                Section("Allergies & Other Conditions") {
                    TextField("Allergies and reactions, e.g. penicillin: rash", text: $draft.allergies, axis: .vertical)
                    TextField("Other conditions, e.g. diabetes, high blood pressure", text: $draft.otherConditions, axis: .vertical)
                }
                careSection("Neurologist", $draft.neurologist)
                careSection("Family Doctor", $draft.familyDoctor)
                emergencySection
                Section("Notes") {
                    TextField("Anything else your doctor or family should know", text: $draft.notes, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle("Medical Details")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { id in
                if let i = draft.medications.firstIndex(where: { $0.id == id }) {
                    MedicationEditor(med: $draft.medications[i])
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") {
                        draft.medications.removeAll { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }
                        draft.emergencyContacts.removeAll { $0.name.isEmpty && $0.phone.isEmpty }
                        save(draft)
                        dismiss()
                    }
                }
            }
            .interactiveDismissDisabled(original != nil && original != draft)
            .onAppear { if original == nil { original = draft } }
        }
    }

    private var aboutSection: some View {
        Section("About You") {
            OptionalDateRow(title: "Date of birth", date: $draft.birthDate,
                            defaultDate: Calendar.current.date(byAdding: .year, value: -60, to: .now)!)
            Picker("Sex", selection: $draft.sex) {
                Text("Not set").tag(MedicalInfo.Sex?.none)
                ForEach(MedicalInfo.Sex.allCases) { Text($0.title).tag(Optional($0)) }
            }
            LabeledContent("Height") {
                TextField("cm", value: $draft.heightCm, format: .number).keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Weight") {
                TextField("kg", value: $draft.weightKg, format: .number).keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            }
            Picker("Blood type", selection: $draft.bloodType) {
                Text("Not set").tag(MedicalInfo.BloodType?.none)
                ForEach(MedicalInfo.BloodType.allCases) { Text($0.rawValue).tag(Optional($0)) }
            }
            Picker("Writing hand", selection: $draft.dominantHand) {
                Text("Not set").tag(MedicalInfo.Side?.none)
                ForEach(MedicalInfo.Side.allCases) { Text($0 == .both ? "Both" : $0.title).tag(Optional($0)) }
            }
        }
    }

    private var conditionSection: some View {
        Section {
            Picker("Diagnosis", selection: $draft.diagnosis) {
                Text("Not set").tag(MedicalInfo.Diagnosis?.none)
                ForEach(MedicalInfo.Diagnosis.allCases) { Text($0.title).tag(Optional($0)) }
            }
            if draft.diagnosis == .other {
                TextField("Name of the condition", text: $draft.diagnosisOther)
            }
            yearPicker("Symptoms started", $draft.symptomsSinceYear)
            if draft.diagnosis != .notYet { yearPicker("Year diagnosed", $draft.diagnosedYear) }
            Picker("Side most affected", selection: $draft.affectedSide) {
                Text("Not set").tag(MedicalInfo.Side?.none)
                ForEach(MedicalInfo.Side.allCases) { Text($0.title).tag(Optional($0)) }
            }
            if draft.diagnosis == .parkinsons {
                Picker("Stage", selection: $draft.stage) {
                    Text("Not known").tag(Int?.none)
                    ForEach(1...5, id: \.self) { Text(MedicalInfo.stageTitle($0)).tag(Optional($0)) }
                }
            }
            NavigationLink {
                SymptomPicker(selected: $draft.symptoms)
            } label: {
                LabeledContent("Symptoms", value: draft.symptoms.isEmpty ? "None" : "\(draft.symptoms.count) selected")
            }
            Toggle("Deep brain stimulation", isOn: $draft.hasDBS)
            if draft.hasDBS { yearPicker("Implanted in", $draft.dbsSinceYear) }
        } header: {
            Text("Condition")
        } footer: {
            Text("Stage is the Hoehn and Yahr stage your neurologist records. Leave it as Not known if you're unsure.")
        }
    }

    private var medicationSection: some View {
        Section {
            ForEach(draft.medications) { med in
                NavigationLink(value: med.id) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(med.name.isEmpty ? "New medication" : [med.name, med.strength].filter { !$0.isEmpty }.joined(separator: " "))
                        Text(med.schedule).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { draft.medications.remove(atOffsets: $0) }
            Button("Add Medication", systemImage: "plus.circle.fill") {
                let med = Medication()
                draft.medications.append(med)
                path.append(med.id)
            }
        } header: {
            Text("Medication")
        } footer: {
            Text("Your medications also appear as quick picks when you log a dose.")
        }
    }

    private func careSection(_ title: String, _ c: Binding<CareContact>) -> some View {
        Section(title) {
            TextField("Name, e.g. Dr. Meera Rao", text: c.name).textContentType(.name)
            TextField("Clinic or hospital", text: c.clinic).textContentType(.organizationName)
            TextField("Phone", text: c.phone).textContentType(.telephoneNumber).keyboardType(.phonePad)
        }
    }

    private var emergencySection: some View {
        Section {
            ForEach($draft.emergencyContacts) { $c in
                VStack(spacing: 10) {
                    TextField("Name", text: $c.name).textContentType(.name)
                    Divider()
                    TextField("Relationship, e.g. Daughter", text: $c.relationship)
                    Divider()
                    TextField("Phone", text: $c.phone).textContentType(.telephoneNumber).keyboardType(.phonePad)
                }
                .padding(.vertical, 4)
            }
            .onDelete { draft.emergencyContacts.remove(atOffsets: $0) }
            Button("Add Emergency Contact", systemImage: "plus.circle.fill") {
                draft.emergencyContacts.append(EmergencyContact())
            }
        } header: {
            Text("Emergency Contacts")
        } footer: {
            Text("Swipe left on a contact to remove it.")
        }
    }

    private func yearPicker(_ title: String, _ value: Binding<Int?>) -> some View {
        Picker(title, selection: value) {
            Text("Not set").tag(Int?.none)
            ForEach(Self.years, id: \.self) { Text(String($0)).tag(Optional($0)) }
        }
    }
}

/// A date that may be unset: "Add" until chosen, then a date picker with a clear button.
private struct OptionalDateRow: View {
    let title: String
    @Binding var date: Date?
    let defaultDate: Date

    var body: some View {
        if let d = date {
            HStack {
                DatePicker(title, selection: Binding(get: { d }, set: { date = $0 }), in: ...Date.now,
                           displayedComponents: .date)
                Button("Clear", systemImage: "xmark.circle.fill") { date = nil }
                    .labelStyle(.iconOnly).foregroundStyle(.secondary).buttonStyle(.plain)
            }
        } else {
            LabeledContent(title) { Button("Add") { date = defaultDate } }
        }
    }
}

private struct SymptomPicker: View {
    @Binding var selected: Set<MedicalInfo.Symptom>

    var body: some View {
        List(MedicalInfo.Symptom.allCases) { s in
            Button {
                if selected.contains(s) { selected.remove(s) } else { selected.insert(s) }
            } label: {
                HStack {
                    Text(s.title).foregroundStyle(.primary)
                    Spacer()
                    if selected.contains(s) { Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold) }
                }
            }
        }
        .navigationTitle("Symptoms")
    }
}

private struct MedicationEditor: View {
    @Binding var med: Medication

    private static let common = [
        "Levodopa/Carbidopa", "Levodopa/Benserazide", "Pramipexole", "Ropinirole", "Rasagiline", "Selegiline",
        "Safinamide", "Entacapone", "Opicapone", "Amantadine", "Trihexyphenidyl", "Propranolol", "Primidone",
    ]

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Name", text: $med.name)
                    Menu {
                        ForEach(Self.common, id: \.self) { n in Button(n) { med.name = n } }
                    } label: {
                        Image(systemName: "list.bullet.circle.fill").font(.title3)
                    }
                    .accessibilityLabel("Common medicines")
                }
                TextField("Strength, e.g. 100/25 mg", text: $med.strength)
                Picker("Form", selection: $med.form) {
                    ForEach(Medication.DoseForm.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Amount per dose") {
                    TextField("1", text: $med.amount).multilineTextAlignment(.trailing).keyboardType(.decimalPad)
                }
            } header: { Text("Medicine") }

            Section {
                ForEach(med.times.indices, id: \.self) { i in
                    DatePicker("Dose \(i + 1)", selection: Binding(
                        get: { Calendar.current.date(bySettingHour: med.times[i] / 60, minute: med.times[i] % 60, second: 0, of: .now)! },
                        set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); med.times[i] = c.hour! * 60 + c.minute! }),
                               displayedComponents: .hourAndMinute)
                }
                .onDelete { med.times.remove(atOffsets: $0) }
                Button("Add Time", systemImage: "plus.circle.fill") {
                    med.times.append(min(23 * 60, (med.times.max() ?? 8 * 60 - 360) + 360))
                }
                Picker("Food", selection: $med.withFood) {
                    Text("Doesn't matter").tag(Bool?.none)
                    Text("With food").tag(Bool?.some(true))
                    Text("Empty stomach").tag(Bool?.some(false))
                }
            } header: { Text("Schedule") } footer: {
                Text("Use the times your neurologist prescribed. Swipe left on a time to remove it.")
            }

            Section("Notes") {
                TextField("e.g. Half tablet if dizzy", text: $med.notes, axis: .vertical)
            }
        }
        .navigationTitle(med.name.isEmpty ? "Medication" : med.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
