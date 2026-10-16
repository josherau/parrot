import Foundation

/// A `Transcriber` whose model is loaded before use and freed after a model
/// change (#43).
package protocol LoadableTranscriber: Transcriber {
    /// Loads the model, downloading it first if needed. `progress` gets the
    /// download's fraction done, 0 to 1.
    func warmUp(progress: (@Sendable (Double) -> Void)?) async throws
    /// Frees the model; a load still running is dropped.
    func unload() async
}

extension LoadableTranscriber {
    package func warmUp() async throws { try await warmUp(progress: nil) }
}

/// The transcriber for each engine in the registry.
package enum Transcribers {
    /// `tuning` applies to Whisper models only.
    package static func make(_ model: TranscriptionModel, tuning: WhisperTuning = .standard) -> any LoadableTranscriber {
        switch model.engine {
        case .whisperKit: return WhisperKitTranscriber(model: model, tuning: tuning)
        case .parakeet: return ParakeetTranscriber(model: model)
        }
    }

    /// True if the model's weights are already on this Mac.
    package static func isCached(_ model: TranscriptionModel) -> Bool {
        switch model.engine {
        case .whisperKit: return WhisperKitTranscriber.isCached(model)
        case .parakeet: return ParakeetTranscriber.isCached
        }
    }
}
