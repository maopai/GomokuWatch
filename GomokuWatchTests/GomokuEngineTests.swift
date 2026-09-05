import XCTest
@testable import GomokuWatch

final class GomokuEngineTests: XCTestCase {
    func testWinsInEveryDirectionAndWithOverline() {
        let directions = [(0, 1), (1, 0), (1, 1), (1, -1)]

        for (rowStep, columnStep) in directions {
            var board = GomokuBoard(size: 15)
            let origin = BoardPosition(row: 7, column: columnStep < 0 ? 9 : 5)
            var last = origin
            for index in 0..<6 {
                last = BoardPosition(
                    row: origin.row + rowStep * index,
                    column: origin.column + columnStep * index
                )
                XCTAssertTrue(board.place(.black, at: last))
            }
            XCTAssertTrue(board.isWinningMove(at: last))
            let winningLine = board.winningLine(containing: last)
            XCTAssertEqual(winningLine.count, 6)
            XCTAssertTrue(winningLine.contains(last))
        }
    }

    func testDefaultBoardUsesStableLargeCoordinatesAndCanRenderASmallWindow() {
        var board = GomokuBoard()
        let opening = BoardPosition(row: 50, column: 50)
        XCTAssertEqual(board.size, 101)
        XCTAssertTrue(board.place(.black, at: opening))

        let window = board.positions(rows: 48..<53, columns: 48..<53)

        XCTAssertEqual(window.count, 25)
        XCTAssertEqual(board.stone(at: opening), .black)
    }

    func testNearbyCandidateCacheRestoresAfterSearchStyleUndo() {
        var board = GomokuBoard()
        XCTAssertTrue(board.place(.black, at: BoardPosition(row: 50, column: 50)))
        XCTAssertTrue(board.place(.white, at: BoardPosition(row: 52, column: 52)))
        let beforeProbe = board.nearbyEmptyPositions()

        let probe = BoardPosition(row: 51, column: 51)
        XCTAssertTrue(board.place(.black, at: probe))
        XCTAssertEqual(board.removeStone(at: probe), .black)

        XCTAssertEqual(board.nearbyEmptyPositions(), beforeProbe)
    }

    func testEveryDifficultyTakesImmediateWinAndBlocksImmediateLoss() {
        for difficulty in AIDifficulty.allCases {
            var winningBoard = GomokuBoard()
            for column in 48...51 {
                XCTAssertTrue(winningBoard.place(.white, at: BoardPosition(row: 50, column: column)))
            }
            let winningMove = winningBoard.bestMove(for: .white, difficulty: difficulty)
            XCTAssertNotNil(winningMove)
            var won = winningBoard
            XCTAssertTrue(won.place(.white, at: winningMove!))
            XCTAssertTrue(won.isWinningMove(at: winningMove!))

            var blockingBoard = GomokuBoard()
            for column in 48...51 {
                XCTAssertTrue(blockingBoard.place(.black, at: BoardPosition(row: 50, column: column)))
            }
            let block = blockingBoard.bestMove(for: .white, difficulty: difficulty)
            XCTAssertTrue(
                block == BoardPosition(row: 50, column: 47)
                    || block == BoardPosition(row: 50, column: 52)
            )
        }
    }

    func testEveryDifficultyAlwaysBlocksAContinuousLiveThree() {
        let directions = [(0, 1), (1, 0), (1, 1), (1, -1)]

        for (rowStep, columnStep) in directions {
            var board = GomokuBoard()
            let origin = BoardPosition(row: 50, column: 50)
            for index in 0..<3 {
                XCTAssertTrue(board.place(.black, at: BoardPosition(
                    row: origin.row + rowStep * index,
                    column: origin.column + columnStep * index
                )))
            }
            let expectedBlocks: Set<BoardPosition> = [
                BoardPosition(row: origin.row - rowStep, column: origin.column - columnStep),
                BoardPosition(row: origin.row + rowStep * 3, column: origin.column + columnStep * 3)
            ]

            for difficulty in AIDifficulty.allCases {
                // Easy used to choose randomly from eight moves, so repeat the
                // same position to prove no random branch can skip the block.
                for _ in 0..<30 {
                    let move = board.bestMove(for: .white, difficulty: difficulty)
                    XCTAssertNotNil(move)
                    XCTAssertTrue(expectedBlocks.contains(move!))
                }
            }
        }
    }

