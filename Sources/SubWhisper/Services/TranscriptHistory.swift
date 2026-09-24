import Foundation

struct TranscriptRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var createdAt: Date
    var language: String
    var modelName: String
    var cueCount: Int
    var fileName: String
}

enum TranscriptStore {
    static var root: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("SubWhisperHistory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func save(
        segments: [SubtitleSegment],
        title: String,
        language: String,
        modelName: String
    ) throws -> TranscriptRecord {
        let id = UUID()
        let record = TranscriptRecord(
            id: id,
            title: title.isEmpty ? "未命名" : title,
            createdAt: Date(),
            language: language,
            modelName: modelName,
            cueCount: segments.count,
            fileName: "\(id.uuidString).srt"
        )
        let srt = SubtitleExporter.serialize(segments, format: .srt)
        try srt.write(to: fileURL(for: record), atomically: true, encoding: .utf8)
        var all = loadIndex()
        all.insert(record, at: 0)
        try persist(all)
        return record
    }

    static func loadIndex() -> [TranscriptRecord] {
        let url = root.appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([TranscriptRecord].self, from: data) else {
            return []
        }
        return records.sorted { $0.createdAt > $1.createdAt }
    }

    static func fileURL(for record: TranscriptRecord) -> URL {
        root.appendingPathComponent(record.fileName)
    }

    static func delete(_ record: TranscriptRecord) {
        try? FileManager.default.removeItem(at: fileURL(for: record))
        persistQuietly(loadIndex().filter { $0.id != record.id })
    }

    private static func persist(_ records: [TranscriptRecord]) throws {
        let data = try JSONEncoder().encode(records)
        try data.write(to: root.appendingPathComponent("index.json"), options: .atomic)
    }

    private static func persistQuietly(_ records: [TranscriptRecord]) {
        try? persist(records)
    }
}

enum HomophoneCorrector {
    private static let key = "SubWhisper.corrections"

    static func load() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    static func save(_ rules: [String: String]) {
        UserDefaults.standard.set(rules, forKey: key)
    }

    static func apply(_ text: String, rules: [String: String]) -> String {
        rules.reduce(text) { partial, rule in
            guard !rule.key.isEmpty, rule.key != rule.value else { return partial }
            return partial.replacingOccurrences(of: rule.key, with: rule.value)
        }
    }
}
