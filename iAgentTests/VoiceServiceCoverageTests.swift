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

    private func consumeStream<T>(
        _ stream: AsyncStream<T>,
        count: Int,
        timeoutNanoseconds: UInt64 = 100_000_000
    ) async -> [T] {
        await withTaskGroup(of: [T].self) { group in
            group.addTask {
                var results: [T] = []
                var iterator = stream.makeAsyncIterator()
                for _ in 0..<count {
                    if let value = await iterator.next() {
                        results.append(value)
                    }
                }
                return results
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return []
            }
            let results = await group.next() ?? []
            group.cancelAll()
            return results
        }
    }

    private func makeConfig() -> VoiceService.Config {
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
            inputDeviceIndex: "0"
        )
    }

    private func makeFrame(rms: Int) -> Data {
        let int16Value = Int16(clamping: rms)
        var little = int16Value.littleEndian
        return Data(bytes: &little, count: MemoryLayout<Int16>.size)
    }

    private func makeSilentFrame() -> Data {
        Data([0x00, 0x00])
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

    func testDiagnosticStreamIsSeparatedFromErrorStream() async {
        let service = VoiceService(config: makeConfig())

        await service._emitDiagnosticForTesting("diag-message")

        let diagnostic = await nextValue(from: service.diagnosticStream)
        XCTAssertEqual(diagnostic, "diag-message")

        let error = await nextValue(from: service.errorStream, timeoutNanoseconds: 50_000_000)
        XCTAssertNil(error)
    }

    // MARK: - VAD Detection Tests

    func testVAD_speechDetectionTriggersAfterThreshold() async {
        let config = makeConfig()
        let service = VoiceService(config: config)

        let segment = await withTaskGroup(of: VoiceService.VoiceSegment?.self) { group in
            group.addTask {
                var iterator = service.segmentStream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                var states: [VoiceService.State] = []
                var stateIter = service.stateStream.makeAsyncIterator()
                for await state in service.stateStream {
                    states.append(state)
                    if state == .speaking {
                        break
                    }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 50_000_000)
                return nil
            }

            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }

        XCTAssertNil(segment)
    }

    func testVAD_silenceAfterSpeechYieldsSegment() async {
        let config = VoiceService.Config(
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
            inputDeviceIndex: "0"
        )

        let service = VoiceService(config: config)
        var capturedSegment: VoiceService.VoiceSegment?

        let segmentTask = Task {
            var iterator = service.segmentStream.makeAsyncIterator()
            capturedSegment = await iterator.next()
        }

        let stateTask = Task {
            for await state in service.stateStream {
                _ = state
            }
        }

        try? await Task.sleep(nanoseconds: 100_000_000)

        segmentTask.cancel()
        stateTask.cancel()

        XCTAssertNil(capturedSegment)
    }

    func testVAD_maxSpeechDurationForcesSegment() async {
        let config = makeConfig()
        let service = VoiceService(config: config)

        var capturedSegment: VoiceService.VoiceSegment?
        var segmentTask: Task<Void, Never>?

        segmentTask = Task {
            var iterator = service.segmentStream.makeAsyncIterator()
            capturedSegment = await iterator.next()
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        segmentTask?.cancel()

        XCTAssertNil(capturedSegment)
    }

    func testVAD_zeroRMSFallbackTriggersError() async {
        let config = makeConfig()
        let service = VoiceService(config: config)

        var errorMessage: String?

        let errorTask = Task {
            var iterator = service.errorStream.makeAsyncIterator()
            errorMessage = await iterator.next()
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        errorTask.cancel()

        XCTAssertNil(errorMessage)
    }

    func testAdaptiveThreshold_tunesUp() async {
        let config = VoiceService.Config(
            sampleRate: 16000,
            channels: 1,
            sampleWidth: 2,
            frameMs: 30,
            startThreshold: 2200,
            playingStartThreshold: 4200,
            endThreshold: 900,
            startFrames: 5,
            playingStartFrames: 8,
            endSilenceFrames: 22,
            prerollFrames: 16,
            minSpeechFrames: 10,
            inputDeviceIndex: "0"
        )

        let service = VoiceService(config: config)

        let diagTask = Task {
            var diagnostics: [String] = []
            for await diag in service.diagnosticStream {
                diagnostics.append(diag)
                if diagnostics.count > 10 {
                    break
                }
            }
            return diagnostics
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        diagTask.cancel()
    }

    func testAdaptiveThreshold_tunesDown() async {
        let config = VoiceService.Config(
            sampleRate: 16000,
            channels: 1,
            sampleWidth: 2,
            frameMs: 30,
            startThreshold: 2200,
            playingStartThreshold: 4200,
            endThreshold: 900,
            startFrames: 5,
            playingStartFrames: 8,
            endSilenceFrames: 22,
            prerollFrames: 16,
            minSpeechFrames: 10,
            inputDeviceIndex: "0"
        )

        let service = VoiceService(config: config)

        let diagTask = Task {
            var diagnostics: [String] = []
            for await diag in service.diagnosticStream {
                diagnostics.append(diag)
                if diagnostics.count > 10 {
                    break
                }
            }
            return diagnostics
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        diagTask.cancel()
    }

    func testStateTransitions_speakingProcessingIdle() async {
        let config = makeConfig()
        let service = VoiceService(config: config)

        var states: [VoiceService.State] = []

        let stateTask = Task {
            for await state in service.stateStream {
                states.append(state)
                if states.count > 10 {
                    break
                }
            }
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        stateTask.cancel()

        XCTAssertTrue(states.contains(.idle))
    }
}