    func testEveryDifficultyCreatesAndBlocksDoubleLiveThreeFork() {
        let center = BoardPosition(row: 50, column: 50)

        for difficulty in AIDifficulty.allCases {
            var attackingBoard = GomokuBoard()
            XCTAssertTrue(attackingBoard.place(.white, at: BoardPosition(row: 50, column: 48)))
            XCTAssertTrue(attackingBoard.place(.white, at: BoardPosition(row: 50, column: 49)))
            XCTAssertTrue(attackingBoard.place(.white, at: BoardPosition(row: 48, column: 50)))
            XCTAssertTrue(attackingBoard.place(.white, at: BoardPosition(row: 49, column: 50)))
            XCTAssertEqual(attackingBoard.bestMove(for: .white, difficulty: difficulty), center)

            var defendingBoard = GomokuBoard()
            XCTAssertTrue(defendingBoard.place(.black, at: BoardPosition(row: 50, column: 48)))
            XCTAssertTrue(defendingBoard.place(.black, at: BoardPosition(row: 50, column: 49)))
            XCTAssertTrue(defendingBoard.place(.black, at: BoardPosition(row: 48, column: 50)))
            XCTAssertTrue(defendingBoard.place(.black, at: BoardPosition(row: 49, column: 50)))
            XCTAssertEqual(defendingBoard.bestMove(for: .white, difficulty: difficulty), center)
        }
    }

    func testEveryDifficultyPrefersStrongerForkOverDisposableRushFour() {
        let fork = BoardPosition(row: 60, column: 60)

        for difficulty in AIDifficulty.allCases {
            var board = GomokuBoard()

            // White can extend this blocked live three at (50, 52), but Black
            // can answer at (50, 53) and leave the entire line closed.
            for column in 49...51 {
                XCTAssertTrue(board.place(.white, at: BoardPosition(row: 50, column: column)))
            }
            XCTAssertTrue(board.place(.black, at: BoardPosition(row: 50, column: 48)))

            // The center move creates two live threes and therefore has a real
            // continuation after the opponent's next reply.
            XCTAssertTrue(board.place(.white, at: BoardPosition(row: 60, column: 58)))
            XCTAssertTrue(board.place(.white, at: BoardPosition(row: 60, column: 59)))
            XCTAssertTrue(board.place(.white, at: BoardPosition(row: 58, column: 60)))
            XCTAssertTrue(board.place(.white, at: BoardPosition(row: 59, column: 60)))

            XCTAssertEqual(board.bestMove(for: .white, difficulty: difficulty), fork)
        }
    }

    func testMediumOpeningDoesNotAlwaysChooseTheSameUpwardTieBreak() {
        let blackOpening = BoardPosition(row: 50, column: 50)
        let oldFixedResponse = BoardPosition(row: 48, column: 50)
        var responses = Set<BoardPosition>()

        for _ in 0..<8 {
            var board = GomokuBoard()
            XCTAssertTrue(board.place(.black, at: blackOpening))
            guard let response = board.bestMove(for: .white, difficulty: .medium) else {
                return XCTFail("AI should produce an opening response")
            }
            XCTAssertTrue(board.contains(response))
            XCTAssertNil(board.stone(at: response))
            responses.insert(response)
        }

        XCTAssertNotEqual(responses, Set([oldFixedResponse]))
        XCTAssertGreaterThan(responses.count, 1)
    }

