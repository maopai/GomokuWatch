import Foundation
import SwiftUI

struct BoardZoomMetrics {
    static let initialVisibleLineCount = 11
    static let maximumCellScale = 2.0

    static func surfaceScales(for visibleLineCount: Int) -> [Double] {
        let visibleIntervals = Double(max(visibleLineCount - 1, 1))
        let initialIntervals = Double(initialVisibleLineCount - 1)
        let maximumSurfaceScale = maximumCellScale * visibleIntervals / initialIntervals

        let stepCount = Int(((maximumSurfaceScale - 1.0) / 0.5).rounded())
        return (0...max(0, stepCount)).map { 1.0 + Double($0) * 0.5 }
    }

    static func cellScale(surfaceScale: Double, visibleLineCount: Int) -> Double {
        let visibleIntervals = Double(max(visibleLineCount - 1, 1))
        let initialIntervals = Double(initialVisibleLineCount - 1)
        return surfaceScale * initialIntervals / visibleIntervals
    }
}

// Shared geometry for drawing, hit testing and bounded accessibility targets.
struct BoardViewportLayout {
    let boardSize: Int
    let center: BoardPosition
    let lineCount: Int
    let step: CGFloat
    let viewport: CGSize
    let offset: CGSize

    var rows: Range<Int> { centeredRange(center.row) }
    var columns: Range<Int> { centeredRange(center.column) }
    var origin: CGPoint {
        CGPoint(
            x: viewport.width / 2 + offset.width - CGFloat(columns.lowerBound + lineCount / 2) * step,
            y: viewport.height / 2 + offset.height - CGFloat(rows.lowerBound + lineCount / 2) * step
        )
    }
    var visibleRows: Range<Int> { visibleRange(rows, origin: origin.y, length: viewport.height) }
    var visibleColumns: Range<Int> { visibleRange(columns, origin: origin.x, length: viewport.width) }
    var visibleIntersectionCount: Int { visibleRows.count * visibleColumns.count }
    var usesIndividualAccessibilityTargets: Bool { visibleIntersectionCount <= 900 }

    func point(for position: BoardPosition) -> CGPoint {
        CGPoint(x: origin.x + CGFloat(position.column) * step,
                y: origin.y + CGFloat(position.row) * step)
    }

    func position(at point: CGPoint) -> BoardPosition? {
        let position = BoardPosition(row: Int(((point.y - origin.y) / step).rounded()),
                                     column: Int(((point.x - origin.x) / step).rounded()))
        return rows.contains(position.row) && columns.contains(position.column) ? position : nil
    }

    func isVisible(_ position: BoardPosition) -> Bool {
        visibleRows.contains(position.row) && visibleColumns.contains(position.column)
    }

    private func centeredRange(_ coordinate: Int) -> Range<Int> {
        let start = min(max(0, coordinate - lineCount / 2), boardSize - lineCount)
        return start..<(start + lineCount)
    }

    private func visibleRange(_ range: Range<Int>, origin: CGFloat, length: CGFloat) -> Range<Int> {
        // Include a cell of overscan for partially visible stones and dragging.
        let lower = min(range.upperBound, max(range.lowerBound, Int(floor(-origin / step)) - 1))
        let upper = max(lower, min(range.upperBound, Int(ceil((length - origin) / step)) + 2))
        return lower..<upper
    }
}

enum GameScreen: Equatable {
    case modeSelection
    case difficultySelection
    case colorSelection
    case game
}

@MainActor
final class GameViewModel: ObservableObject {
    private struct MoveRecord {
        let position: BoardPosition
        let stone: Stone
        let owner: Int
    }

    @Published private(set) var board = GomokuBoard()
    @Published private(set) var turn: Stone = .black
    @Published private(set) var blackOwner = 0
    @Published private(set) var selectedPosition: BoardPosition?
    @Published private(set) var lastMovePosition: BoardPosition?
    @Published private(set) var winningLine: [BoardPosition] = []
    @Published private(set) var winner: Int?
    @Published private(set) var isDraw = false
    @Published private(set) var mode: GameMode = .versusPlayer
    @Published private(set) var difficulty: AIDifficulty = .medium
    @Published private(set) var pendingDifficulty: AIDifficulty = .medium
    @Published private(set) var screen: GameScreen = .modeSelection
    @Published private(set) var isPaused = false
    @Published private(set) var viewportCenter = BoardPosition(
        row: GomokuBoard.defaultSize / 2,
        column: GomokuBoard.defaultSize / 2
    )
    @Published private(set) var visibleLineCount = BoardZoomMetrics.initialVisibleLineCount
    @Published private(set) var viewportResetID = UUID()
    @Published var showResult = false
    @Published var showCrownHint = false

