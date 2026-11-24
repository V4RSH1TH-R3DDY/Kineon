// Checks the Swift models against contracts/openapi.json, the way `npm run gen` keeps the dashboard honest.
// If this fails after a backend change, regenerate the contract and update Models.swift to match.
import Foundation
import Testing
@testable import TremorKit

private let contractURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // TremorKitTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // TremorKit
    .deletingLastPathComponent()  // ios
    .deletingLastPathComponent()  // repo root
    .appending(path: "contracts/openapi.json")

private func schemas() throws -> [String: [String: Any]] {
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: contractURL)) as! [String: Any]
    let components = json["components"] as! [String: Any]
    return components["schemas"] as! [String: [String: Any]]
}

/// Every string enum value found anywhere under a schema node (handles anyOf/null wrappers and $ref-free inlines).
private func enumValues(_ node: Any) -> Set<String> {
    switch node {
    case let d as [String: Any]:
        var out = Set((d["enum"] as? [String]) ?? [])
        for v in d.values { out.formUnion(enumValues(v)) }
        return out
    case let a as [Any]:
        return a.reduce(into: Set<String>()) { $0.formUnion(enumValues($1)) }
    default:
        return []
    }
}

private func property(_ schema: String, _ prop: String) throws -> Any {
    let s = try #require(try schemas()[schema], "schema \(schema) missing")
    let props = try #require(s["properties"] as? [String: Any])
    return try #require(props[prop], "\(schema).\(prop) missing")
}

@Test(arguments: contractModels.map { ObjectIdentifier($0) })
func modelKeysMatchContract(_ id: ObjectIdentifier) throws {
    let model = contractModels.first { ObjectIdentifier($0) == id }!
    let schema = try #require(try schemas()[model.schemaName], "\(model.schemaName) not in openapi.json")
    let props = Set((schema["properties"] as? [String: Any])?.keys.map { $0 } ?? [])
    #expect(Set(model.wireKeys) == props, "\(model.schemaName) keys differ from the contract")
}

@Test func enumsMatchContract() throws {
    #expect(enumValues(try property("ScoreResult", "activity")) == Set([
        Activity.resting, .walking, .eating, .writing, .brushing, .unknown].map(\.rawValue)))
    #expect(enumValues(try property("ScoreResult", "status")) == Set(["ok", "insufficient_data"]))
    #expect(enumValues(try property("Report", "lang")) == Set(Lang.allCases.map(\.rawValue)))
    #expect(enumValues(try property("DoseEvent", "tags")) == Set(DoseTag.allCases.map(\.rawValue)))
    #expect(enumValues(try property("MotionWindow", "source")) == Set(["watch", "phone"]))
}
