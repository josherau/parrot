import Foundation

/// Where to cut audio still being recorded so the finished part can be
/// transcribed now: in the middle of a pause, so no word is split and the
/// pieces join without overlap. Pure, so it is tested.
///
/// Uses the same 10 ms energy frames as `SilenceTrimmer`. A frame is quiet
/// below `max(SilenceTrimmer.minimumLevel, peak × relativeLevel)`, with the
/// peak taken over the audio given.
package enum PauseCutter {
    package struct Options: Equatable, Sendable {
        /// Shortest piece worth a transcription of its own.
        package var minSeconds: Double = 6
        /// Past this with no pause, cut at the quietest frame anyway, so a
        /// piece stays inside one 30 s window.
        package var maxSeconds: Double = 20
        /// A pause this long counts.
        package var pauseSeconds: Double = 0.3
        /// Quiet below this fraction of the loudest frame. Looser than the
        /// trimmer's: a pause between words is rarely true silence.
        package var relativeLevel: Float = 0.1

        package init(minSeconds: Double = 6, maxSeconds: Double = 20, pauseSeconds: Double = 0.3, relativeLevel: Float = 0.1) {
            self.minSeconds = minSeconds
            self.maxSeconds = maxSeconds
            self.pauseSeconds = pauseSeconds
            self.relativeLevel = relativeLevel
        }
    }

    static let frameLength = SilenceTrimmer.frameLength
    static let sampleRate = SilenceTrimmer.sampleRate

    /// The sample index to cut `audio` at, or nil to wait for more. The cut
    /// is the middle of the latest pause that starts at or after
    /// `minSeconds`; without one, once `audio` is longer than `maxSeconds`,
    /// the quietest frame after `minSeconds`, keeping the last half second.
    package static func cut(_ audio: [Float], options: Options = Options()) -> Int? {
        let minFrames = Int(options.minSeconds * Double(sampleRate)) / frameLength
        let levels = frameLevels(audio)
        guard levels.count > minFrames else { return nil }
        let peak = levels.max() ?? 0
        let threshold = max(SilenceTrimmer.minimumLevel, peak * options.relativeLevel)
        let pauseFrames = max(1, Int(options.pauseSeconds * Double(sampleRate)) / frameLength)

        // Nothing voiced yet: no piece worth transcribing.
        guard peak >= threshold else { return nil }

        // Runs of quiet frames, latest first. A run still going on at the end
        // counts: the speaker is pausing now.
        var best: Int?
        var f = levels.count - 1
        while f >= minFrames {
            guard levels[f] < threshold else {
                f -= 1
                continue
            }
            let end = f + 1
            var start = f
            while start > 0, levels[start - 1] < threshold { start -= 1 }
            let middle = (start + end) / 2
            if end - start >= pauseFrames, middle >= minFrames {
                best = middle
                break
            }
            f = start - 1
        }
        if let best { return best * frameLength }

        let maxFrames = Int(options.maxSeconds * Double(sampleRate)) / frameLength
        guard levels.count > maxFrames else { return nil }
        let keep = sampleRate / 2 / frameLength
        let window = minFrames..<min(levels.count, max(minFrames + 1, levels.count - keep))
        guard let quietest = window.min(by: { levels[$0] < levels[$1] }) else { return nil }
        return quietest * frameLength
    }

    /// RMS of each whole 10 ms frame.
    static func frameLevels(_ audio: [Float]) -> [Float] {
        let frames = audio.count / frameLength
        var levels = [Float](repeating: 0, count: frames)
        audio.withUnsafeBufferPointer { samples in
            for f in 0..<frames {
                var sum: Float = 0
                for s in samples[(f * frameLength)..<((f + 1) * frameLength)] { sum += s * s }
                levels[f] = (sum / Float(frameLength)).squareRoot()
            }
        }
        return levels
    }
}
