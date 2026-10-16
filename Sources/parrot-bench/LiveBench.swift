import Foundation
import ParrotCore
import WhisperKit

/// Flags for `parrot-bench live`.
struct LiveBenchOptions: Sendable {
    var folder: String
    var runs: Int
    var model: String?
    var noPrompt: Bool
    var live: LiveTranscription.Options
    /// Replay speed; 1 is real time, as a dictation arrives.
    var speed: Double
}

/// `parrot-bench live <folder>`: release→text with and without transcribing
/// while recording, on the same recordings.
///
/// Each recording is replayed at the speed it was spoken: samples become
/// readable as wall-clock time passes, as from the microphone, while a
/// `LiveTranscription` works on them. At the end of the audio (the release)
/// the clock starts; it stops when the whole transcript is back. The batch
/// figure is the same recording transcribed whole after the release, as
/// Parrot did before. Capture stop, processing and delivery are not included
/// (tens of ms in the daemon's ⏱ line).
///
/// Prints timings, counts and word error rates, never transcript text.
enum LiveBench {
    static func run(_ options: LiveBenchOptions) throws {
        guard options.runs > 0, options.speed > 0 else {
            print("--runs and --speed must be positive")
            throw SilentExit(64)
        }
        guard let model = options.model.map(ModelRegistry.find) ?? ModelRegistry.recommended() else {
            print("unknown model: \(options.model ?? "")")
            throw SilentExit(1)
        }
        guard WhisperKitTranscriber.isCached(model) else {
            print("\(model.id) is not downloaded; run: parrot models download \(model.id)")
            throw SilentExit(1)
        }
        let files = try TranscriptionBench.recordings(in: options.folder)
        guard !files.isEmpty else {
            print("no .wav files in \(options.folder)")
            throw SilentExit(1)
        }

        var context = DictionaryContext(
            store: DictionaryStore(),
            language: DictionaryContext.language(of: model, setting: nil),
            examples: DictionaryContext.savedExamples()
        ).context()
        if options.noPrompt {
            context.prompt = nil
            context.examples = [:]
        }
        let fixedContext = context

        let transcriber = WhisperKitTranscriber(model: model)
        try TranscriptionBench.blocking { try await transcriber.warmUp() }
        let firstAudio = try AudioProcessor.loadAudioAsFloatArray(fromPath: files[0].audio.path)
        _ = try TranscriptionBench.blocking { try await transcriber.transcribe(firstAudio, context: fixedContext) }

        let cutter = options.live.cutter
        print("model \(model.id) · prompt \(fixedContext.prompt.map { "\($0.split(separator: " ").count) words" } ?? (fixedContext.examples.isEmpty ? "none" : "example for the language"))")
        print(String(
            format: "live: pieces %.0f–%.0f s, cut in pauses ≥ %.2f s, %d context words · replay %.1f× · %d runs · ms, median/p90",
            cutter.minSeconds, cutter.maxSeconds, cutter.pauseSeconds, options.live.contextWords, options.speed, options.runs
        ))
        print("")
        print("file                     audio   batch        live         pieces  wait       WER batch  WER live")

        var batchAll: [Double] = []
        var liveAll: [Double] = []
        var batchLong: [Double] = []
        var liveLong: [Double] = []
        var errors = (batch: 0, live: 0, words: 0)
        for file in files {
            let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: file.audio.path)
            let seconds = Double(audio.count) / Double(WhisperKit.sampleRate)

            var batch: [Double] = []
            var batchText = ""
            for _ in 0..<options.runs {
                let started = CFAbsoluteTimeGetCurrent()
                let transcript = try TranscriptionBench.blocking { try await transcriber.transcribe(audio, context: fixedContext) }
                batch.append((CFAbsoluteTimeGetCurrent() - started) * 1000)
                batchText = transcript.text
            }

            var live: [Double] = []
            var waits: [Double] = []
            var pieces: [Double] = []
            var liveText = ""
            for _ in 0..<options.runs {
                let result = try TranscriptionBench.blocking {
                    try await replay(audio, transcriber: transcriber, context: fixedContext, options: options)
                }
                live.append(result.releaseToText * 1000)
                waits.append((result.transcript.timings?.liveWait ?? 0) * 1000)
                pieces.append(Double(result.transcript.timings?.liveChunks ?? 0))
                liveText = result.transcript.text
                Thread.sleep(forTimeInterval: 0.5)
            }

            var werBatch: WordErrorRate?
            var werLive: WordErrorRate?
            if let reference = file.reference {
                werBatch = WordErrorRate(reference: reference, hypothesis: batchText)
                werLive = WordErrorRate(reference: reference, hypothesis: liveText)
                errors.batch += werBatch!.errors
                errors.live += werLive!.errors
                errors.words += werBatch!.referenceWords
            }
            batchAll += batch
            liveAll += live
            if seconds >= 20 {
                batchLong += batch
                liveLong += live
            }
            func pair(_ values: [Double]) -> String {
                String(format: "%.0f/%.0f", Percentile.of(values, 50), Percentile.of(values, 90))
            }
            func rate(_ wer: WordErrorRate?) -> String {
                wer.map { String(format: "%5.1f%%", $0.rate * 100) } ?? "     -"
            }
            print(
                file.audio.lastPathComponent.padding(toLength: 24, withPad: " ", startingAt: 0)
                    + String(format: "%5.1fs  ", seconds)
                    + pair(batch).padding(toLength: 13, withPad: " ", startingAt: 0)
                    + pair(live).padding(toLength: 13, withPad: " ", startingAt: 0)
                    + String(format: "%-7.0f ", Percentile.of(pieces, 50))
                    + pair(waits).padding(toLength: 11, withPad: " ", startingAt: 0)
                    + rate(werBatch) + "     " + rate(werLive)
            )
        }