    @AppStorage("gomoku.playerWins") var playerWins = 0
    private var matchID = UUID()
    private var moveHistory: [MoveRecord] = []
    private var computerTask: Task<Void, Never>?
    private var computerRequestID = UUID()
    private let computerMoveDelay: Duration
    private let computerMove: @Sendable (GomokuBoard, Stone, AIDifficulty) async -> BoardPosition?

    init(
        computerMoveDelay: Duration = .milliseconds(450),
        computerMove: @escaping @Sendable (GomokuBoard, Stone, AIDifficulty) async -> BoardPosition? = { board, stone, difficulty in
            let worker = Task.detached(priority: .userInitiated) {
                board.bestMove(for: stone, difficulty: difficulty)
            }
            return await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
        }
    ) {
        self.computerMoveDelay = computerMoveDelay
        self.computerMove = computerMove
    }

    deinit { computerTask?.cancel() }

    var currentOwner: Int { owner(for: turn) }
    var isComputerTurn: Bool {
        mode == .versusAI
            && currentOwner == 1
            && winner == nil
            && !isDraw
            && !isPaused
            && screen == .game
    }
    var isFinished: Bool { winner != nil || isDraw }
    var canUndo: Bool {
        switch mode {
        case .versusPlayer:
            return !moveHistory.isEmpty
        case .versusAI:
            return moveHistory.contains { $0.owner == 0 }
        }
    }
    var playerName: String {
        mode == .versusAI ? (currentOwner == 0 ? "玩家" : "AI") : "玩家\(currentOwner + 1)"
    }
    var blackOwnerName: String { ownerName(blackOwner) }
    var whiteOwnerName: String { ownerName(1 - blackOwner) }
    var resultText: String {
        if isDraw { return "平局" }
        guard let winner else { return "" }
        return "\(ownerName(winner)) 获胜"
    }

    func tap(_ position: BoardPosition) {
        guard !isPaused,
              !isFinished,
              !isComputerTurn,
              board.stone(at: position) == nil else { return }
        // First tap previews the intended move; tapping the same intersection
        // again confirms it. Tapping elsewhere simply moves the preview.
        if selectedPosition == position {
            commitHumanMove(at: position)
        } else {
            selectedPosition = position
        }
    }

    func choosePlayerMatch() {
        mode = .versusPlayer
        startNewMatch(firstBlackOwner: 0)
    }

    func showDifficultySelection() {
        screen = .difficultySelection
    }

    func chooseAIDifficulty(_ difficulty: AIDifficulty) {
        pendingDifficulty = difficulty
        screen = .colorSelection
    }

    // Retained for callers that want the traditional player-first opening.
    func chooseAIMatch(difficulty: AIDifficulty) {
        chooseAIMatch(difficulty: difficulty, playerColor: .black)
    }

    func chooseAIMatch(difficulty: AIDifficulty, playerColor: Stone) {
        mode = .versusAI
        self.difficulty = difficulty
        startNewMatch(firstBlackOwner: playerColor == .black ? 0 : 1)
    }

    func returnToModeSelection() {
        invalidateComputerMove()
        matchID = UUID()
        board = GomokuBoard()
        moveHistory.removeAll()
        turn = .black
        isPaused = false
        winner = nil
        isDraw = false
        showResult = false
        showCrownHint = false
        selectedPosition = nil
        lastMovePosition = nil
        winningLine = []
        visibleLineCount = BoardZoomMetrics.initialVisibleLineCount
        viewportCenter = BoardPosition(row: board.size / 2, column: board.size / 2)
        viewportResetID = UUID()
        screen = .modeSelection
    }

    func pauseForInactivity() {
        guard screen == .game, !isFinished else { return }
        invalidateComputerMove()
        isPaused = true
    }

    func resumeAfterInactivity() {
        guard screen == .game, isPaused else { return }
        isPaused = false
        scheduleComputerMoveIfNeeded()
    }

    func dismissCrownHint() {
        showCrownHint = false
    }

