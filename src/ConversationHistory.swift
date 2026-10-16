import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum ConversationHistoryRole: String, Codable, Sendable { case user, assistant }
enum ConversationGenerationStatus: String, Codable, Sendable {
    case notApplicable, unknown, inProgress, complete, interrupted, failed, incomplete
}
enum ConversationPlaybackStatus: String, Codable, Sendable {
    case notApplicable, unknown, notStarted, inProgress, completed, interrupted, failed
    var terminal: Bool { [.notApplicable, .unknown, .completed, .interrupted, .failed].contains(self) }
}
enum ConversationHistoryFailureStage: String, Codable, Sendable { case generation, voice }
enum ConversationHistoryEvent: Equatable, Sendable {
    case generated, playbackStarted, playbackCompleted, interrupted
    /// Typed replies may continue generating text after their voice path fails.
    case voiceFailedContinuing
    case failed(ConversationHistoryFailureStage)
}

struct ConversationHistoryRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let date: Date
    let role: ConversationHistoryRole
    var text: String
    let turnID: UUID
    var generation: ConversationGenerationStatus
    var playback: ConversationPlaybackStatus
    var generationCompletedAt: Date?
    var playbackStartedAt: Date?
    var playbackCompletedAt: Date?
    var endedAt: Date?
    var failureStage: ConversationHistoryFailureStage?
    var textTruncated = false

    var isTerminal: Bool {
        let continuingText = generation == .inProgress && playback == .failed
            && failureStage == .voice && endedAt == nil
        return playback.terminal && !continuingText
    }

    var statusSummary: String {
        guard role == .assistant else { return "User transcript" }
        let generated: String
        switch generation {
        case .complete: generated = "Generated response"
        case .inProgress: generated = "Generating"
        case .interrupted: generated = "Generation interrupted"
        case .failed: generated = "Generation failed"
        case .incomplete: generated = "Generation incomplete"
        default: generated = "Saved response"
        }
        let delivery: String
        switch playback {
        case .notStarted: delivery = "Playback not started"
        case .inProgress: delivery = "Playback in progress"
        case .completed: delivery = "Playback completed"
        case .interrupted: delivery = playbackStartedAt == nil ? "Interrupted before playback" : "Playback interrupted"
        case .failed: delivery = "Voice failed"
        default: delivery = "Delivery unknown"
        }
        return generated + " · " + delivery
    }

    var deliveryExplanation: String {
        guard role == .assistant else { return "Recognized user text; microphone audio is not saved." }
        let detail = playback == .completed
            ? "All queued audio reported successful playback. This does not establish that the user heard it."
            : "This is generated text. It is not a transcript of words confirmed heard; the exact partially played words are unknown."
        return detail + (textTruncated ? " Saved text was shortened to the storage limit." : "")
    }
}

enum ConversationHistoryError: Error, LocalizedError, Equatable {
    case invalidText, capacityExceeded, corrupt, unsupportedVersion(Int), unsafeStorage, notFound, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidText: return "History needs nonempty text within the per-message limit."
        case .capacityExceeded: return "Local history reached its storage limit. Delete saved entries to make room."
        case .corrupt: return "Saved history could not be read. Its file has been preserved; Clear History can explicitly reset it."
        case .unsupportedVersion: return "This history was saved by an unsupported version of dot. Its file has been preserved."
        case .unsafeStorage: return "History storage is not a private, locally owned regular file or folder."
        case .notFound: return "That history entry is no longer available."
        case .unavailable: return "Local history could not be read or saved."
        }
    }
}