    func testWinningFourOutranksDefendingRushFourInEveryOrientationAndColor() {
        for difficulty in AIDifficulty.allCases {
            for attacker in Stone.allCases {
                for reflected in [false, true] {
                    for rotation in 0..<4 {
                        func position(_ row: Int, _ column: Int) -> BoardPosition {
                            var r = row - 50
                            var c = (column - 50) * (reflected ? -1 : 1)
                            for _ in 0..<rotation { (r, c) = (c, -r) }
                            return BoardPosition(row: r + 50, column: c + 50)
                        }
                        var board = GomokuBoard()
                        for c in 30...32 { _ = board.place(attacker.opposite, at: position(30, c)) }
                        _ = board.place(attacker, at: position(30, 29))
                        for c in 49...51 { _ = board.place(attacker, at: position(50, c)) }
                        _ = board.place(attacker.opposite, at: position(10, 10))
                        _ = board.place(attacker.opposite, at: position(15, 15))
                        let move = board.bestMove(for: attacker, difficulty: difficulty)
                        XCTAssertTrue([position(50, 48), position(50, 52)].contains(move!))
                        _ = board.place(attacker, at: move!)
                        let wins = board.nearbyEmptyPositions().filter { p in
                            var next = board
                            _ = next.place(attacker, at: p)
                            return next.isWinningMove(at: p)
                        }
                        XCTAssertGreaterThanOrEqual(wins.count, 2)
                    }
                }
            }
        }
    }

    func testInterruptedSearchReturnsNoScoreAndDoesNotCacheIncompleteRoot() {
        for limit in [1, 3] {
            var board = GomokuBoard()
            _ = board.place(.black, at: BoardPosition(row: 50, column: 50))
            let stones = board.stones
            let candidates = board.nearbyEmptyPositions()
            var budget = SearchBudget(limit: limit, timeLimit: 60)
            var table: [TranspositionKey: TranspositionEntry] = [:]
            let score = board.alphaBeta(
                toMove: .white, perspective: .white, remainingDepth: 2,
                forcingDepth: 0, alpha: Int.min / 4, beta: Int.max / 4,
                candidateLimit: 4, budget: &budget, transpositionTable: &table
            )
            XCTAssertNil(score)
            XCTAssertFalse(table.values.contains { $0.remainingDepth == 2 })
            XCTAssertEqual(board.stones, stones)
            XCTAssertEqual(board.nearbyEmptyPositions(), candidates)
        }
    }

