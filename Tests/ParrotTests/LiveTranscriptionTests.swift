import XCTest
@testable import ParrotCore

/// Synthetic speech: each "word" is a 0.4 s tone whose amplitude names it,
/// so a fake transcriber can say which words a piece of audio holds.
private enum Speech {
    static let rate = 16_000

    static func amplitude(_ word: Int) -> Float { 0.1 + Float(word) * 0.01 }

    static func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(rate)))
    }

    static func word(_ index: Int, seconds: Double = 0.4) -> [Float] {
        let a = amplitude(index)
        return (0..<Int(seconds * Double(rate))).map { a * sin(Float($0) * 2 * .pi * 220 / Float(rate)) }
    }

    /// `count` words, 0.1 s apart, with a 0.5 s pause after every fifth.
    static func dictation(words count: Int) -> [Float] {
        var audio = silence(0.3)
        for i in 0..<count {
            audio += word(i)
            audio += silence((i + 1) % 5 == 0 ? 0.5 : 0.1)
        }
        return audio
    }

    /// The words in `audio`, in order: one per run of loud samples, named by
    /// its peak amplitude. A word cut in two comes back twice.
    static func words(in audio: [Float]) -> [String] {
        var words: [String] = []
        var peak: Float = 0
        var quiet = 0
        for sample in audio {
            if abs(sample) > 0.05 {
                peak = max(peak, abs(sample))
                quiet = 0
            } else if peak > 0 {
                quiet += 1
                if quiet > 400 {
                    words.append(name(peak))
                    peak = 0
                }
            }
        }
        if peak > 0 { words.append(name(peak)) }
        return words
    }

    private static func name(_ peak: Float) -> String {
        "w\(Int(((peak - 0.1) / 0.01).rounded()))"
    }
}

final class PauseCutterTests: XCTestCase {
    private let options = PauseCutter.Options(minSeconds: 2, maxSeconds: 8, pauseSeconds: 0.3)

    func testWaitsUntilTheMinimum() {
        XCTAssertNil(PauseCutter.cut(Speech.dictation(words: 3), options: options))
    }

    func testCutsInTheLatestPauseAfterTheMinimum() throws {
        let audio = Speech.dictation(words: 12)
        let cut = try XCTUnwrap(PauseCutter.cut(audio, options: options))
        XCTAssertGreaterThanOrEqual(cut, 2 * Speech.rate)
        // Inside silence, so no word is split.
        XCTAssertTrue(audio[max(0, cut - 800)..<min(audio.count, cut + 800)].allSatisfy { $0 == 0 })
        XCTAssertEqual(Speech.words(in: Array(audio[..<cut])) + Speech.words(in: Array(audio[cut...])),
                       Speech.words(in: audio))
    }

    func testShortGapsBetweenWordsAreNotPauses() {
        // 0.1 s gaps only: no cut until the maximum.
        var audio = Speech.silence(0.2)
        for i in 0..<8 { audio += Speech.word(i) + Speech.silence(0.1) }
        XCTAssertNil(PauseCutter.cut(audio, options: options))
    }

    func testForcesACutPastTheMaximum() throws {
        var audio: [Float] = []
        for i in 0..<20 { audio += Speech.word(i) + Speech.silence(0.1) }
        let cut = try XCTUnwrap(PauseCutter.cut(audio, options: options))
        XCTAssertGreaterThanOrEqual(cut, 2 * Speech.rate)
        XCTAssertLessThanOrEqual(cut, audio.count - Speech.rate / 2)
    }

    func testSilenceIsNeverCut() {
        XCTAssertNil(PauseCutter.cut(Speech.silence(12), options: options))
    }

    func testAPauseGoingOnAtTheEndCounts() throws {
        var audio = Speech.silence(0.2)
        for i in 0..<8 { audio += Speech.word(i) + Speech.silence(0.1) }
        XCTAssertNil(PauseCutter.cut(audio, options: options))
        XCTAssertNotNil(PauseCutter.cut(audio + Speech.silence(0.5), options: options))
    }
}

final class LiveTranscriptionTests: XCTestCase {
    /// Reveals one more second of `audio` each time it is read.
    private final class Recording: @unchecked Sendable {
        let audio: [Float]
        private let lock = NSLock()
        private var available = 0

        init(_ audio: [Float]) { self.audio = audio }

        var isComplete: Bool {
            lock.lock()
            defer { lock.unlock() }
            return available == audio.count
        }

        func peek(from start: Int) -> [Float] {
            lock.lock()
            defer { lock.unlock() }
            available = min(audio.count, available + Speech.rate)
            return start < available ? Array(audio[start..<available]) : []
        }
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var contexts: [TranscriptionContext] = []
        func add(_ context: TranscriptionContext) {
            lock.lock()
            contexts.append(context)
            lock.unlock()
        }
    }