/// One serialized owner for durable text. It never changes live LLM context and
/// stores no audio, images, learned facts, or implicit screen context.
actor ConversationHistoryStore {
    struct Limits: Sendable {
        let maxRecords: Int
        let maxTextBytes: Int
        let maxTotalTextBytes: Int
        let maxFileBytes: Int
        static let `default` = Limits(maxRecords: 2_000, maxTextBytes: 65_536,
                                      maxTotalTextBytes: 2_097_152, maxFileBytes: 4_194_304)
    }
    private let directory: URL
    private let fileURL: URL
    private let limits: Limits
    private static let fileName = "conversations.json"
    private static let backupName = "conversations.schema1.backup.json"
    private static let limitsKey = CodingUserInfoKey(rawValue: "dot.history.limits")!
    private var legacyData: Data?
    private var activeAssistantIDs = Set<UUID>()

    init(directory: URL? = nil, limits: Limits = .default) throws {
        guard limits.maxRecords > 0, limits.maxRecords <= 10_000,
              limits.maxTextBytes > 0, limits.maxTextBytes <= 1_048_576,
              limits.maxTotalTextBytes > 0, limits.maxTotalTextBytes <= 16_777_216,
              limits.maxFileBytes > 0, limits.maxFileBytes <= 33_554_432 else {
            throw ConversationHistoryError.capacityExceeded
        }
        let chosen: URL
        if let directory { chosen = directory }
        else {
            guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw ConversationHistoryError.unavailable
            }
            chosen = support.appendingPathComponent("Dot", isDirectory: true).appendingPathComponent("History", isDirectory: true)
        }
        guard chosen.isFileURL else { throw ConversationHistoryError.unsafeStorage }
        self.directory = chosen.standardizedFileURL
        fileURL = chosen.standardizedFileURL.appendingPathComponent(Self.fileName)
        self.limits = limits
        try Self.prepareDirectory(self.directory)
    }

    func read() throws -> [ConversationHistoryRecord] { try load().map(recovered) }

    @discardableResult
    func append(role: ConversationHistoryRole, text: String, turnID: UUID, date: Date = Date()) throws -> ConversationHistoryRecord {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= limits.maxTextBytes, Self.validDate(date) else {
            throw ConversationHistoryError.invalidText
        }
        var records = try load()
        // Schema 1 records millisecond timestamps. Canonicalize the returned value
        // too, so reopening a file preserves record equality rather than exposing
        // floating-point differences from the Unix/reference-epoch conversion.
        let timestamp = Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded() / 1_000)
        let record = ConversationHistoryRecord(id: UUID(), date: timestamp, role: role, text: text, turnID: turnID,
            generation: role == .user ? .notApplicable : .unknown, playback: role == .user ? .notApplicable : .unknown)
        records.append(record)
        try save(records)
        return record
    }

    func beginAssistant(id: UUID, turnID: UUID, date: Date = Date()) throws {
        guard Self.validDate(date) else { throw ConversationHistoryError.invalidText }
        var records = try load()
        guard !records.contains(where: { $0.id == id || ($0.role == .assistant && $0.turnID == turnID) }) else { return }
        let record = ConversationHistoryRecord(id: id, date: Self.timestamp(date), role: .assistant, text: "", turnID: turnID,
                                              generation: .inProgress, playback: .notStarted)
        activeAssistantIDs.insert(id)
        do { records.append(record); try save(records) }
        catch { activeAssistantIDs.remove(id); throw error }
    }

    /// Only the current-session record can change. Terminal or deleted records
    /// cannot be resurrected; a typed reply can explicitly outlive voice failure.
    @discardableResult
    func recordAssistant(id: UUID, turnID: UUID, text: String? = nil, event: ConversationHistoryEvent,
                         date: Date = Date()) throws -> Bool {
        guard activeAssistantIDs.contains(id) else { return false }
        guard Self.validDate(date) else { throw ConversationHistoryError.invalidText }
        var records = try load()
        guard let index = records.firstIndex(where: { $0.id == id && $0.turnID == turnID && $0.role == .assistant }) else {
            return false
        }
        var record = records[index]
        guard !record.isTerminal else { activeAssistantIDs.remove(id); return false }
        let timestamp = Self.timestamp(date)
        switch event {
        case .generated:
            guard record.generation == .inProgress, let text,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            record.generation = .complete; record.generationCompletedAt = timestamp
            if record.playback == .failed { record.endedAt = timestamp }
        case .playbackStarted:
            guard record.playback == .notStarted else { return false }
            record.playback = .inProgress; record.playbackStartedAt = timestamp
        case .playbackCompleted:
            guard record.generation == .complete, record.playback == .inProgress else { return false }
            record.playback = .completed; record.playbackCompletedAt = timestamp; record.endedAt = timestamp
        case .interrupted:
            if record.generation == .inProgress { record.generation = .interrupted }
            if record.playback != .failed { record.playback = .interrupted }
            record.endedAt = timestamp
        case .voiceFailedContinuing:
            guard record.playback == .notStarted || record.playback == .inProgress else { return false }
            record.playback = .failed; record.failureStage = .voice
            if record.generation != .inProgress { record.endedAt = timestamp }
        case .failed(let stage):
            if record.generation == .inProgress { record.generation = stage == .generation ? .failed : .interrupted }
            if record.playback != .failed { record.playback = stage == .voice ? .failed : .interrupted }
            record.failureStage = stage; record.endedAt = timestamp
        }
        if let text, records[index].generation == .inProgress {
            let bounded = Self.bounded(text, bytes: limits.maxTextBytes)
            record.text = bounded.text; record.textTruncated = bounded.truncated
        }
        records[index] = record
        try save(records)
        if record.isTerminal { activeAssistantIDs.remove(id) }
        return true
    }

    /// Return plain text for an explicit UI Copy action; this store never writes the clipboard.
    func textToCopy(id: UUID? = nil) throws -> String {
        let records = try read()
        if let id {
            guard let record = records.first(where: { $0.id == id }) else { throw ConversationHistoryError.notFound }
            return Self.copyText(record)
        }
        let formatter = ISO8601DateFormatter()
        return records.map {
            "[\(formatter.string(from: $0.date))] \($0.role == .user ? "You" : "dot")\n\(Self.copyText($0))"
        }.joined(separator: "\n\n")
    }

    @discardableResult func delete(id: UUID) throws -> Bool {
        var records = try load()
        guard let index = records.firstIndex(where: { $0.id == id }) else { return false }
        records.remove(at: index)
        try removeMigrationBackup()
        try save(records, preserveLegacy: false)
        activeAssistantIDs.remove(id)
        return true
    }

    /// Explicit deletion is the only operation allowed to replace malformed or
    /// unsupported history. Ordinary reads/appends/deletes preserve that file.
    func clear() throws {
        try removeMigrationBackup()
        try save([], preserveLegacy: false)
        activeAssistantIDs.removeAll()
    }

    private func load() throws -> [ConversationHistoryRecord] {
        legacyData = nil
        try Self.prepareDirectory(directory)
        guard try Self.checkFile(fileURL) else { return [] }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard let size = attributes[.size] as? NSNumber, size.int64Value <= Int64(limits.maxFileBytes) else {
                throw ConversationHistoryError.capacityExceeded
            }
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: limits.maxFileBytes + 1) ?? Data()
            guard data.count <= limits.maxFileBytes else { throw ConversationHistoryError.capacityExceeded }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            decoder.userInfo[Self.limitsKey] = limits
            let document = try decoder.decode(Document.self, from: data)
            try validate(document.records)
            if document.schemaVersion == 1 { legacyData = data }
            return document.records
        } catch let error as ConversationHistoryError { throw error }
        catch is DecodingError { throw ConversationHistoryError.corrupt }
        catch { throw ConversationHistoryError.unavailable }
    }

    private func save(_ records: [ConversationHistoryRecord], preserveLegacy: Bool = true) throws {
        try validate(records)
        try Self.prepareDirectory(directory)
        _ = try Self.checkFile(fileURL)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(Document(records: records.map(recovered)))
            guard data.count <= limits.maxFileBytes else { throw ConversationHistoryError.capacityExceeded }
            if preserveLegacy, let legacyData {
                let backup = directory.appendingPathComponent(Self.backupName)
                if try Self.checkFile(backup) {
                    let handle = try FileHandle(forReadingFrom: backup)
                    defer { try? handle.close() }
                    let saved = try handle.read(upToCount: limits.maxFileBytes + 1) ?? Data()
                    guard saved == legacyData else { throw ConversationHistoryError.unavailable }
                } else {
                    try legacyData.write(to: backup, options: .withoutOverwriting)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                }
            }
            // The containing 0700 directory protects the replacement throughout
            // Foundation's atomic write; the final file is then restricted to 0600.
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            legacyData = nil
        } catch let error as ConversationHistoryError { throw error }
        catch { throw ConversationHistoryError.unavailable }
    }

    private func validate(_ records: [ConversationHistoryRecord]) throws {
        guard records.count <= limits.maxRecords else { throw ConversationHistoryError.capacityExceeded }
        var identifiers = Set<UUID>(), total = 0
        for record in records {
            guard identifiers.insert(record.id).inserted, Self.validDate(record.date),
                  !record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || (record.role == .assistant && [.inProgress, .interrupted, .failed, .incomplete].contains(record.generation)),
                  [record.generationCompletedAt, record.playbackStartedAt, record.playbackCompletedAt, record.endedAt].allSatisfy({ $0.map(Self.validDate) != false }),
                  record.role == .assistant || (record.generation == .notApplicable && record.playback == .notApplicable),
                  record.role == .user || (record.generation != .notApplicable && record.playback != .notApplicable),
                  record.playback != .completed || (record.generation == .complete && record.generationCompletedAt != nil && record.playbackStartedAt != nil && record.playbackCompletedAt != nil),
                  record.generation != .complete || !record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConversationHistoryError.corrupt
            }
            let count = record.text.utf8.count
            guard count <= limits.maxTextBytes else { throw ConversationHistoryError.capacityExceeded }
            total += count
            guard total <= limits.maxTotalTextBytes else { throw ConversationHistoryError.capacityExceeded }
        }
    }

    private static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && date >= .distantPast && date <= .distantFuture
    }

    private func recovered(_ original: ConversationHistoryRecord) -> ConversationHistoryRecord {
        var record = original
        if record.role == .assistant && !activeAssistantIDs.contains(record.id) {
            if record.generation == .inProgress { record.generation = .incomplete }
            if !record.playback.terminal { record.playback = .unknown }
        }
        return record
    }

    private func removeMigrationBackup() throws {
        let backup = directory.appendingPathComponent(Self.backupName)
        if try Self.checkFile(backup) { try FileManager.default.removeItem(at: backup) }
    }

    private static func timestamp(_ date: Date) -> Date { Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded() / 1_000) }
    private static func bounded(_ text: String, bytes: Int) -> (text: String, truncated: Bool) {
        guard text.utf8.count > bytes else { return (text, false) }
        return (text.truncated(toUTF8Bytes: bytes), true)
    }
    private static func copyText(_ record: ConversationHistoryRecord) -> String {
        guard record.role == .assistant else { return record.text }
        return "Dot — \(record.statusSummary)\n\(record.deliveryExplanation)\n\nGenerated text:\n\(record.text)"
    }

    private static func prepareDirectory(_ url: URL) throws {
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                // Check a dangling symlink as well; fileExists follows its destination.
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
                    throw ConversationHistoryError.unsafeStorage
                }
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid() else {
                throw ConversationHistoryError.unsafeStorage
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch let error as ConversationHistoryError { throw error }
        catch { throw ConversationHistoryError.unavailable }
    }

    /// Never follow a symlink or overwrite a non-regular/user-owned entry.
    private static func checkFile(_ url: URL) throws -> Bool {
        do {
            guard FileManager.default.fileExists(atPath: url.path) else {
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
                    throw ConversationHistoryError.unsafeStorage
                }
                return false
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid() else {
                throw ConversationHistoryError.unsafeStorage
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch let error as ConversationHistoryError { throw error }
        catch { throw ConversationHistoryError.unavailable }
    }

    private struct Document: Codable {
        let schemaVersion: Int
        let records: [ConversationHistoryRecord]
        enum CodingKeys: String, CodingKey { case schemaVersion, records }
        init(records: [ConversationHistoryRecord]) { schemaVersion = 2; self.records = records }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            guard schemaVersion == 1 || schemaVersion == 2 else { throw ConversationHistoryError.unsupportedVersion(schemaVersion) }
            let limits = decoder.userInfo[ConversationHistoryStore.limitsKey] as? Limits ?? .default
            var values = try container.nestedUnkeyedContainer(forKey: .records)
            if let count = values.count, count > limits.maxRecords { throw ConversationHistoryError.capacityExceeded }
            var decoded: [ConversationHistoryRecord] = []
            var textBytes = 0
            while !values.isAtEnd {
                guard decoded.count < limits.maxRecords else { throw ConversationHistoryError.capacityExceeded }
                let record: ConversationHistoryRecord
                if schemaVersion == 1 {
                    let old = try values.decode(LegacyRecord.self)
                    guard !old.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConversationHistoryError.corrupt }
                    record = ConversationHistoryRecord(id: old.id, date: old.date, role: old.role, text: old.text, turnID: old.turnID,
                        generation: old.role == .user ? .notApplicable : .unknown, playback: old.role == .user ? .notApplicable : .unknown)
                } else { record = try values.decode(ConversationHistoryRecord.self) }
                let count = record.text.utf8.count
                textBytes += count
                guard count <= limits.maxTextBytes, textBytes <= limits.maxTotalTextBytes else {
                    throw ConversationHistoryError.capacityExceeded
                }
                decoded.append(record)
            }
            records = decoded
        }
    }
    private struct LegacyRecord: Decodable {
        let id: UUID
        let date: Date
        let role: ConversationHistoryRole
        let text: String
        let turnID: UUID
    }
}
