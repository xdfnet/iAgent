import XCTest
@testable import iAgent

final class PlaybackServiceStateStreamTests: XCTestCase {
    func testStateStreamEmitsStateChanges() async throws {
        let service = PlaybackService()
        var iterator = service.stateStream.makeAsyncIterator()

        let initial = await iterator.next()
        XCTAssertEqual(initial, .idle)

        await service._setStateForTesting(.playing)
        let playing = await iterator.next()
        XCTAssertEqual(playing, .playing)

        await service._setStateForTesting(.idle)
        let idle = await iterator.next()
        XCTAssertEqual(idle, .idle)
    }
}
