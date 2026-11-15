import Foundation
import Synchronization

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

    /// Mark the step for `key` done (or undo). No-op if there is no step. Stamps the step so sync keeps
    /// this change over an older copy on another device (the widget calls this from its own process).
    @discardableResult
    public func setStepDone(_ done: Bool, on key: DayKey, at date: Date) throws -> CompassSnapshot {
        try update { snap in
            snap.updateDay(key) { day in
                guard day.step != nil else { return }
                day.step?.completedAt = done ? date : nil
                day.step?.updatedAt = date
            }
        }
    }
}

public final class InMemoryStore: Store, Sendable {
    private struct State {
        var snapshot: CompassSnapshot
        var saveCount = 0
    }
    private let state: Mutex<State>

    /// How many times `save` ran (tests).
    public var saveCount: Int { state.withLock { $0.saveCount } }

    public init(_ snapshot: CompassSnapshot = .empty) {
        state = Mutex(State(snapshot: snapshot))
    }

    public func load() throws -> CompassSnapshot {
        state.withLock { $0.snapshot }
    }

    public func save(_ snapshot: CompassSnapshot) throws {
        state.withLock {
            $0.snapshot = snapshot
            $0.saveCount += 1
        }
    }
}

public enum StoreError: Error, Equatable {
    /// The file isn't a snapshot this version can read (truncated, damaged, hand-edited).
    case corrupt(String)
    /// Written by a newer version of Compass (`schemaVersion` above `CompassSnapshot.currentSchema`).
    case newerSchema(Int)
}

/// Why the store couldn't be read at launch, and where the unreadable file was copied.
public struct StoreProblem: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Unreadable. A copy is kept; Compass starts empty (sync brings iCloud data back) and later saves
        /// replace the damaged file.
        case corrupt
        /// From a newer Compass. A copy is kept and the file is never overwritten: saves are refused
        /// until Compass is updated.
        case newerSchema(Int)
    }

    public var kind: Kind
    /// The copy set aside next to the store ("compass.unreadable-20261110-153000.json"). nil if copying failed.
    public var quarantinedCopy: URL?

    public init(kind: Kind, quarantinedCopy: URL?) {
        self.kind = kind
        self.quarantinedCopy = quarantinedCopy
    }

    /// Saving would overwrite data this version can't read.
    public var blocksSaving: Bool {
        if case .newerSchema = kind { return true }
        return false
    }
}

/// JSON file store. A missing file loads as `.empty`. Writes are atomic.
public final class JSONFileStore: Store, Sendable {
    public let url: URL
    private let lock = NSLock()
    /// Set by `loadRecovering` when the file on disk is from a newer schema: saves are refused.
    private var blockedBy: Int?

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

    /// Throws `StoreError.newerSchema` for a file from a newer Compass (never misread as empty) and
    /// `StoreError.corrupt` for one that doesn't decode.
    public func load() throws -> CompassSnapshot {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        let data = try Data(contentsOf: url)
        if let version = CompassSnapshot.schemaVersion(of: data), version > CompassSnapshot.currentSchema {
            throw StoreError.newerSchema(version)
        }
        do {
            return try Self.decoder().decode(CompassSnapshot.self, from: data)
        } catch {
            throw StoreError.corrupt(String(describing: error))
        }
    }

    /// Launch-time load that never loses data: an unreadable or newer file is copied aside (never
    /// overwriting an earlier copy) and reported; the app starts from `.empty`. A newer-schema file also
    /// blocks saving through this store, so it is never overwritten.
    public func loadRecovering(now: Date = Date()) -> (snapshot: CompassSnapshot, problem: StoreProblem?) {
        do {
            return (try load(), nil)
        } catch StoreError.newerSchema(let version) {
            let copy = quarantine(label: "newer-schema", now: now)
            lock.withLock { blockedBy = version }
            return (.empty, StoreProblem(kind: .newerSchema(version), quarantinedCopy: copy))
        } catch {
            let copy = quarantine(label: "unreadable", now: now)
            return (.empty, StoreProblem(kind: .corrupt, quarantinedCopy: copy))
        }
    }

    /// Copy the store file next to itself under a new name. Returns the copy, or nil if nothing was copied.
    @discardableResult
    public func quarantine(label: String, now: Date = Date()) -> URL? {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stem = url.deletingPathExtension().lastPathComponent + ".\(label)-\(f.string(from: now))"
        let dir = url.deletingLastPathComponent()
        for n in 0..<1000 {
            let name = n == 0 ? "\(stem).json" : "\(stem)-\(n).json"
            let target = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path) { continue }
            do {
                try fm.copyItem(at: url, to: target)
                return target
            } catch {
                return nil
            }
        }
        return nil
    }

    public func save(_ snapshot: CompassSnapshot) throws {
        lock.lock(); defer { lock.unlock() }
        if let blockedBy { throw StoreError.newerSchema(blockedBy) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    /// Remove the file (H2 Delete everything). Refused for a newer-schema file.
    public func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        if let blockedBy { throw StoreError.newerSchema(blockedBy) }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
