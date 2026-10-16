import FluidAudio
import Foundation

/// Parakeet TDT 0.6B v3 (25 European languages) through FluidAudio's CoreML
/// pipeline on the Neural Engine.
///
/// Ported from two MIT-licensed Parrot forks: FernandoGomes83/parrot
/// (e236e68, "add Parakeet TDT 0.6B v3 (FluidAudio) as second transcription
/// backend") and andredezzy/parrot (9abb27c, "parakeet: treat audio below the
/// engine minimum as silence"), adapted to ParrotCore's `Transcriber`.
///
/// Parakeet takes no prompt and no language: `TranscriptionContext` is
/// ignored, and the dictionary works through its replacements only.
package actor ParakeetTranscriber: LoadableTranscriber {
    package let modelID: String
    private var manager: AsrManager?
    private var retired = false

    package init(model: TranscriptionModel) {
        self.modelID = model.id
    }

    /// Where the weights live. FluidAudio takes the repo folder's name from
    /// the last path component, so it must be the repo's own folder name, or
    /// the downloader and the loader disagree about where the files are.
    static var store: URL {
        Paths.appSupport.appendingPathComponent("fluidaudio/parakeet-tdt-0.6b-v3-coreml", isDirectory: true)
    }

    static var isCached: Bool { AsrModels.modelsExist(at: store, version: .v3) }

    package func warmUp(progress: (@Sendable (Double) -> Void)?) async throws {
        if manager != nil || retired { return }
        Log.info("loading \(modelID)...")
        try Paths.prepareDirectory(Paths.appSupport)
        try Paths.prepareDirectory(Self.store.deletingLastPathComponent())
        let models = try await AsrModels.downloadAndLoad(to: Self.store, version: .v3) { p in
            progress?(p.fractionCompleted)
        }
        let loaded = AsrManager(config: .default)
        try await loaded.loadModels(models)
        if retired {
            await loaded.cleanup()
            return
        }
        manager = loaded
        Log.info("✓ \(modelID) ready")
    }

    package func unload() async {
        retired = true
        await manager?.cleanup()
        manager = nil
    }

    package func transcribe(_ audio: [Float], context _: TranscriptionContext) async throws -> Transcript {
        if manager == nil { try await warmUp() }
        guard let manager else { throw TranscriberError.notLoaded }
        let started = CFAbsoluteTimeGetCurrent()
        var timings = TranscriberTimings()
        timings.audioSeconds = Double(audio.count) / AudioCapture.targetSampleRate

        // Shorter than the engine's own minimum it throws instead of
        // returning nothing, and a tap on the hotkey is silence, not a failure.
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: Int(AudioCapture.targetSampleRate))
        guard audio.count >= minimum else {
            timings.total = CFAbsoluteTimeGetCurrent() - started
            return Transcript(text: "", timings: timings)
        }

        // Each dictation, and each piece of one, starts from a clean decoder.
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(audio, decoderState: &state)
        timings.total = CFAbsoluteTimeGetCurrent() - started
        // FluidAudio reports no split by stage; the ⏱ line shows it as decoder.
        timings.decoder = timings.total
        // No sanitize: Parakeet emits plain text, not Whisper's [BLANK_AUDIO]
        // placeholders, and stripping brackets would eat dictated ones.
        return Transcript(text: result.text.trimmingCharacters(in: .whitespacesAndNewlines), timings: timings)
    }
}
