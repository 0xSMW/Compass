import Foundation
import Synchronization

/// Persistence for the whole snapshot. The real app syncs the JSON file through iCloud;
/// the widget reads and writes the same file in the shared App Group container.
public protocol Store: AnyObject, Sendable {
    func load() throws -> CompassSnapshot
    func save(_ snapshot: CompassSnapshot) throws
    /// Load, mutate, save as one step. `JSONFileStore` does it under file coordination, so the widget's
    /// change and the app's save never interleave.
    @discardableResult
    func update(_ body: (inout CompassSnapshot) throws -> Void) throws -> CompassSnapshot
    /// The app's save as one step (`JSONFileStore`: one coordinated write). `body` gets what is stored now
    /// and when it last changed on disk, and leaves what to write. With `replacingUnreadable`, a damaged
    /// file (`StoreError.corrupt`, already copied aside at launch) reads as `.empty` and is replaced; a
    /// newer-schema file still throws. The result carries the modification date right after the write,
    /// read in the same step, so another process's write can't slip in between.
    func update(replacingUnreadable: Bool, _ body: (inout CompassSnapshot, _ storedModifiedAt: Date?) throws -> Void) throws -> StoreWrite
    /// When the stored data last changed on disk (nil: unknown, or nothing stored).
    var modifiedAt: Date? { get }
}

/// What `Store.update(replacingUnreadable:_:)` wrote.
public struct StoreWrite: Equatable, Sendable {
    public var snapshot: CompassSnapshot
    /// The store's modification date right after the write.
    public var modifiedAt: Date?

    public init(snapshot: CompassSnapshot, modifiedAt: Date?) {
        self.snapshot = snapshot
        self.modifiedAt = modifiedAt
    }
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

    public func update(replacingUnreadable: Bool, _ body: (inout CompassSnapshot, Date?) throws -> Void) throws -> StoreWrite {
        let before = modifiedAt
        var snapshot: CompassSnapshot
        do {
            snapshot = try load()
        } catch StoreError.corrupt where replacingUnreadable {
            snapshot = .empty
        }
        try body(&snapshot, before)
        try save(snapshot)
        return StoreWrite(snapshot: snapshot, modifiedAt: modifiedAt)
    }

    public var modifiedAt: Date? { nil }

    /// Mark the step for `key` done (or undo). No-op if there is no step. Stamps the completion
    /// (`completionChangedAt`, not `updatedAt`) so sync keeps this change over an older copy on another
    /// device without undoing a title edit made there (the widget calls this from its own process).
    @discardableResult
    public func setStepDone(_ done: Bool, on key: DayKey, at date: Date) throws -> CompassSnapshot {
        try update { snap in
            snap.updateDay(key) { day in
                guard day.step != nil else { return }
                day.step?.completedAt = done ? date : nil
                day.step?.completionChangedAt = date
            }
        }
    }
}

public final class InMemoryStore: Store, Sendable {
    private struct State {
        var snapshot: CompassSnapshot
        var saveCount = 0
        var modifiedAt: Date?
        var failsSaving = false
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
        try state.withLock {
            if $0.failsSaving { throw CocoaError(.fileWriteOutOfSpace) }
            $0.snapshot = snapshot
            $0.saveCount += 1
            $0.modifiedAt = Date()
        }
    }

    public var modifiedAt: Date? { state.withLock { $0.modifiedAt } }

    /// Tests: make every save fail (a full disk), or work again.
    public var failsSaving: Bool {
        get { state.withLock { $0.failsSaving } }
        set { state.withLock { $0.failsSaving = newValue } }
    }

