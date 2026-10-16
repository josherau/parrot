import Foundation

/// Recent transcripts and Paste Last preferences.
///
/// The `settings.json` field for this feature; see `Settings`.
struct HistorySettings: Codable, Equatable {
    /// Keep the last `TranscriptHistory.limit` transcripts in
    /// `Paths.historyFile`. Off keeps only the last one, in memory.
    var enabled = true
    /// The global shortcut that pastes the last transcript, such as
    /// `"option+command+v"`, or `"off"`. One that doesn't parse is off and
    /// logged at startup.
    var pasteLastHotkey = KeyCombo.defaultPasteLast.name

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        pasteLastHotkey = try c.decodeIfPresent(String.self, forKey: .pasteLastHotkey) ?? KeyCombo.defaultPasteLast.name
    }
}
