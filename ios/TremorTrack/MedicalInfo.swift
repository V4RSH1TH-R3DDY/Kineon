// The patient's medical details, modelled on Apple's Medical ID plus what matters for tremor care:
// diagnosis, affected side, medication schedule, DBS, care team and emergency contacts.
// Kept on this iPhone in a protected file. The patient can attach a copy to a specific doctor access link.
import Foundation

struct MedicalInfo: Codable, Equatable {
    // About you
    var birthDate: Date?
    var sex: Sex?
    var heightCm: Double?
    var weightKg: Double?
    var bloodType: BloodType?
    var dominantHand: Side?

    // Condition
    var diagnosis: Diagnosis?
    var diagnosisOther = ""
    var symptomsSinceYear: Int?
    var diagnosedYear: Int?
    var affectedSide: Side?
    var symptoms: Set<Symptom> = []
    var stage: Int?                       // Hoehn and Yahr, 1–5, as recorded by the neurologist
    var hasDBS = false
    var dbsSinceYear: Int?

    // Medication and other health
    var medications: [Medication] = []
    var allergies = ""
    var otherConditions = ""

    // People
    var neurologist = CareContact()
    var familyDoctor = CareContact()
    var emergencyContacts: [EmergencyContact] = []

    var notes = ""
    var updatedAt: Date?

    var isEmpty: Bool { self == MedicalInfo() }

    var age: Int? {
        birthDate.flatMap { Calendar.current.dateComponents([.year], from: $0, to: .now).year }
    }

    /// The next scheduled dose today or tomorrow, from the medication schedule.
    func nextDose(after now: Date = .now) -> (name: String, at: Date)? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        return [0, 1].flatMap { day in
            medications.flatMap { m in
                m.times.map { t in (m.name, cal.date(byAdding: .minute, value: t, to: cal.date(byAdding: .day, value: day, to: today)!)!) }
            }
        }
        .filter { $0.1 > now && !$0.0.isEmpty }
        .min { $0.1 < $1.1 }
        .map { (name: $0.0, at: $0.1) }
    }

    /// One line for the Account tab, e.g. "Parkinson's disease · 2 medications · 1 emergency contact".
    var summary: String {
        var parts: [String] = []
        if let d = diagnosis { parts.append(d == .other && !diagnosisOther.isEmpty ? diagnosisOther : d.title) }
        if !medications.isEmpty { parts.append("\(medications.count) medication\(medications.count == 1 ? "" : "s")") }
        if !emergencyContacts.isEmpty {
            parts.append("\(emergencyContacts.count) emergency contact\(emergencyContacts.count == 1 ? "" : "s")")
        }
        return parts.isEmpty ? "Add your diagnosis, medication and emergency contacts" : parts.joined(separator: " · ")
    }

    enum Sex: String, Codable, CaseIterable, Identifiable {
        case female, male, other
        var id: Self { self }
        var title: String { switch self { case .female: "Female"; case .male: "Male"; case .other: "Other" } }
    }

    enum BloodType: String, Codable, CaseIterable, Identifiable {
        case aPos = "A+", aNeg = "A−", bPos = "B+", bNeg = "B−", abPos = "AB+", abNeg = "AB−", oPos = "O+", oNeg = "O−"
        var id: Self { self }
    }

    enum Side: String, Codable, CaseIterable, Identifiable {
        case left, right, both
        var id: Self { self }
        var title: String { switch self { case .left: "Left"; case .right: "Right"; case .both: "Both" } }
    }

    enum Diagnosis: String, Codable, CaseIterable, Identifiable {
        case parkinsons, essentialTremor, dystonicTremor, drugInduced, notYet, other
        var id: Self { self }
        var title: String {
            switch self {
            case .parkinsons: "Parkinson's disease"
            case .essentialTremor: "Essential tremor"
            case .dystonicTremor: "Dystonic tremor"
            case .drugInduced: "Drug-induced tremor"
            case .notYet: "Not diagnosed yet"
            case .other: "Other"
            }
        }
    }

    enum Symptom: String, Codable, CaseIterable, Identifiable {
        case restTremor, actionTremor, stiffness, slowness, balance, freezing, dyskinesia, speech, swallowing, sleep, mood
        var id: Self { self }
        var title: String {
            switch self {
            case .restTremor: "Tremor at rest"
            case .actionTremor: "Tremor when moving"
            case .stiffness: "Stiffness"
            case .slowness: "Slowness of movement"
            case .balance: "Balance problems or falls"
            case .freezing: "Freezing when walking"
            case .dyskinesia: "Involuntary movements (dyskinesia)"
            case .speech: "Speech changes"
            case .swallowing: "Difficulty swallowing"
            case .sleep: "Sleep problems"
            case .mood: "Low mood or anxiety"
            }
        }
    }

    /// Hoehn and Yahr stages in plain words.
    static func stageTitle(_ s: Int) -> String {
        switch s {
        case 1: "Stage 1 · one side only"
        case 2: "Stage 2 · both sides, balance fine"
        case 3: "Stage 3 · balance affected, independent"
        case 4: "Stage 4 · needs some help"
        default: "Stage 5 · needs a wheelchair or bed"
        }
    }
}

