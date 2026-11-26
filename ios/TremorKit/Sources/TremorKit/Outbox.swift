// Windows and doses the phone could not post yet, kept on disk and retried oldest first.
// A reading is never dropped silently: it waits here until the server accepts it or the queue is full.
import Foundation

public struct Outbox: Codable, Sendable {
    public enum Item: Codable, Sendable {
        case window(MotionWindow)
        case dose(patientId: String, DoseEvent)
    }

    /// About two hours of 10-second windows. Past this the oldest windows go first; doses are kept.
    public static let limit = 720

    public private(set) var items: [Item] = []

    public init() {}

    public var count: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }

    public mutating func append(_ item: Item) {
        items.append(item)
        while items.count > Self.limit {
            guard let i = items.firstIndex(where: { if case .window = $0 { true } else { false } }) else { break }
            items.remove(at: i)
        }
    }

    /// Sends items oldest first and stops at the first failure, so order is kept. Returns how many were sent.
    @discardableResult
    public mutating func drain(isolation: isolated (any Actor)? = #isolation,
                               _ send: (Item) async throws -> Void) async -> Int {
        var sent = 0
        while let first = items.first {
            do { try await send(first) } catch { break }
            items.removeFirst()
            sent += 1
        }
        return sent
    }

    public static func load(from url: URL) -> Outbox {
        guard let data = try? Data(contentsOf: url),
              let box = try? JSONDecoder.tremor.decode(Outbox.self, from: data) else { return Outbox() }
        return box
    }

    public func save(to url: URL) {
        guard let data = try? JSONEncoder.tremor.encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
