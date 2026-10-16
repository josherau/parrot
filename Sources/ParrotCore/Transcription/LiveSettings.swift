import Foundation

/// Transcribe while recording (`LiveTranscription`).
///
/// The `settings.json` field for this feature; see `Settings`.
struct LiveSettings: Codable, Equatable {
    /// Transcribe finished parts of a dictation while it is recorded, so the
    /// release waits only for the rest. Off transcribes the whole capture
    /// after the release, as before.
    var enabled = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}