    func testCancelledSearchDoesNotReturnAMove() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return GomokuBoard().bestMove(for: .black, difficulty: .hard)
        }
        let move = await task.value
        XCTAssertNil(move)
    }

    func testIncrementalEvaluationMatchesFreshBoardThroughMovesAndUndo() {
        var board = GomokuBoard(size: 15)
        board.prepareEvaluation()
        var history: [BoardPosition] = []
        func verify(_ board: GomokuBoard, file: StaticString = #filePath, line: UInt = #line) {
            var rebuilt = GomokuBoard(size: board.size)
            for (position, stone) in board.stones { _ = rebuilt.place(stone, at: position) }
            for stone in Stone.allCases {
                XCTAssertEqual(board.boardScore(for: stone), rebuilt.boardScore(for: stone), file: file, line: line)
            }
            XCTAssertEqual(board.nearbyEmptyPositions(), rebuilt.nearbyEmptyPositions(), file: file, line: line)
        }
        for i in 0..<60 {
            let position = BoardPosition(row: (i * 7) % 15, column: (i * 11 + i / 15) % 15)
            guard board.place(i % 2 == 0 ? .black : .white, at: position) else { continue }
            history.append(position)
            verify(board)
        }
        for position in history.reversed() {
            _ = board.removeStone(at: position)
            verify(board)
        }
        XCTAssertEqual(board.boardScore(for: .black), 0)
    }

    func testBudgetDeadlineAppliesBetweenNodeCheckpoints() {
        var expired = SearchBudget(limit: 100, timeLimit: 0)
        expired.visit()
        XCTAssertTrue(expired.isExhausted)
        XCTAssertEqual(expired.remainingTime, 0)
    }

    func testVCFFindsMultiStepWinAndRestoresBoardInEveryOrientation() {
        for attacker in Stone.allCases {
            for reflected in [false, true] {
                for rotation in 0..<4 {
                    func point(_ row: Int, _ column: Int) -> BoardPosition {
                        var r = row - 7
                        var c = (column - 7) * (reflected ? -1 : 1)
                        for _ in 0..<rotation { (r, c) = (c, -r) }
                        return BoardPosition(row: r + 7, column: c + 7)
                    }
                    var board = GomokuBoard(size: 15)
                    for p in [(7,4),(7,5),(7,6),(5,7),(6,7)] { _ = board.place(attacker, at: point(p.0,p.1)) }
                    _ = board.place(attacker.opposite, at: point(7,3))
                    board.prepareEvaluation()
                    let before = board.stones
                    let beforeScore = board.boardScore(for: attacker)
                    let beforeCandidates = board.nearbyEmptyPositions()
                    for limit in [1, 2] {
                        var interrupted = SearchBudget(limit: limit, timeLimit: 5)
                        XCTAssertNil(board.continuousFourWin(for: attacker, remainingPlies: 5, budget: &interrupted))
                        XCTAssertEqual(board.stones, before)
                        XCTAssertEqual(board.boardScore(for: attacker), beforeScore)
                    }
                    var budget = SearchBudget(limit: 10_000, timeLimit: 5)
                    let move = board.continuousFourWin(for: attacker, remainingPlies: 5, budget: &budget)
                    XCTAssertEqual(move, point(7,7))
                    XCTAssertEqual(board.stones, before)
                    XCTAssertEqual(board.boardScore(for: attacker), beforeScore)
                    XCTAssertEqual(board.nearbyEmptyPositions(), beforeCandidates)

                    // Independently check the forcing line, including its unique reply.
                    _ = board.place(attacker, at: point(7,7))
                    let wins = board.nearbyEmptyPositions().filter { p in
                        var next = board
                        _ = next.place(attacker, at: p)
                        return next.isWinningMove(at: p)
                    }
                    XCTAssertEqual(wins, [point(7,8)])
                    _ = board.place(attacker.opposite, at: point(7,8))
                    _ = board.place(attacker, at: point(4,7))
                    let finalWins = board.nearbyEmptyPositions().filter { p in
                        var next = board
                        _ = next.place(attacker, at: p)
                        return next.isWinningMove(at: p)
                    }
                    XCTAssertEqual(Set(finalWins), Set([point(3,7),point(8,7)]))
                }
            }
        }
    }

    func testVCFDoesNotIgnoreOpponentsImmediateWinOrClaimTimeoutProof() {
        var board = GomokuBoard(size: 15)
        for p in [(7,4),(7,5),(7,6),(5,7),(6,7)] { _ = board.place(.white, at: BoardPosition(row:p.0,column:p.1)) }
        _ = board.place(.black, at: BoardPosition(row:7,column:3))
        for c in 2...5 { _ = board.place(.black, at: BoardPosition(row:2,column:c)) }
        board.prepareEvaluation()
        let before = board.stones
        let beforeScore = board.boardScore(for: .white)
        var budget = SearchBudget(limit: 1000, timeLimit: 1)
        XCTAssertNil(board.continuousFourWin(for: .white, remainingPlies: 9, budget: &budget))
        var expired = SearchBudget(limit: 1000, timeLimit: 0)
        XCTAssertNil(board.continuousFourWin(for: .white, remainingPlies: 9, budget: &expired))
        XCTAssertEqual(board.stones, before)
        XCTAssertEqual(board.boardScore(for: .white), beforeScore)
    }

    func testNarrowedRootWindowPreservesExactTies() {
        var board = GomokuBoard(size: 15)
        for (i, p) in [(7,7),(7,8),(8,7),(6,7),(6,8)].enumerated() {
            _ = board.place(i % 2 == 0 ? .black : .white, at: BoardPosition(row:p.0,column:p.1))
        }
        func evaluate(alpha: Int) -> Int? {
            var copy = board
            var budget = SearchBudget(limit: 100_000, timeLimit: 10)
            var table: [TranspositionKey: TranspositionEntry] = [:]
            return copy.alphaBeta(toMove: .white, perspective: .white, remainingDepth: 2, forcingDepth: 1,
                alpha: alpha, beta: Int.max / 4, candidateLimit: 5, budget: &budget, transpositionTable: &table)
        }
        guard let exact = evaluate(alpha: Int.min / 4) else { return XCTFail("Full search interrupted") }
        XCTAssertEqual(evaluate(alpha: exact - 1), exact)
    }

}
