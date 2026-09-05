import XCTest
@testable import GomokuWatch

@MainActor
final class GameViewModelTests: XCTestCase {
    func testHumanMoveRequiresSelectionAndConfirmation() {
        let game = GameViewModel()
        game.choosePlayerMatch()
        let center = BoardPosition(row: 50, column: 50)

        game.tap(center)
        XCTAssertEqual(game.selectedPosition, center)
        XCTAssertNil(game.board.stone(at: center))

        game.tap(center)
        XCTAssertEqual(game.board.stone(at: center), .black)
        XCTAssertEqual(game.lastMovePosition, center)
        XCTAssertEqual(game.turn, .white)
    }

    func testInactivityRequiresExplicitResumeOrAbandonDecision() {
        let game = GameViewModel()
        game.choosePlayerMatch()
        let center = BoardPosition(row: 50, column: 50)

        game.pauseForInactivity()
        XCTAssertTrue(game.isPaused)
        game.tap(center)
        XCTAssertNil(game.selectedPosition)

        game.resumeAfterInactivity()
        XCTAssertFalse(game.isPaused)
        game.tap(center)
        XCTAssertEqual(game.selectedPosition, center)
    }

    func testPlayerMatchCanUndoEveryMoveBackToOpening() {
        let game = GameViewModel()
        game.choosePlayerMatch()
        let black = BoardPosition(row: 50, column: 50)
        let white = BoardPosition(row: 50, column: 51)

        game.tap(black)
        game.tap(black)
        game.tap(white)
        game.tap(white)
        XCTAssertEqual(game.board.stones.count, 2)
        XCTAssertTrue(game.canUndo)

        game.undoLastTurn()
        XCTAssertNil(game.board.stone(at: white))
        XCTAssertEqual(game.turn, .white)
        XCTAssertEqual(game.lastMovePosition, black)

        game.undoLastTurn()
        XCTAssertTrue(game.board.stones.isEmpty)
        XCTAssertEqual(game.turn, .black)
        XCTAssertNil(game.lastMovePosition)
        XCTAssertFalse(game.canUndo)
    }

    func testUndoCancelsPendingComputerReply() async {
        let game = GameViewModel()
        game.chooseAIMatch(difficulty: .easy)
        let center = BoardPosition(row: 50, column: 50)

        game.tap(center)
        game.tap(center)
        XCTAssertEqual(game.board.stones.count, 1)

        game.undoLastTurn()
        try? await Task.sleep(for: .milliseconds(650))

        XCTAssertTrue(game.board.stones.isEmpty)
        XCTAssertEqual(game.turn, .black)
        XCTAssertFalse(game.canUndo)
    }

    func testPlayerCanChooseWhiteAndComputerMakesTheOpeningMove() async {
        let game = GameViewModel()
        game.chooseAIMatch(difficulty: .easy, playerColor: .white)

        XCTAssertEqual(game.blackOwner, 1)
        XCTAssertEqual(game.turn, .black)
        XCTAssertTrue(game.isComputerTurn)

        try? await Task.sleep(for: .milliseconds(750))

        XCTAssertEqual(game.board.stones.count, 1)
        XCTAssertEqual(game.board.stones.values.first, .black)
        XCTAssertEqual(game.turn, .white)
        XCTAssertEqual(game.playerName, "玩家")
        XCTAssertFalse(game.isComputerTurn)
    }

    func testAIMatchUndoRemovesComputerReplyAndPlayerMove() async {
        let game = GameViewModel()
        game.chooseAIMatch(difficulty: .easy)
        let center = BoardPosition(row: 50, column: 50)

        game.tap(center)
        game.tap(center)
        try? await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(game.board.stones.count, 2)

        game.undoLastTurn()

        XCTAssertTrue(game.board.stones.isEmpty)
        XCTAssertEqual(game.turn, .black)
        XCTAssertNil(game.lastMovePosition)
        XCTAssertFalse(game.canUndo)
    }

    func testWinningMoveCanBeUndoneAndMatchContinues() {
        let game = GameViewModel()
        game.choosePlayerMatch()

        let blackMoves = (48...52).map { BoardPosition(row: 50, column: $0) }
        let whiteMoves = (48...51).map { BoardPosition(row: 51, column: $0) }
        for index in blackMoves.indices {
            game.tap(blackMoves[index])
            game.tap(blackMoves[index])
            if index < whiteMoves.count {
                game.tap(whiteMoves[index])
                game.tap(whiteMoves[index])
            }
        }
        XCTAssertTrue(game.isFinished)
        XCTAssertEqual(game.blackOwner, 0)
        let stoneCount = game.board.stones.count

        game.undoLastTurn()

        XCTAssertFalse(game.isFinished)
        XCTAssertTrue(game.canUndo)
        XCTAssertEqual(game.board.stones.count, stoneCount - 1)
        XCTAssertNil(game.board.stone(at: blackMoves.last!))
        XCTAssertNil(game.winner)
        XCTAssertTrue(game.winningLine.isEmpty)
        XCTAssertEqual(game.turn, .black)
        XCTAssertEqual(game.lastMovePosition, whiteMoves.last)
        XCTAssertEqual(game.blackOwner, 0)

        let replacement = BoardPosition(row: 52, column: 52)
        game.tap(replacement)
        game.tap(replacement)
        XCTAssertEqual(game.board.stone(at: replacement), .black)
    }

