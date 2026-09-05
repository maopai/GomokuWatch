import XCTest

final class GomokuWatchUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testAIFlowAcceptsAConfirmedMove() {
        let aiMode = app.buttons["mode.ai"]
        XCTAssertTrue(aiMode.waitForExistence(timeout: 5))
        aiMode.tap()

        let easy = app.buttons["difficulty.easy"]
        XCTAssertTrue(easy.waitForExistence(timeout: 3))
        easy.tap()
        let black = app.buttons["color.black"]
        XCTAssertTrue(black.waitForExistence(timeout: 3))
        XCTAssertEqual(black.label, "玩家执黑，简单 · 你先手")
        black.tap()

        let center = app.descendants(matching: .any)["board.50.50"]
        XCTAssertTrue(center.waitForExistence(timeout: 3))
        center.tap()
        center.tap()

        let blackStone = NSPredicate(format: "value == %@", "黑棋")
        expectation(for: blackStone, evaluatedWith: center)
        waitForExpectations(timeout: 3)
        XCTAssertEqual(center.value as? String, "黑棋")
        XCTAssertTrue(app.staticTexts["match.turn"].exists)
        keepScreenshot(named: "AI 对局落子后")
    }

    func testReturningFromHomeRequiresResumeDecision() {
        app.buttons["mode.player"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["match.board"].waitForExistence(timeout: 3))

        XCUIDevice.shared.press(.home)
        app.activate()

        XCTAssertTrue(app.buttons["pause.resume"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["pause.abandon"].exists)
        assertFullyVisible(app.buttons["pause.resume"])
        assertFullyVisible(app.buttons["pause.abandon"])
        keepScreenshot(named: "返回后的暂停选择")
        app.buttons["pause.resume"].tap()
        XCTAssertFalse(app.buttons["pause.abandon"].exists)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["pause.abandon"].waitForExistence(timeout: 3))
        app.buttons["pause.abandon"].tap()
        XCTAssertTrue(app.buttons["mode.player"].waitForExistence(timeout: 3))
    }

    func testMatchHeaderUsesSingleReadableRow() {
        let playerMode = app.buttons["mode.player"]
        XCTAssertTrue(playerMode.waitForExistence(timeout: 5))
        playerMode.tap()

        let turnStatus = app.descendants(matching: .any)["match.turn"]
        XCTAssertTrue(turnStatus.waitForExistence(timeout: 3))
        XCTAssertEqual(turnStatus.label, "双人对战，玩家1，黑棋回合")
        XCTAssertTrue(app.buttons["match.undo"].exists)
        XCTAssertFalse(app.buttons["match.recenter"].exists)
        keepScreenshot(named: "单行清晰对局栏")
    }

    func testDigitalCrownZoomsTheBoard() {
        app.buttons["mode.player"].tap()
        let center = app.descendants(matching: .any)["board.50.50"]
        XCTAssertTrue(center.waitForExistence(timeout: 3))
        let board = app.descendants(matching: .any)["match.board"]
        XCTAssertTrue(board.exists)
        let originalScale = board.value as? String

        XCUIDevice.shared.rotateDigitalCrown(delta: 3.0)

        let enlarged = NSPredicate(format: "value != %@", originalScale ?? "")
        expectation(for: enlarged, evaluatedWith: board)
        waitForExpectations(timeout: 3)
        XCTAssertNotEqual(board.value as? String, originalScale)
        keepScreenshot(named: "表冠缩放后")
    }

    func testExpandedBoardStillZoomsToTwiceInitialCellSize() {
        app.buttons["mode.player"].tap()
        let nearEdge = app.descendants(matching: .any)["board.50.53"]
        XCTAssertTrue(nearEdge.waitForExistence(timeout: 3))
        nearEdge.tap()
        nearEdge.tap()

        let board = app.descendants(matching: .any)["match.board"]
        XCTAssertTrue(board.waitForExistence(timeout: 3))
        XCTAssertTrue(board.label.contains("当前显示 21 行 21 列"))

        // Expanded boards now have additional half-step zoom levels.
        for _ in 0..<6 {
            XCUIDevice.shared.rotateDigitalCrown(delta: 3.0)
            if board.value as? String == "格子大小为初始的 2 倍" { break }
        }

        let maximumCellSize = NSPredicate(format: "value == %@", "格子大小为初始的 2 倍")
        expectation(for: maximumCellSize, evaluatedWith: board)
        waitForExpectations(timeout: 3)
        keepScreenshot(named: "21 乘 21 扩充后放大到初始两倍")
    }

    func testNearEdgeMoveRendersMoreIntersections() {
        app.buttons["mode.player"].tap()
        let nearEdge = app.descendants(matching: .any)["board.50.53"]
        let newlyVisibleEdge = app.descendants(matching: .any)["board.50.60"]

        XCTAssertTrue(nearEdge.waitForExistence(timeout: 3))
        XCTAssertFalse(newlyVisibleEdge.exists)
        nearEdge.tap()
        XCTAssertFalse(newlyVisibleEdge.exists)
        nearEdge.tap()

        XCTAssertTrue(newlyVisibleEdge.waitForExistence(timeout: 3))
        XCTAssertEqual(nearEdge.value as? String, "黑棋，最后落子")
        keepScreenshot(named: "自动扩展为 21 乘 21")
    }

    func testWinningLineCanBeUndoneAndMatchContinues() {
        let playerMode = app.buttons["mode.player"]
        XCTAssertTrue(playerMode.waitForExistence(timeout: 5))
        playerMode.tap()
        let blackMoves = (48...52).map { app.descendants(matching: .any)["board.50.\($0)"] }
        let whiteMoves = (48...51).map { app.descendants(matching: .any)["board.51.\($0)"] }

        if !blackMoves[0].waitForExistence(timeout: 2), playerMode.exists {
            playerMode.tap()
        }

        for index in blackMoves.indices {
            XCTAssertTrue(blackMoves[index].waitForExistence(timeout: 3))
            blackMoves[index].tap()
            blackMoves[index].tap()
            if index < whiteMoves.count {
                whiteMoves[index].tap()
                whiteMoves[index].tap()
            }
        }

        XCTAssertTrue(app.descendants(matching: .any)["match.winningLine"].waitForExistence(timeout: 3))
        XCTAssertEqual(blackMoves.last?.value as? String, "黑棋，最后落子")
        XCTAssertTrue(app.descendants(matching: .any)["match.board"].exists)
        XCTAssertTrue(app.staticTexts["match.turn"].label.contains("玩家1 获胜"))
        keepScreenshot(named: "五连红线与最后落子红点")

        let undo = app.buttons["match.undo"]
        XCTAssertTrue(undo.isEnabled)
        undo.tap()

        XCTAssertFalse(app.descendants(matching: .any)["match.winningLine"].exists)
        XCTAssertEqual(blackMoves.last?.value as? String, "空位")
        XCTAssertTrue(app.staticTexts["match.turn"].label.contains("玩家1"))
        XCTAssertFalse(app.staticTexts["match.turn"].label.contains("获胜"))
        keepScreenshot(named: "胜利后悔棋并继续对局")

        app.buttons["match.back"].tap()
        app.buttons["放弃并返回首页"].tap()
        XCTAssertTrue(app.buttons["mode.player"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["match.board"].exists)
    }

    func testDifficultyAndColorSelectionFitDisplay() {
        let aiMode = app.buttons["mode.ai"]
        XCTAssertTrue(aiMode.waitForExistence(timeout: 5))
        aiMode.tap()
        for identifier in ["difficulty.easy", "difficulty.medium", "difficulty.hard"] {
            let button = app.buttons[identifier]
            XCTAssertTrue(button.waitForExistence(timeout: 3))
            assertFullyVisible(button)
        }
        keepScreenshot(named: "三种难度同屏")
        app.buttons["difficulty.hard"].tap()
        let black = app.buttons["color.black"]
        let white = app.buttons["color.white"]
        XCTAssertTrue(black.waitForExistence(timeout: 3))
        XCTAssertEqual(black.label, "玩家执黑，困难 · 你先手")
        XCTAssertEqual(white.label, "玩家执白，困难 · AI 先手")
        assertFullyVisible(black)
        assertFullyVisible(white)
        keepScreenshot(named: "执棋页难度文案")
    }

    func testZoomedDragDoesNotPlaceStoneAndConfirmedTapKeepsCoordinates() {
        app.buttons["mode.player"].tap()
        let board = app.descendants(matching: .any)["match.board"]
        XCTAssertTrue(board.waitForExistence(timeout: 3))
        // The 101-line board has 39 half-step levels; traverse the full range.
        for _ in 0..<40 {
            XCUIDevice.shared.rotateDigitalCrown(delta: 3.0, velocity: XCUIGestureVelocity(rawValue: 5.0))
            if board.value as? String == "格子大小为初始的 2 倍" { break }
        }
        let enlarged = NSPredicate(format: "value == %@", "格子大小为初始的 2 倍")
        expectation(for: enlarged, evaluatedWith: board)
        waitForExpectations(timeout: 3)
        board.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: board.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)))
        let center = app.descendants(matching: .any)["board.50.50"]
        XCTAssertEqual(center.value as? String, "空位")
        center.tap()
        XCTAssertEqual(center.value as? String, "已选择 黑棋，再次操作确认落子")
        center.tap()
        XCTAssertEqual(center.value as? String, "黑棋，最后落子")
        keepScreenshot(named: "视口拖动后坐标与落子一致")
    }

    func testFullBoardOverviewUsesBoundedTargetsAndZoomedTapWorks() {
        app.buttons["mode.player"].tap()
        let edge = app.descendants(matching: .any)["board.50.53"]
        XCTAssertTrue(edge.waitForExistence(timeout: 3))
        edge.tap(); edge.tap()
        let board = app.descendants(matching: .any)["match.board"]
        for lines in stride(from: 31, through: 101, by: 10) {
            let point = board.coordinate(withNormalizedOffset: CGVector(dx: 0.985, dy: lines % 20 == 11 ? 0.45 : 0.55))
            point.tap(); point.tap()
            let expanded = NSPredicate(format: "label CONTAINS %@", "当前显示 \(lines) 行")
            expectation(for: expanded, evaluatedWith: board)
            waitForExpectations(timeout: 3)
        }
        let targets = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "board."))
        XCTAssertLessThan(targets.count, 900)
        keepScreenshot(named: "101 乘 101 全局视野")
        // The 101-line board has 39 half-step levels; traverse the full range.
        for _ in 0..<40 {
            XCUIDevice.shared.rotateDigitalCrown(delta: 3.0, velocity: XCUIGestureVelocity(rawValue: 5.0))
            if board.value as? String == "格子大小为初始的 2 倍" { break }
        }
        let enlarged = NSPredicate(format: "value == %@", "格子大小为初始的 2 倍")
        expectation(for: enlarged, evaluatedWith: board)
        waitForExpectations(timeout: 3)
        XCTAssertLessThan(targets.count, 150)
        let center = app.descendants(matching: .any)["board.50.50"]
        center.tap(); center.tap()
        XCTAssertTrue((center.value as? String)?.contains("最后落子") == true)
        keepScreenshot(named: "101 乘 101 放大后落子")
    }

    private func assertFullyVisible(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.isHittable, file: file, line: line)
        XCTAssertTrue(app.frame.insetBy(dx: 2, dy: 2).contains(element.frame),
                      "Control extends beyond display: \(element.frame)", file: file, line: line)
    }

    private func keepScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
