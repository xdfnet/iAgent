import XCTest
@testable import iAgent

final class VoiceServiceCoverageTests: XCTestCase {
    private func nextValue<T>(
        from stream: AsyncStream<T>,
        timeoutNanoseconds: UInt64 = 100_000_000
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func makeConfig(
        interruptOnSpeech: Bool = false,
        postInterruptCooldownSeconds: Double = 0.1
    ) -> VoiceService.Config {
        VoiceService.Config(
            sampleRate: 1000,
            channels: 1,
            sampleWidth: 2,
            frameMs: 10,
            startThreshold: 50,
            playingStartThreshold: 100,
            endThreshold: 20,
            startFrames: 2,
            playingStartFrames: 2,
            endSilenceFrames: 2,
            prerollFrames: 1,
            minSpeechFrames: 3,
            postInterruptCooldownSeconds: postInterruptCooldownSeconds,
            interruptOnSpeech: interruptOnSpeech,
            inputDeviceIndex: "0"
        )
    }

    func testConfigDefaultInitializerValues() {
        let config = VoiceService.Config()
        XCTAssertEqual(config.sampleRate, 16000)
        XCTAssertEqual(config.channels, 1)
        XCTAssertEqual(config.sampleWidth, 2)
        XCTAssertEqual(config.frameMs, 30)
        XCTAssertEqual(config.frameBytes, 960)
        XCTAssertEqual(config.inputDeviceID, "0")
    }

    func testInputDeviceIDUsesConfiguredValue() {
        let config = VoiceService.Config(
            sampleRate: 16000,
            channels: 1,
            sampleWidth: 2,
            frameMs: 30,
            startThreshold: 2200,
            playingStartThreshold: 4200,
            endThreshold: 900,
            startFrames: 7,
            playingStartFrames: 10,
            endSilenceFrames: 28,
            prerollFrames: 14,
            minSpeechFrames: 12,
            postInterruptCooldownSeconds: 1.2,
            interruptOnSpeech: false,
            inputDeviceIndex: "2"
        )
        XCTAssertEqual(config.inputDeviceID, "2")
    }

    func testInputDeviceIDFallsBackToFirstLegacyConfiguredValue() {
        let config = VoiceService.Config(
            sampleRate: 16000,
            channels: 1,
            sampleWidth: 2,
            frameMs: 30,
            startThreshold: 2200,
            playingStartThreshold: 4200,
            endThreshold: 900,
            startFrames: 7,
            playingStartFrames: 10,
            endSilenceFrames: 28,
            prerollFrames: 14,
            minSpeechFrames: 12,
            postInterruptCooldownSeconds: 1.2,
            interruptOnSpeech: false,
            inputDeviceIndex: "2, 2, 5"
        )
        XCTAssertEqual(config.inputDeviceID, "2")
    }

    func testInputDeviceIDAutoKeepsFallbackValue() {
        let config = VoiceService.Config(
            sampleRate: 16000,
            channels: 1,
            sampleWidth: 2,
            frameMs: 30,
            startThreshold: 2200,
            playingStartThreshold: 4200,
            endThreshold: 900,
            startFrames: 7,
            playingStartFrames: 10,
            endSilenceFrames: 28,
            prerollFrames: 14,
            minSpeechFrames: 12,
            postInterruptCooldownSeconds: 1.2,
            interruptOnSpeech: false,
            inputDeviceIndex: "auto"
        )
        XCTAssertEqual(config.inputDeviceID, "0")
    }

    func testCleanupResetsListeningFlag() async {
        let service = VoiceService(config: makeConfig())
        await service._setIsRunningForTesting(true)
        let listeningBeforeCleanup = await service.isListening
        XCTAssertTrue(listeningBeforeCleanup)

        await service.cleanup()

        let listeningAfterCleanup = await service.isListening
        XCTAssertFalse(listeningAfterCleanup)
    }

    func testLastInterruptTestingHookAcceptsValue() async {
        let service = VoiceService(config: makeConfig(interruptOnSpeech: true))
        await service._setLastInterruptAtForTesting(Date())
        await service._setLastInterruptAtForTesting(nil)
        let listening = await service.isListening
        XCTAssertFalse(listening)
    }

    func testDiagnosticStreamIsSeparatedFromErrorStream() async {
        let service = VoiceService(config: makeConfig())

        await service._emitDiagnosticForTesting("diag-message")

        let diagnostic = await nextValue(from: service.diagnosticStream)
        XCTAssertEqual(diagnostic, "diag-message")

        let error = await nextValue(from: service.errorStream, timeoutNanoseconds: 50_000_000)
        XCTAssertNil(error)
    }
}
