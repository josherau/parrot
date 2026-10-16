import Foundation

/// Transcribes a dictation while it is still being recorded, so the release
/// only waits for the last few seconds.
///
/// Every `pollInterval` it looks at the audio not yet transcribed and asks
/// `PauseCutter` for a cut in a pause. Each piece up to a cut is transcribed
/// on its own, exactly as a short dictation would be (trim, pad, prompt), one
/// at a time. At the release, `finish` waits for a piece in progress,
/// transcribes the rest, and joins the texts. Cutting only in pauses means no
/// word is split and nothing overlaps, so the pieces join with a space.
///
/// `finish` returns nil when nothing was transcribed during the recording
/// (a short dictation) or a piece failed: the caller then transcribes the
/// whole capture as before. Logs counts and timings, never text.
package actor LiveTranscription {
    package typealias Transcribe = @Sendable ([Float], TranscriptionContext) async throws -> Transcript

    package struct Options: Equatable, Sendable {
        package var cutter = PauseCutter.Options()
        /// Seconds between looks at the audio.
        package var pollInterval: Double = 0.25
        /// Words of the previous piece's text added to the prompt, so a piece
        /// that starts mid-sentence continues it. Each costs a decoder step.
        package var contextWords = 0

        package init(cutter: PauseCutter.Options = PauseCutter.Options(), pollInterval: Double = 0.25, contextWords: Int = 0) {
            self.cutter = cutter
            self.pollInterval = pollInterval
            self.contextWords = contextWords
        }
    }

    private let transcribe: Transcribe
    private let peek: @Sendable (Int) -> [Float]
    private let options: Options
    private var context: TranscriptionContext
    /// The prompt before any previous-piece words were added.
    private let basePrompt: String?

    /// Samples transcribed so far, from the start of the capture.
    private var committed = 0
    private var pieces: [String] = []
    private var pieceSeconds: TimeInterval = 0
    private var failed = false
    private var stopped = false
    private var loop: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?

    /// `peek(n)` returns the samples captured so far from index `n` on.
    package init(
        context: TranscriptionContext,
        options: Options = Options(),
        peek: @escaping @Sendable (Int) -> [Float],
        transcribe: @escaping Transcribe
    ) {
        self.context = context
        self.basePrompt = context.prompt
        self.options = options
        self.peek = peek
        self.transcribe = transcribe
    }

    package func start() {
        guard loop == nil, !stopped else { return }
        let interval = UInt64(max(0.01, options.pollInterval) * 1_000_000_000)
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard let self, await self.step() else { return }
            }
        }
    }

    /// The recording was discarded: stop, and drop anything in progress.
    package func cancel() {
        stopped = true
        loop?.cancel()
    }

    /// The whole capture's transcript, or nil to transcribe it the usual way.
    /// `capture` is every sample of the recording.
    package func finish(_ capture: [Float]) async throws -> Transcript? {
        stopped = true
        loop?.cancel()
        let waitStarted = CFAbsoluteTimeGetCurrent()
        if let inFlight { await inFlight.value }
        let waited = CFAbsoluteTimeGetCurrent() - waitStarted
        guard !failed, committed > 0, committed <= capture.count else { return nil }

        let tail = Array(capture[committed...])
        var tailTranscript = Transcript(text: "", timings: nil)
        if SilenceTrimmer.voicedRange(tail) != nil {
            tailTranscript = try await transcribe(tail, contextForNextPiece())
        }
        var timings = tailTranscript.timings ?? TranscriberTimings()
        timings.liveChunks = pieces.count
        timings.liveSeconds = pieceSeconds
        timings.liveWait = waited
        timings.total += waited
        if timings.language == nil { timings.language = context.language }
        Log.info(String(
            format: "  live: %d piece%@ (%.1f s) during recording · waited %.0f ms · tail %.1f s",
            pieces.count, pieces.count == 1 ? "" : "s", pieceSeconds, waited * 1000,
            Double(tail.count) / Double(PauseCutter.sampleRate)
        ))
        return Transcript(text: Self.join(pieces + [tailTranscript.text]), timings: timings)
    }

    /// One look at the audio. Returns false once the loop should end.
    private func step() async -> Bool {
        guard !stopped, !failed else { return false }
        let pending = peek(committed)
        guard let cut = PauseCutter.cut(pending, options: options.cutter) else { return true }
        let piece = Array(pending[..<cut])
        let task = Task { await self.transcribePiece(piece) }
        inFlight = task
        await task.value
        inFlight = nil
        return !stopped && !failed
    }

    private func transcribePiece(_ piece: [Float]) async {
        let started = CFAbsoluteTimeGetCurrent()
        do {
            let transcript = try await transcribe(piece, contextForNextPiece())
            guard !failed else { return }
            pieces.append(transcript.text)
            committed += piece.count
            let seconds = Double(piece.count) / Double(PauseCutter.sampleRate)
            pieceSeconds += seconds
            // Automatic language: the first piece decides for the rest, so
            // every piece is decoded in one language.
            if context.language == nil, let language = transcript.timings?.language {
                context.language = language
            }
            Log.info(String(format: "  live piece %.1f s → %.0f ms", seconds, (CFAbsoluteTimeGetCurrent() - started) * 1000))
        } catch {
            failed = true
            Log.warning("live transcription failed: \(error); transcribing the whole capture at release")
        }
    }

    /// The context with the last `contextWords` words already transcribed
    /// added to the prompt.
    private func contextForNextPiece() -> TranscriptionContext {
        guard options.contextWords > 0 else { return context }
        let words = Self.join(pieces).split(separator: " ").suffix(options.contextWords)
        guard !words.isEmpty else { return context }
        var next = context
        let previous = words.joined(separator: " ")
        next.prompt = [basePrompt, previous].compactMap { $0 }.joined(separator: " ")
        // Automatic picks its prompt from `examples`; carry the words there too.
        next.examples = context.examples.mapValues { "\($0) \(previous)" }
        return next
    }

    /// Pieces' texts in order, one space between, empty pieces skipped.
    package static func join(_ texts: [String]) -> String {
        texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