    private func startNewMatch(firstBlackOwner: Int) {
        invalidateComputerMove()
        matchID = UUID()
        board = GomokuBoard()
        moveHistory.removeAll()
        turn = .black
        selectedPosition = nil
        lastMovePosition = nil
        winningLine = []
        winner = nil
        isDraw = false
        isPaused = false
        showResult = false
        showCrownHint = true
        visibleLineCount = BoardZoomMetrics.initialVisibleLineCount
        viewportCenter = BoardPosition(row: board.size / 2, column: board.size / 2)
        viewportResetID = UUID()
        blackOwner = firstBlackOwner
        screen = .game
        let hintMatchID = matchID
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.matchID == hintMatchID else { return }
            self.showCrownHint = false
        }
        scheduleComputerMoveIfNeeded()
    }

    private func commitHumanMove(at position: BoardPosition) {
        guard board.place(turn, at: position) else { return }
        invalidateComputerMove()
        moveHistory.append(MoveRecord(position: position, stone: turn, owner: owner(for: turn)))
        lastMovePosition = position
        selectedPosition = nil
        resolveMove(at: position)
    }

    private func commitComputerMove(at position: BoardPosition) {
        guard isComputerTurn, board.place(turn, at: position) else { return }
        invalidateComputerMove()
        moveHistory.append(MoveRecord(position: position, stone: turn, owner: owner(for: turn)))
        lastMovePosition = position
        resolveMove(at: position)
    }

    func undoLastTurn() {
        guard screen == .game, !isPaused, canUndo else { return }

        // Invalidate any delayed AI task before changing the board. A newly
        // scheduled task always captures the replacement match identifier.
        invalidateComputerMove()
        matchID = UUID()

        selectedPosition = nil

        if isFinished {
            if mode == .versusAI, winner == 0 {
                playerWins = max(0, playerWins - 1)
            }
            winner = nil
            isDraw = false
            showResult = false
            winningLine = []
        }

        if mode == .versusAI {
            // Remove the AI response first, then the player's preceding move.
            // This returns control to the player instead of letting the AI
            // immediately replay the move that was just undone.
            while moveHistory.last?.owner == 1 {
                removeLastRecordedMove()
            }
            if moveHistory.last?.owner == 0 {
                removeLastRecordedMove()
            }
        } else {
            removeLastRecordedMove()
        }

        turn = moveHistory.last?.stone.opposite ?? .black
        lastMovePosition = moveHistory.last?.position
        scheduleComputerMoveIfNeeded()
    }

    private func removeLastRecordedMove() {
        guard let move = moveHistory.popLast() else { return }
        _ = board.removeStone(at: move.position)
    }

    private func resolveMove(at position: BoardPosition) {
        expandVisibleBoardIfNeeded(around: position)
        let completedLine = board.winningLine(containing: position)
        if !completedLine.isEmpty {
            winningLine = completedLine
            finish(winner: owner(for: turn))
            return
        }
        if board.stones.count == board.size * board.size {
            isDraw = true
            showResult = true
            return
        }
        turn = turn.opposite
        continueAfterMove()
    }

    func recenterViewport() {
        viewportCenter = BoardPosition(row: board.size / 2, column: board.size / 2)
        viewportResetID = UUID()
    }

    private func continueAfterMove() {
        scheduleComputerMoveIfNeeded()
    }

    private func expandVisibleBoardIfNeeded(around position: BoardPosition) {
        var expandedLineCount = visibleLineCount

        while expandedLineCount < board.size {
            let radius = expandedLineCount / 2
            let isNearVisibleEdge = position.row <= viewportCenter.row - radius + Self.expansionThreshold
                || position.row >= viewportCenter.row + radius - Self.expansionThreshold
                || position.column <= viewportCenter.column - radius + Self.expansionThreshold
                || position.column >= viewportCenter.column + radius - Self.expansionThreshold
            guard isNearVisibleEdge else { break }
            expandedLineCount = min(board.size, expandedLineCount + Self.expansionIncrement)
        }

        guard expandedLineCount != visibleLineCount else { return }
        visibleLineCount = expandedLineCount
        viewportCenter = clampedViewportCenter(viewportCenter)
    }

    private func clampedViewportCenter(_ position: BoardPosition) -> BoardPosition {
        let viewportRadius = visibleLineCount / 2
        let upperBound = board.size - viewportRadius - 1
        return BoardPosition(
            row: min(max(position.row, viewportRadius), upperBound),
            column: min(max(position.column, viewportRadius), upperBound)
        )
    }

    private func invalidateComputerMove() {
        computerRequestID = UUID()
        computerTask?.cancel()
        computerTask = nil
    }

    private func scheduleComputerMoveIfNeeded() {
        guard isComputerTurn, computerTask == nil else { return }
        let requestID = computerRequestID
        let boardSnapshot = board
        let stone = turn
        let difficulty = difficulty
        let delay = computerMoveDelay
        let compute = computerMove
        computerTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard self?.computerRequestID == requestID,
                  self?.isComputerTurn == true, self?.turn == stone else { return }
            let position = await compute(boardSnapshot, stone, difficulty)
            guard let self, !Task.isCancelled,
                  self.computerRequestID == requestID,
                  self.isComputerTurn, self.turn == stone else { return }
            self.computerTask = nil
            guard let position else { return }
            self.commitComputerMove(at: position)
        }
    }

    private func finish(winner: Int) {
        self.winner = winner
        // Keep the completed board visible. The red winning line is the result
        // presentation; the board is cleared only after the player goes back.
        showResult = false
        if mode == .versusAI, winner == 0 {
            playerWins += 1
        }
    }

    private func owner(for stone: Stone) -> Int {
        stone == .black ? blackOwner : 1 - blackOwner
    }

    private func ownerName(_ owner: Int) -> String {
        mode == .versusAI ? (owner == 0 ? "玩家" : "AI") : "玩家\(owner + 1)"
    }

    private static let expansionIncrement = 10
    private static let expansionThreshold = 2
}