        print("")
        func summary(_ label: String, _ batch: [Double], _ live: [Double]) {
            guard !batch.isEmpty else { return }
            print(String(
                format: "%@: batch median %.0f, p90 %.0f · live median %.0f, p90 %.0f",
                label, Percentile.of(batch, 50), Percentile.of(batch, 90), Percentile.of(live, 50), Percentile.of(live, 90)
            ))
        }
        summary("release→text ms, all files", batchAll, liveAll)
        summary("release→text ms, files ≥ 20 s", batchLong, liveLong)
        if errors.words > 0 {
            print(String(
                format: "WER batch %.1f%% · live %.1f%% (%d / %d errors, %d words)",
                100 * Double(errors.batch) / Double(errors.words), 100 * Double(errors.live) / Double(errors.words),
                errors.batch, errors.live, errors.words
            ))
        }
    }

    struct Replay: Sendable {
        var transcript: Transcript
        var releaseToText: TimeInterval
    }

    /// Plays `audio` into a `LiveTranscription` at the speed it was spoken,
    /// then times the release.
    static func replay(
        _ audio: [Float],
        transcriber: WhisperKitTranscriber,
        context: TranscriptionContext,
        options: LiveBenchOptions
    ) async throws -> Replay {
        let rate = Double(WhisperKit.sampleRate) * options.speed
        let started = CFAbsoluteTimeGetCurrent()
        // The microphone delivers about every 10 ms; so does this.
        let block = WhisperKit.sampleRate / 100
        let session = LiveTranscription(
            context: context,
            options: options.live,
            peek: { from in
                let elapsed = CFAbsoluteTimeGetCurrent() - started
                let available = min(audio.count, Int(elapsed * rate) / block * block)
                return from < available ? Array(audio[from..<available]) : []
            },
            transcribe: { samples, context in try await transcriber.transcribe(samples, context: context) }
        )
        await session.start()
        let duration = Double(audio.count) / rate
        let remaining = duration - (CFAbsoluteTimeGetCurrent() - started)
        if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }

        let released = CFAbsoluteTimeGetCurrent()
        let transcript: Transcript
        if let live = try await session.finish(audio) {
            transcript = live
        } else {
            transcript = try await transcriber.transcribe(audio, context: context)
        }
        return Replay(transcript: transcript, releaseToText: CFAbsoluteTimeGetCurrent() - released)
    }
}