    func testNearEdgeMovesExpandVisibleBoardWithoutChangingLogicalCoordinates() {
        let game = GameViewModel()
        game.choosePlayerMatch()
        let firstVisibleEdge = BoardPosition(row: 50, column: 53)
        let secondVisibleEdge = BoardPosition(row: 50, column: 58)

        game.tap(firstVisibleEdge)
        XCTAssertEqual(game.visibleLineCount, 11)
        XCTAssertNil(game.board.stone(at: firstVisibleEdge))
        game.tap(firstVisibleEdge)

        XCTAssertEqual(game.board.size, 101)
        XCTAssertEqual(game.board.stone(at: firstVisibleEdge), .black)
        XCTAssertEqual(game.viewportCenter, BoardPosition(row: 50, column: 50))
        XCTAssertEqual(game.visibleLineCount, 21)

        game.tap(secondVisibleEdge)
        game.tap(secondVisibleEdge)

        XCTAssertEqual(game.board.stone(at: secondVisibleEdge), .white)
        XCTAssertEqual(game.viewportCenter, BoardPosition(row: 50, column: 50))
        XCTAssertEqual(game.visibleLineCount, 31)
    }

    func testExpandedBoardCanStillReachTwiceTheInitialCellSize() {
        for visibleLineCount in [11, 21, 31, 101] {
            let scales = BoardZoomMetrics.surfaceScales(for: visibleLineCount)
            let maximumCellScale = BoardZoomMetrics.cellScale(
                surfaceScale: scales.last!,
                visibleLineCount: visibleLineCount
            )

            XCTAssertEqual(scales.first, 1.0)
            for (previous, next) in zip(scales, scales.dropFirst()) {
                XCTAssertEqual(next - previous, 0.5, accuracy: 0.000_001)
            }
            XCTAssertEqual(maximumCellScale, 2.0, accuracy: 0.000_001)
        }

        XCTAssertEqual(BoardZoomMetrics.surfaceScales(for: 11), [1.0, 1.5, 2.0])
        XCTAssertEqual(BoardZoomMetrics.surfaceScales(for: 21).last, 4.0)
        XCTAssertEqual(BoardZoomMetrics.surfaceScales(for: 31).last, 6.0)
    }

    func testWinningDoesNotChangeColorsAndNewMatchStartsIndependently() {
        let game = GameViewModel()
        game.choosePlayerMatch()

        let blackMoves = (48...52).map { BoardPosition(row: 50, column: $0) }
        let whiteMoves = (48...51).map { BoardPosition(row: 51, column: $0) }
        for index in 0..<blackMoves.count {
            game.tap(blackMoves[index])
            game.tap(blackMoves[index])
            if index < whiteMoves.count {
                game.tap(whiteMoves[index])
                game.tap(whiteMoves[index])
            }
        }

        XCTAssertEqual(game.winner, 0)
        XCTAssertEqual(game.blackOwner, 0)
        XCTAssertEqual(game.lastMovePosition, blackMoves.last)
        XCTAssertEqual(game.winningLine, blackMoves)
        XCTAssertFalse(game.showResult)

        game.returnToModeSelection()
        game.choosePlayerMatch()
        XCTAssertEqual(game.blackOwner, 0)
        XCTAssertEqual(game.playerName, "玩家1")
    }

    func testWinningBoardStaysVisibleUntilReturningThenClears() {
        let game = GameViewModel()
        game.choosePlayerMatch()

        let blackMoves = (48...52).map { BoardPosition(row: 50, column: $0) }
        let whiteMoves = (48...51).map { BoardPosition(row: 51, column: $0) }
        for index in blackMoves.indices {
            game.tap(blackMoves[index])
            game.tap(blackMoves[index])
            if index < whiteMoves.count {
                game.tap(whiteMoves[index])
                game.tap(whiteMoves[index])
            }
        }

        XCTAssertEqual(game.board.stones.count, 9)
        XCTAssertEqual(game.winningLine.count, 5)
        XCTAssertTrue(game.isFinished)

        game.returnToModeSelection()

        XCTAssertTrue(game.board.stones.isEmpty)
        XCTAssertNil(game.lastMovePosition)
        XCTAssertTrue(game.winningLine.isEmpty)
        XCTAssertNil(game.winner)
        XCTAssertEqual(game.screen, .modeSelection)
    }
    func testPausedSearchCannotCommitIntoLaterTurnAfterResume() async {
        let worker = ControlledComputer()
        let game = GameViewModel(computerMoveDelay: .zero) { board, _, _ in
            await worker.move(on: board)
        }
        game.chooseAIMatch(difficulty: .hard)
        let first = BoardPosition(row: 50, column: 50)
        game.tap(first); game.tap(first)
        await waitForRequests(1, worker: worker)

        game.pauseForInactivity()
        game.resumeAfterInactivity()
        game.resumeAfterInactivity() // Must not schedule a duplicate.
        await waitForRequests(2, worker: worker)
        await worker.complete(1, at: BoardPosition(row: 51, column: 50))
        await waitForStones(2, game: game)

        let second = BoardPosition(row: 52, column: 50)
        game.tap(second); game.tap(second)
        await waitForRequests(3, worker: worker)
        let stale = BoardPosition(row: 49, column: 50)
        await worker.complete(0, at: stale) // Ignores cancellation deliberately.
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(game.board.stones.count, 3)
        XCTAssertNil(game.board.stone(at: stale))
        XCTAssertTrue(game.isComputerTurn)
        let snapshots = await worker.counts
        XCTAssertEqual(snapshots, [1, 1, 3])

        await worker.complete(2, at: BoardPosition(row: 48, column: 50))
        await waitForStones(4, game: game)
        game.returnToModeSelection()
    }

