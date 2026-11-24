import Foundation
import Testing
@testable import TremorKit

@Test(arguments: [
    "http://10.20.167.77:8000",
    " http://10.20.167.77:8000 ",
    "http://172.20.10.2:8000/",
    "https://clinic.example.org",
])
func acceptsServerURLs(_ s: String) {
    #expect(SetupInput.serverURL(s) != nil)
}

@Test(arguments: ["", "10.20.167.77:8000", "ftp://host", "http://", "http://host:8000/v1", "aniket-test"])
func rejectsServerURLs(_ s: String) {
    #expect(SetupInput.serverURL(s) == nil)
}

@Test func trimsServerURL() {
    #expect(SetupInput.serverURL("  http://10.0.0.5:8000\n")?.absoluteString == "http://10.0.0.5:8000")
}

@Test(arguments: ["aniket-test", "demo-patient", "P_001.a", " padded "])
func acceptsPatientIds(_ s: String) {
    #expect(SetupInput.patientIdProblem(s) == nil)
}

@Test(arguments: [
    "",
    "http://10.20.167.77:8000",
    "http://10.20.167.77:8000.",
    "http://172.20.10:8000",
    "has space",
    "slash/id",
    "हिंदी",
])
func rejectsPatientIds(_ s: String) {
    #expect(SetupInput.patientIdProblem(s) != nil)
}

@Test func serverAddressInPatientFieldGetsSpecificMessage() {
    #expect(SetupInput.patientIdProblem("http://10.20.167.77:8000")?.contains("server address") == true)
}
