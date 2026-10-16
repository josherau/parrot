import Foundation

/// The last few transcripts, newest first, for the Recent menu and Paste
/// Last.
///
/// On (the default), they live in `Paths.historyFile`: text only, no audio,
/// no app or time, owner-only (0600) in an owner-only directory, written
/// before the transcript is delivered so a paste into nothing can still be
/// recovered. Off, only the last transcript is kept, in memory, and the file
/// is deleted.
///
/// Never logs the text. A file that can't be used (a symlink, not ours, too
/// large, unreadable) is ignored with one log line and replaced at the next
/// write; it is never written through.
final class TranscriptHistory {
    /// How many transcripts the file keeps.
    static let limit = 20
    /// Far larger than `limit` long dictations; refuses anything absurd.
    static let maxBytes = 1 << 20

    private struct File: Codable {
        var version = 1
        var transcripts: [String]
    }

    let file: URL
    private let limit: Int
    private let log: (String) -> Void
    private(set) var isEnabled: Bool
    /// Newest first.
    private(set) var entries: [String] = []

    init(file: URL = Paths.historyFile, enabled: Bool, limit: Int = TranscriptHistory.limit, log: @escaping (String) -> Void = { Log.warning($0) }) {
        self.file = file
        self.isEnabled = enabled
        self.limit = limit
        self.log = log
        if enabled {
            entries = read()
        } else {
            remove()
        }
    }

    /// The newest transcript, what Paste Last pastes.
    var last: String? { entries.first }

    /// Adds `text` as the newest transcript and, when on, saves the file.
    /// Blank text is ignored.
    func record(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        entries.insert(text, at: 0)
        entries = Array(entries.prefix(isEnabled ? limit : 1))
        if isEnabled { save() }
    }

    /// Turns the file on or off. Off deletes it and keeps the last
    /// transcript in memory; on writes what is in memory.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            if !entries.isEmpty { save() }
        } else {
            entries = Array(entries.prefix(1))
            remove()
        }
    }

    /// Forgets every transcript, in memory and on disk.
    func clear() {
        entries = []
        remove()
    }

    // MARK: - Disk

    private func read() -> [String] {
        guard let type = Paths.fileType(file.path) else { return [] }
        guard type == .typeRegular else {
            log("\(file.path) is not a regular file; history not loaded")
            return []
        }
        var st = stat()
        guard stat(file.path, &st) == 0 else { return [] }
        guard st.st_uid == getuid() else {
            log("\(file.path) is not owned by you; history not loaded")
            return []
        }
        guard st.st_size <= Self.maxBytes else {
            log("\(file.path) is larger than \(Self.maxBytes / 1024) KB; history not loaded")
            return []
        }
        do {
            // Tighten a file loosened by hand before reading it.
            if st.st_mode & 0o077 != 0 {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            let decoded = try JSONDecoder().decode(File.self, from: Data(contentsOf: file))
            return Array(decoded.transcripts.prefix(limit))
        } catch {
            // The error names the file and the problem, never its contents.
            log("couldn't read \(file.lastPathComponent): \(Self.describe(error)); starting a new history")
            return []
        }
    }

    /// Writes a 0600 temporary file beside the history and renames it over
    /// it, so the text is never readable by others, not even for a moment,
    /// and a crash leaves either the old file or the new one.
    private func save() {
        let dir = file.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".\(file.lastPathComponent).\(getpid()).tmp")
        do {
            try Paths.prepareDirectory(dir)
            if Paths.fileType(temp.path) != nil { try FileManager.default.removeItem(at: temp) }
            try Paths.preparePrivateFile(temp)
            let data = try JSONEncoder().encode(File(transcripts: entries))
            let handle = try FileHandle(forWritingTo: temp)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            // rename(2) replaces a symlink at `file` rather than following it.
            guard rename(temp.path, file.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            log("couldn't save \(file.path): \(Self.describe(error))")
        }
    }

    private func remove() {
        guard Paths.fileType(file.path) != nil else { return }
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            log("couldn't delete \(file.path): \(Self.describe(error))")
        }
    }

    /// A decoding error without the decoder's debug text, which can quote
    /// the file.
    private static func describe(_ error: Error) -> String {
        if error is DecodingError { return "not a history file" }
        return error.localizedDescription
    }
}