    func testPauseCancelsDelayedSearchBeforeItStarts() async {
        let worker = ControlledComputer()
        let game = GameViewModel(computerMoveDelay: .milliseconds(100)) { board, _, _ in
            await worker.move(on: board)
        }
        game.chooseAIMatch(difficulty: .easy, playerColor: .white)
        game.pauseForInactivity()
        try? await Task.sleep(for: .milliseconds(200))
        let counts = await worker.counts
        XCTAssertTrue(counts.isEmpty)
        XCTAssertTrue(game.board.stones.isEmpty)
        game.returnToModeSelection()
    }

    func testOldSearchCannotCommitAfterUndoOrNewColorSelection() async {
        let worker = ControlledComputer()
        let game = GameViewModel(computerMoveDelay: .zero) { board, _, _ in
            await worker.move(on: board)
        }
        game.chooseAIMatch(difficulty: .easy)
        let center = BoardPosition(row: 50, column: 50)
        game.tap(center); game.tap(center)
        await waitForRequests(1, worker: worker)
        game.undoLastTurn()
        await worker.complete(0, at: BoardPosition(row: 51, column: 50))
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(game.board.stones.isEmpty)

        game.tap(center); game.tap(center)
        await waitForRequests(2, worker: worker)
        game.returnToModeSelection()
        game.chooseAIMatch(difficulty: .easy, playerColor: .white)
        await waitForRequests(3, worker: worker)
        await worker.complete(1, at: BoardPosition(row: 51, column: 50))
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(game.board.stones.isEmpty)
        XCTAssertEqual(game.blackOwner, 1)
        await worker.complete(2, at: center)
        await waitForStones(1, game: game)
        XCTAssertEqual(game.board.stone(at: center), .black)
        game.returnToModeSelection()
    }

    func testViewportCullsExpandedBoardAndHitTestingTracksDragAndZoom() {
        for lines in [11, 21, 31, 51, 101] {
            for scale in BoardZoomMetrics.surfaceScales(for: lines) {
                for offset in [CGSize.zero, CGSize(width: -75, height: 42)] {
                    let layout = BoardViewportLayout(
                        boardSize: 101, center: BoardPosition(row: 50, column: 50),
                        lineCount: min(lines + 4, 101), step: 200 * scale / CGFloat(lines - 1),
                        viewport: CGSize(width: 200, height: 200), offset: offset
                    )
                    for row in layout.visibleRows {
                        for column in layout.visibleColumns {
                            let position = BoardPosition(row: row, column: column)
                            XCTAssertEqual(layout.position(at: layout.point(for: position)), position)
                        }
                    }
                    if scale == BoardZoomMetrics.surfaceScales(for: lines).last {
                        XCTAssertLessThan(layout.visibleIntersectionCount, 100)
                    }
                    if lines == 101 && scale == 1 {
                        XCTAssertFalse(layout.usesIndividualAccessibilityTargets)
                    }
                }
            }
        }
    }

    func testViewportHitTestRejectsOutsideLogicalBoard() {
        let layout = BoardViewportLayout(
            boardSize: 101, center: BoardPosition(row: 50, column: 50), lineCount: 101,
            step: 20, viewport: CGSize(width: 200, height: 200), offset: .zero
        )
        XCTAssertNil(layout.position(at: layout.point(for: BoardPosition(row: -1, column: 50))))
        XCTAssertNil(layout.position(at: layout.point(for: BoardPosition(row: 50, column: 101))))
    }

    private func waitForRequests(_ count: Int, worker: ControlledComputer) async {
        for _ in 0..<100 {
            if await worker.counts.count >= count { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Computer request did not start")
    }

    private func waitForStones(_ count: Int, game: GameViewModel) async {
        for _ in 0..<100 {
            if game.board.stones.count == count { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Computer result did not commit")
    }

}


private actor ControlledComputer {
    private(set) var counts: [Int] = []
    private var pending: [Int: CheckedContinuation<BoardPosition?, Never>] = [:]

    func move(on board: GomokuBoard) async -> BoardPosition? {
        let request = counts.count
        counts.append(board.stones.count)
        return await withCheckedContinuation { pending[request] = $0 }
    }

    func complete(_ request: Int, at position: BoardPosition) {
        pending.removeValue(forKey: request)?.resume(returning: position)
    }
}
