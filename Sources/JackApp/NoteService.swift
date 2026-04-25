import Foundation

// MARK: - VoiceNote

struct VoiceNote: Identifiable {
    let id: String
    let date: Date
    let timestamp: String
    let dayStamp: String
    let text: String
}

// MARK: - NoteService

final class NoteService {
    private let fileManager: FileManager
    private let notesDirectoryURL: URL

    init(
        fileManager: FileManager = .default,
        notesDirectoryURL: URL = NoteService.defaultNotesDirectoryURL()
    ) {
        self.fileManager = fileManager
        self.notesDirectoryURL = notesDirectoryURL
    }

    func notesDirectoryPath() -> String {
        notesDirectoryURL.path
    }

    /// Load all voice notes from the notes directory, newest first.
    func loadAllNotes() -> [VoiceNote] {
        guard fileManager.fileExists(atPath: notesDirectoryURL.path) else { return [] }

        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(
                at: notesDirectoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "md" }
        } catch {
            return []
        }

        var notes: [VoiceNote] = []

        for file in files {
            let dayStamp = file.deletingPathExtension().lastPathComponent
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            notes.append(contentsOf: parseNotes(from: content, dayStamp: dayStamp))
        }

        // Sort newest first
        notes.sort { $0.date > $1.date }
        return notes
    }

    /// Parse a daily markdown file into individual VoiceNote entries.
    private func parseNotes(from content: String, dayStamp: String) -> [VoiceNote] {
        var notes: [VoiceNote] = []
        let lines = content.components(separatedBy: "\n")
        var currentTimestamp: String?
        var currentBody: [String] = []

        for line in lines {
            if line.hasPrefix("## ") {
                // Flush previous note
                if let ts = currentTimestamp {
                    let text = currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        let date = Self.parseDate(day: dayStamp, time: ts) ?? .distantPast
                        notes.append(VoiceNote(
                            id: "\(dayStamp)-\(ts)",
                            date: date,
                            timestamp: ts,
                            dayStamp: dayStamp,
                            text: text
                        ))
                    }
                }
                currentTimestamp = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                currentBody = []
            } else if currentTimestamp != nil && !line.hasPrefix("# ") {
                currentBody.append(line)
            }
        }

        // Flush last note
        if let ts = currentTimestamp {
            let text = currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let date = Self.parseDate(day: dayStamp, time: ts) ?? .distantPast
                notes.append(VoiceNote(
                    id: "\(dayStamp)-\(ts)",
                    date: date,
                    timestamp: ts,
                    dayStamp: dayStamp,
                    text: text
                ))
            }
        }

        return notes
    }

    private static func parseDate(day: String, time: String) -> Date? {
        Self.combinedFormatter.date(from: "\(day) \(time)")
    }

    private static let combinedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    func appendVoiceNote(_ text: String, at date: Date = .now) throws -> URL {
        try fileManager.createDirectory(
            at: notesDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let dayStamp = Self.dayFormatter.string(from: date)
        let timeStamp = Self.timeFormatter.string(from: date)
        let fileURL = notesDirectoryURL.appendingPathComponent("\(dayStamp).md")

        if !fileManager.fileExists(atPath: fileURL.path) {
            let header = "# Jack Voice Notes (\(dayStamp))\n"
            try header.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        let entry = "\n## \(timeStamp)\n\n\(text)\n"
        guard let data = entry.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        defer {
            try? handle.close()
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)

        return fileURL
    }

    static func defaultNotesDirectoryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Jack Notes", isDirectory: true)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
