import Foundation

/// Persistence for the whole snapshot. The real app syncs the JSON file through iCloud;
/// the widget reads and writes the same file in the shared App Group container.
public protocol Store: AnyObject, Sendable {
    func load() throws -> CompassSnapshot
    func save(_ snapshot: CompassSnapshot) throws
}

extension Store {
    /// Load, mutate, save. Returns the saved snapshot.
    @discardableResult
    public func update(_ body: (inout CompassSnapshot) throws -> Void) throws -> CompassSnapshot {
        var snapshot = try load()
        try body(&snapshot)
        try save(snapshot)
        return snapshot
    }

    /// Mark the step for `key` done (or undo). No-op if there is no step.
    @discardableResult
    public func setStepDone(_ done: Bool, on key: DayKey, at date: Date) throws -> CompassSnapshot {
        try update { snap in
            snap.updateDay(key) { day in
                day.step?.completedAt = done ? date : nil
            }
        }
    }
}

public final class InMemoryStore: Store, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: CompassSnapshot
    public private(set) var saveCount = 0

    public init(_ snapshot: CompassSnapshot = .empty) {
        self.snapshot = snapshot
    }

    public func load() throws -> CompassSnapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    public func save(_ snapshot: CompassSnapshot) throws {
        lock.lock(); defer { lock.unlock() }
        self.snapshot = snapshot
        saveCount += 1
    }
}

public enum StoreError: Error, Equatable {
    case corrupt(String)
}

/// JSON file store. A missing file loads as `.empty`. Writes are atomic.
public final class JSONFileStore: Store, @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public func load() throws -> CompassSnapshot {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        let data = try Data(contentsOf: url)
        do {
            return try Self.decoder().decode(CompassSnapshot.self, from: data)
        } catch {
            throw StoreError.corrupt(String(describing: error))
        }
    }

    public func save(_ snapshot: CompassSnapshot) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    /// Remove the file (H2 Delete everything).
    public func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