struct Medication: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""
    var strength = ""                     // e.g. "100/25 mg"
    var form: DoseForm = .tablet
    var amount = "1"                      // per dose, e.g. "1" or "½"
    var times: [Int] = [8 * 60]           // minutes after midnight
    var withFood: Bool? = nil
    var notes = ""

    enum DoseForm: String, Codable, CaseIterable, Identifiable {
        case tablet, capsule, liquid, patch, injection, inhaler, other
        var id: Self { self }
        var title: String { rawValue.capitalized }
    }

    /// "1 tablet · 8:00 AM, 2:00 PM, 8:00 PM"
    var schedule: String {
        let t = times.sorted().map { Medication.timeText($0) }.joined(separator: ", ")
        return "\(amount) \(form.title.lowercased())\(amount == "1" || amount == "½" ? "" : "s")" + (t.isEmpty ? "" : " · \(t)")
    }

    static func timeText(_ minutes: Int) -> String {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now)!
            .formatted(date: .omitted, time: .shortened)
    }
}

struct CareContact: Codable, Equatable {
    var name = ""
    var clinic = ""
    var phone = ""
    var isEmpty: Bool { name.isEmpty && clinic.isEmpty && phone.isEmpty }
}

struct EmergencyContact: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""
    var relationship = ""
    var phone = ""
}

extension MedicalInfo {
    struct SharedRecord: Encodable, Sendable {
        let birthDate: String?
        let sex: Sex?
        let heightCm: Double?
        let weightKg: Double?
        let bloodType: String?
        let dominantHand: Side?
        let diagnosis: String?
        let symptomsSinceYear: Int?
        let diagnosedYear: Int?
        let affectedSide: Side?
        let symptoms: [String]
        let stage: Int?
        let hasDbs: Bool
        let dbsSinceYear: Int?
        let medications: [Medication]
        let allergies: String
        let otherConditions: String
        let neurologist: CareContact
        let familyDoctor: CareContact
        let emergencyContacts: [EmergencyContact]
        let notes: String
        let updatedAt: Date?
    }

    var sharedRecord: SharedRecord {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return SharedRecord(
            birthDate: birthDate.map { formatter.string(from: $0) }, sex: sex, heightCm: heightCm, weightKg: weightKg,
            bloodType: bloodType?.rawValue, dominantHand: dominantHand,
            diagnosis: diagnosis.map { $0 == .other && !diagnosisOther.isEmpty ? diagnosisOther : $0.title },
            symptomsSinceYear: symptomsSinceYear, diagnosedYear: diagnosedYear, affectedSide: affectedSide,
            symptoms: symptoms.map(\.title).sorted(), stage: stage, hasDbs: hasDBS, dbsSinceYear: dbsSinceYear,
            medications: medications, allergies: allergies, otherConditions: otherConditions, neurologist: neurologist,
            familyDoctor: familyDoctor, emergencyContacts: emergencyContacts, notes: notes, updatedAt: updatedAt
        )
    }

    static let fileURL = URL.applicationSupportDirectory.appending(path: "medical.json")

    static func load() -> MedicalInfo {
        (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(MedicalInfo.self, from: $0) } ?? MedicalInfo()
    }

    /// Encrypted at rest while the phone is locked.
    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.fileURL, options: [.atomic, .completeFileProtection])
    }

    static func erase() { try? FileManager.default.removeItem(at: fileURL) }
}
