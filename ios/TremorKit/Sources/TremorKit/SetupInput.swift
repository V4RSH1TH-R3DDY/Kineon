// Validation for what a patient or clinic staff member types during setup.
// Patient IDs end up in URL paths and in the dashboard, so they are kept to a plain, URL-safe set of characters.
// That also catches the server address being typed into the patient field by mistake.
import Foundation

public enum SetupInput {
    /// A usable backend base URL: http or https, with a host. Surrounding spaces are ignored.
    public static func serverURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = URLComponents(string: trimmed),
              let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host, !host.isEmpty,
              c.path.isEmpty || c.path == "/",
              c.query == nil
        else { return nil }
        return c.url
    }

    /// Why a patient ID is not acceptable, or nil when it is fine.
    public static func patientIdProblem(_ text: String) -> String? {
        let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty { return "Enter a patient ID." }
        if id.contains("://") || id.lowercased().hasPrefix("http") {
            return "This looks like the server address. Enter the patient ID here instead."
        }
        if id.count > 64 { return "Use 64 characters or fewer." }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        if !id.unicodeScalars.allSatisfy(allowed.contains) {
            return "Use only letters, numbers, dashes, dots and underscores."
        }
        return nil
    }

    /// The patient ID as it will be sent: trimmed. Only call after `patientIdProblem` returns nil.
    public static func patientId(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