    /// Tests: another process (the widget) writes the store.
    public func writeExternally(_ snapshot: CompassSnapshot, at date: Date) {
        state.withLock {
            $0.snapshot = snapshot
            $0.modifiedAt = date
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

/// JSON file store. A missing file loads as `.empty`. Writes are atomic, and reads and writes are
/// coordinated (`NSFileCoordinator`) because the widget's process reads and writes the same file.
public final class JSONFileStore: Store, Sendable {
    public let url: URL
    private let lock = NSLock()
    /// Set by `loadRecovering` when the file on disk is from a newer schema: saves are refused.
    private let blockedBy = Mutex<Int?>(nil)

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

    /// `value` exactly as it reads back from a file written with `encoder()` (the store, a sync envelope,
    /// the sync state): dates lose their fractions of a second. Whatever is compared with another device's
    /// decoded data, or keyed by a date (an evening entry's `createdAt`), must be held in this form, or this
    /// device sees 21:00:00.7 where every other device sees 21:00:00. Returns `value` unchanged if it
    /// doesn't encode.
    public static func asStored<T: Codable>(_ value: T) -> T {
        guard let data = try? encoder().encode(value), let back = try? decoder().decode(T.self, from: data) else { return value }
        return back
    }

    /// `asStored(new)` at the cost of what changed since `old`, which must already be in stored form (the
    /// app's snapshot always is: it comes from a file, from an earlier call, or is `.empty` or a fixture).
    /// A day equal to the day of `old` with the same key is already stored and is kept as it is; every other
    /// day, and everything outside `days` (goal, past goals, settings, any field added later), goes through
    /// one round trip together. A full round trip of a year of days takes tens of milliseconds; this takes
    /// about one. Equal to `asStored(new)` (`StoredFormTests`).
    public static func asStored(_ new: CompassSnapshot, against old: CompassSnapshot) -> CompassSnapshot {
        var changed: [Int] = []
        var oldByKey: [DayKey: Day]?
        for (i, day) in new.days.enumerated() {
            let before: Day?
            if i < old.days.count, old.days[i].key == day.key {
                before = old.days[i] // the usual case: same order, so no lookup
            } else {
                if oldByKey == nil { oldByKey = Dictionary(old.days.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first }) }
                before = oldByKey?[day.key]
            }
            if before != day { changed.append(i) }
        }
        var rest = new
        rest.days = changed.map { new.days[$0] }
        let stored = asStored(rest)
        // Decoding keeps the count and order of `days`; if `rest` didn't encode it came back unchanged,
        // exactly as `asStored(new)` would return `new`.
        var out = stored
        out.days = new.days
        for (j, i) in changed.enumerated() { out.days[i] = stored.days[j] }
        return out
    }

    /// `asStored(envelope)` for an envelope whose snapshot is already in stored form (the app's snapshot
    /// always is, see `asStored(_:against:)`): only the rest (`savedAt`, tombstones, the wipe, audio
    /// tombstones) goes through a round trip; the snapshot is put back as it is. Equal to `asStored(envelope)`.
    public static func asStored(_ envelope: SyncEnvelope, snapshotIsStored: Bool) -> SyncEnvelope {
        guard snapshotIsStored else { return asStored(envelope) }
        var rest = envelope
        rest.snapshot = .empty
        var out = asStored(rest)
        out.snapshot = envelope.snapshot
        return out
    }

    /// Throws `StoreError.newerSchema` for a file from a newer Compass (never misread as empty) and
    /// `StoreError.corrupt` for one that doesn't decode.
    public func load() throws -> CompassSnapshot {
        lock.lock(); defer { lock.unlock() }
        return try coordinated(.reading) { try readFile(at: $0) }
    }

    /// Load, change and save under one coordinated write, so another process can't write in between.
    @discardableResult
    public func update(_ body: (inout CompassSnapshot) throws -> Void) throws -> CompassSnapshot {
        try update(replacingUnreadable: false) { snapshot, _ in try body(&snapshot) }.snapshot
    }

    public func update(replacingUnreadable: Bool, _ body: (inout CompassSnapshot, Date?) throws -> Void) throws -> StoreWrite {
        lock.lock(); defer { lock.unlock() }
        if let blocked = blockedBy.withLock({ $0 }) { throw StoreError.newerSchema(blocked) }
        return try coordinated(.writing) { file in
            let before = Self.modificationDate(of: file)
            var snapshot: CompassSnapshot
            do {
                snapshot = try readFile(at: file)
            } catch StoreError.corrupt where replacingUnreadable {
                snapshot = .empty
            }
            try body(&snapshot, before)
            try writeFile(snapshot, to: file)
            return StoreWrite(snapshot: snapshot, modifiedAt: Self.modificationDate(of: file))
        }
    }

    public var modifiedAt: Date? { Self.modificationDate(of: url) }

    private static func modificationDate(of file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    private enum Access { case reading, writing, deleting }

    /// Runs `body` while holding file coordination for the store (other processes wait), with the URL the
    /// coordinator hands back (the one to use inside the block). On platforms without `NSFileCoordinator`
    /// (Linux tests) the in-process lock is all there is.
    private func coordinated<T>(_ access: Access, _ body: (URL) throws -> T) throws -> T {
        #if canImport(Darwin)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        switch access {
        case .reading:
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { file in
                result = Result { try body(file) }
            }
        case .writing:
            coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { file in
                result = Result { try body(file) }
            }
        case .deleting:
            coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { file in
                result = Result { try body(file) }
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return try result.get()
        #else
        return try body(url)
        #endif
    }

    private func readFile(at file: URL) throws -> CompassSnapshot {
        guard FileManager.default.fileExists(atPath: file.path) else { return .empty }
        let data = try Data(contentsOf: file)
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
            blockedBy.withLock { $0 = version }
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
        // A coordinated read, so the widget can't be halfway through writing the file being copied.
        return try? coordinated(.reading) { file in copyAside(file, label: label, now: now) }
    }

    private func copyAside(_ file: URL, label: String, now: Date) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else { return nil }
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
                try fm.copyItem(at: file, to: target)
                return target
            } catch {
                return nil
            }
        }
        return nil
    }

    public func save(_ snapshot: CompassSnapshot) throws {
        lock.lock(); defer { lock.unlock() }
        if let blocked = blockedBy.withLock({ $0 }) { throw StoreError.newerSchema(blocked) }
        try coordinated(.writing) { try writeFile(snapshot, to: $0) }
    }

    private func writeFile(_ snapshot: CompassSnapshot, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder().encode(snapshot)
        try data.write(to: file, options: .atomic)
    }

    /// Remove the file (H2 Delete everything), coordinated like every write. Refused for a newer-schema file.
    public func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        if let blocked = blockedBy.withLock({ $0 }) { throw StoreError.newerSchema(blocked) }
        try coordinated(.deleting) { file in
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        }
    }
}
