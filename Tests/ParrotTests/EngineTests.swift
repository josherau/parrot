import WhisperKit
import XCTest
@testable import ParrotCore

final class EngineTests: XCTestCase {
    func testParakeetIsRegisteredAsAMultilingualParakeetModel() throws {
        let model = try XCTUnwrap(ModelRegistry.find("parakeet-tdt-0.6b-v3"))
        XCTAssertEqual(model.engine, .parakeet)
        XCTAssertNil(model.whisperKitID)
        XCTAssertTrue(model.isMultilingual)
        XCTAssertFalse(model.recommended)
    }

    func testFactoryPicksTheEngine() throws {
        let parakeet = try XCTUnwrap(ModelRegistry.find("parakeet-tdt-0.6b-v3"))
        let whisper = try XCTUnwrap(ModelRegistry.find("whisper-base.en"))
        XCTAssertTrue(Transcribers.make(parakeet) is ParakeetTranscriber)
        XCTAssertTrue(Transcribers.make(whisper) is WhisperKitTranscriber)
    }

    func testParakeetWeightsLiveInApplicationSupport() {
        XCTAssertTrue(ParakeetTranscriber.store.path.hasPrefix(Paths.appSupport.path))
        // FluidAudio takes the repo folder from the last path component.
        XCTAssertEqual(ParakeetTranscriber.store.lastPathComponent, "parakeet-tdt-0.6b-v3-coreml")
    }

    /// Past one window WhisperKit drops speech without a chunking strategy
    /// (andredezzy/parrot 9fa3268).
    func testWhisperChunksLongAudioOnSilence() {
        for seconds in [5.0, 45.0] {
            let options = WhisperTuning.standard.decodingOptions(language: "en", promptTokens: nil, audioSeconds: seconds)
            XCTAssertEqual(options.chunkingStrategy, .vad)
        }
    }

    func testOnlyTheTwoParrotIdentifiersAreTheApp() {
        XCTAssertEqual(AppBundle.identifier, "com.humanitas.parrot")
        XCTAssertEqual(AppBundle.devIdentifier, "com.humanitas.parrot.dev")
        // The test runner is neither.
        XCTAssertFalse(AppBundle.isDev)
    }
}