    private let fast = LiveTranscription.Options(
        cutter: PauseCutter.Options(minSeconds: 2, maxSeconds: 8, pauseSeconds: 0.3),
        pollInterval: 0.001
    )

    private func fakeTranscriber(calls: Calls? = nil, failOnCall: Int? = nil) -> LiveTranscription.Transcribe {
        let count = Calls()
        return { audio, context in
            count.add(context)
            calls?.add(context)
            if let failOnCall, count.contexts.count == failOnCall { throw DictationError.noAudio }
            var timings = TranscriberTimings()
            timings.language = "en"
            return Transcript(text: Speech.words(in: audio).joined(separator: " "), timings: timings)
        }
    }

    /// Lets the session read the whole recording.
    private func record(_ session: LiveTranscription, _ recording: Recording) async throws {
        await session.start()
        for _ in 0..<2_000 where !recording.isComplete {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        // Time for the last look to finish its piece.
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    func testEveryWordOnceAcrossPieces() async throws {
        let audio = Speech.dictation(words: 40)
        let recording = Recording(audio)
        let session = LiveTranscription(context: TranscriptionContext(), options: fast, peek: recording.peek, transcribe: fakeTranscriber())
        try await record(session, recording)

        let transcript = try await session.finish(audio)
        let result = try XCTUnwrap(transcript)
        XCTAssertEqual(result.text, (0..<40).map { "w\($0)" }.joined(separator: " "))
        XCTAssertGreaterThan(result.timings?.liveChunks ?? 0, 1)
    }

    func testShortDictationFallsBackToBatch() async throws {
        let audio = Speech.dictation(words: 3)
        let recording = Recording(audio)
        let session = LiveTranscription(context: TranscriptionContext(), options: fast, peek: recording.peek, transcribe: fakeTranscriber())
        try await record(session, recording)
        let transcript = try await session.finish(audio)
        XCTAssertNil(transcript)
    }

    func testAFailedPieceFallsBackToBatch() async throws {
        let audio = Speech.dictation(words: 40)
        let recording = Recording(audio)
        let session = LiveTranscription(
            context: TranscriptionContext(), options: fast, peek: recording.peek,
            transcribe: fakeTranscriber(failOnCall: 2)
        )
        try await record(session, recording)
        let transcript = try await session.finish(audio)
        XCTAssertNil(transcript)
    }

    func testCancelledSessionTranscribesNothingMore() async throws {
        let calls = Calls()
        let audio = Speech.dictation(words: 40)
        let recording = Recording(audio)
        let session = LiveTranscription(context: TranscriptionContext(), options: fast, peek: recording.peek, transcribe: fakeTranscriber(calls: calls))
        await session.cancel()
        await session.start()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(calls.contexts.isEmpty)
    }

    /// Automatic language: the first piece's language is kept for the rest.
    func testLanguageFromTheFirstPieceIsKept() async throws {
        let calls = Calls()
        let audio = Speech.dictation(words: 40)
        let recording = Recording(audio)
        let session = LiveTranscription(context: TranscriptionContext(), options: fast, peek: recording.peek, transcribe: fakeTranscriber(calls: calls))
        try await record(session, recording)
        _ = try await session.finish(audio)
        XCTAssertNil(calls.contexts.first?.language)
        XCTAssertTrue(calls.contexts.dropFirst().allSatisfy { $0.language == "en" })
    }

    func testContextWordsJoinTheDictionaryPrompt() async throws {
        let calls = Calls()
        let audio = Speech.dictation(words: 40)
        let recording = Recording(audio)
        var options = fast
        options.contextWords = 2
        let session = LiveTranscription(
            context: TranscriptionContext(language: "en", prompt: "Koen and EDF."),
            options: options, peek: recording.peek, transcribe: fakeTranscriber(calls: calls)
        )
        try await record(session, recording)
        _ = try await session.finish(audio)
        XCTAssertEqual(calls.contexts.first?.prompt, "Koen and EDF.")
        let second = try XCTUnwrap(calls.contexts.dropFirst().first?.prompt)
        XCTAssertTrue(second.hasPrefix("Koen and EDF. w"))
        XCTAssertEqual(second.split(separator: " ").count, 5)
    }

    func testJoinSkipsEmptyPieces() {
        XCTAssertEqual(LiveTranscription.join(["Hello there.", "", "  ", "How are you? "]), "Hello there. How are you?")
    }
}

final class LiveSettingsTests: XCTestCase {
    func testOnByDefaultAndDecodes() throws {
        XCTAssertTrue(try JSONDecoder().decode(Settings.self, from: Data("{}".utf8)).live.enabled)
        XCTAssertFalse(try JSONDecoder().decode(Settings.self, from: Data(#"{"live": {"enabled": false}}"#.utf8)).live.enabled)
    }
}
