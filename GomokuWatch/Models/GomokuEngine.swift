import Foundation

enum Stone: Int, Codable, CaseIterable {
    case black
    case white

    var title: String { self == .black ? "黑棋" : "白棋" }
    var symbol: String { self == .black ? "●" : "○" }
    var opposite: Stone { self == .black ? .white : .black }
}

enum GameMode: String, CaseIterable, Identifiable {
    case versusPlayer = "玩家对战"
    case versusAI = "AI 对战"

    var id: String { rawValue }
}

enum AIDifficulty: String, CaseIterable, Identifiable {
    case easy = "简单"
    case medium = "中等"
    case hard = "困难"

    var id: String { rawValue }
}

struct BoardPosition: Hashable, Codable {
    let row: Int
    let column: Int
}

struct GomokuBoard {
    static let defaultSize = 101

    private(set) var size: Int
    private(set) var stones: [BoardPosition: Stone] = [:]
    // A count rather than a Set lets the search remove a stone and restore its
    // exact candidate neighborhood without rebuilding candidates from every
    // occupied intersection.
    private var candidateRefCounts: [BoardPosition: Int] = [:]
    private var positionHash: UInt64 = 0
    private var evaluationEnabled = false
    private var patterns: [BoardPosition: CachedPattern] = [:]
    private var blackEvaluation = 0
    private var whiteEvaluation = 0
    private static let axes = [(0, 1), (1, 0), (1, 1), (1, -1)]

    init(size: Int = Self.defaultSize) {
        precondition(size >= 5)
        self.size = size
    }

    func positions(rows: Range<Int>, columns: Range<Int>) -> [BoardPosition] {
        rows.flatMap { row in
            columns.map { BoardPosition(row: row, column: $0) }
        }
    }

    func contains(_ position: BoardPosition) -> Bool {
        position.row >= 0 && position.row < size && position.column >= 0 && position.column < size
    }

    func stone(at position: BoardPosition) -> Stone? {
        stones[position]
    }

    mutating func place(_ stone: Stone, at position: BoardPosition) -> Bool {
        guard contains(position), stones[position] == nil else { return false }
        stones[position] = stone
        adjustCandidateReferences(around: position, by: 1)
        positionHash ^= Self.zobristValue(at: position, stone: stone)
        updateEvaluation(around: position)
        return true
    }

    @discardableResult
    mutating func removeStone(at position: BoardPosition) -> Stone? {
        guard let removed = stones.removeValue(forKey: position) else { return nil }
        adjustCandidateReferences(around: position, by: -1)
        positionHash ^= Self.zobristValue(at: position, stone: removed)
        updateEvaluation(around: position)
        return removed
    }

    func isWinningMove(at position: BoardPosition) -> Bool {
        !winningLine(containing: position).isEmpty
    }

    func winningLine(containing position: BoardPosition) -> [BoardPosition] {
        guard let stone = stones[position] else { return [] }
        let axes = [(0, 1), (1, 0), (1, 1), (1, -1)]
        for (rowStep, columnStep) in axes {
            var start = position
            var previous = start.offset(row: -rowStep, column: -columnStep)
            while contains(previous), stones[previous] == stone {
                start = previous
                previous = start.offset(row: -rowStep, column: -columnStep)
            }

            var line: [BoardPosition] = []
            var current = start
            while contains(current), stones[current] == stone {
                line.append(current)
                current = current.offset(row: rowStep, column: columnStep)
            }
            if line.count >= 5 { return line }
        }
        return []
    }

    func nearbyEmptyPositions() -> [BoardPosition] {
        guard !stones.isEmpty else {
            let center = size / 2
            return [BoardPosition(row: center, column: center)]
        }
        return candidateRefCounts.keys
            .filter { stones[$0] == nil }
            .sorted { ($0.row, $0.column) < ($1.row, $1.column) }
    }

    private mutating func adjustCandidateReferences(around position: BoardPosition, by delta: Int) {
        for rowDelta in -2...2 {
            for columnDelta in -2...2 {
                let candidate = BoardPosition(row: position.row + rowDelta, column: position.column + columnDelta)
                guard contains(candidate) else { continue }
                let updatedCount = (candidateRefCounts[candidate] ?? 0) + delta
                if updatedCount == 0 {
                    candidateRefCounts.removeValue(forKey: candidate)
                } else {
                    candidateRefCounts[candidate] = updatedCount
                }
            }
        }
    }

    func bestMove(for stone: Stone, difficulty: AIDifficulty) -> BoardPosition? {
        // The app model keeps its own immutable snapshot while the AI thinks.
        // The worker then owns this copy and can make/undo moves in place.
        var searchBoard = self
        let move = searchBoard.bestMoveInPlace(for: stone, difficulty: difficulty)
        return Task.isCancelled ? nil : move
    }

    private mutating func bestMoveInPlace(for stone: Stone, difficulty: AIDifficulty) -> BoardPosition? {
        guard !Task.isCancelled else { return nil }
        let configuration = SearchConfiguration(for: difficulty)
        var budget = SearchBudget(limit: configuration.nodeLimit, timeLimit: configuration.timeLimit)
        let candidates = nearbyEmptyPositions()
        guard !candidates.isEmpty else { return nil }

        // Every level understands an immediate win or loss. "Easy" should be
        // approachable, not lose a game by overlooking a one-move threat.
        if let win = firstWinningMove(in: candidates, for: stone) { return win }
        if let block = firstWinningMove(in: candidates, for: stone.opposite) { return block }

        prepareEvaluation()
        let ranked = rankedCandidates(candidates, for: stone, difficulty: difficulty)
        // A complete threat classification is substantially more expensive than
        // a line score. Strong engines run it only after cheap ordering has
        // identified the moves most likely to contain a forcing sequence.
        // Forcing fours are retained independently of ordinary move ordering.
        let forcingPositions = Set(forcingCandidates(in: ranked, for: stone).map(\.position))
            .union(forcingCandidates(in: ranked, for: stone.opposite).map(\.position))
        let tacticalPool = ranked.filter { forcingPositions.contains($0.position) }
            + ranked.prefix(configuration.tacticalCandidateLimit).filter { !forcingPositions.contains($0.position) }

        // Creating two distinct next-move wins is decisive when the opponent
        // has no immediate win (checked above). A mere rush four is not: never
        // let speculative defense take priority over this winning attack.
        let winningAttacks = decisiveFourMoves(in: tacticalPool, for: stone, budget: &budget)
        if let attack = winningAttacks.first { return attack.position }

        if difficulty != .easy, !budget.isExhausted {
            var vcfBudget = SearchBudget(
                limit: min(256, configuration.nodeLimit / 4),
                timeLimit: min(0.08, budget.remainingTime * 0.2)
            )
            let forcedWin = continuousFourWin(for: stone, remainingPlies: 9, budget: &vcfBudget)
            budget.visit(vcfBudget.visitedNodes)
            if let forcedWin, !Task.isCancelled { return forcedWin }
        }

        let decisiveBlocks = decisiveFourMoves(in: tacticalPool, for: stone.opposite, budget: &budget)
        if let block = rankedCandidates(decisiveBlocks.map(\.position), for: stone, difficulty: .hard).first {
            return block.position
        }

        // Double threes are slower than fours. Only use the development
        // shortcut when the opponent cannot force an immediate reply with a four;
        // otherwise let search compare the competing forcing sequences.
        let forcingBlocks = forcingFourMoves(in: tacticalPool, for: stone.opposite, budget: &budget)
        if forcingBlocks.isEmpty && !budget.isExhausted {
            let attackingForks = doubleThreatMoves(in: tacticalPool, for: stone, budget: &budget)
            if let attack = rankedCandidates(attackingForks.map(\.position), for: stone, difficulty: .hard).first {
                return attack.position
            }
            let forkBlocks = doubleThreatMoves(in: tacticalPool, for: stone.opposite, budget: &budget)
            if let block = rankedCandidates(forkBlocks.map(\.position), for: stone, difficulty: .hard).first {
                return block.position
            }
        }

        var transpositionTable: [TranspositionKey: TranspositionEntry] = [:]
        let ordinaryRootPositions = Set(ranked.prefix(configuration.rootCandidateLimit).map(\.position))
        var rootOrder = ranked.filter { ordinaryRootPositions.contains($0.position) || forcingPositions.contains($0.position) }
        var completedScores = rootOrder

        // Iterative deepening always leaves a fully evaluated shallower answer
        // when the watch reaches its node budget. Results from a half-finished
        // deeper pass are never allowed to displace that reliable move.
        for depth in 1...configuration.depth {
            var iteration: [ScoredPosition] = []
            var completedIteration = true
            var rootBest = Int.min / 4

            for candidate in rootOrder {
                if budget.isExhausted {
                    completedIteration = false
                    break
                }
                guard place(stone, at: candidate.position) else { continue }
                let score: Int?
                if isWinningMove(at: candidate.position) {
                    score = Self.winScore + depth
                } else {
                    score = alphaBeta(
                        toMove: stone.opposite,
                        perspective: stone,
                        remainingDepth: depth - 1,
                        forcingDepth: configuration.forcingDepth,
                        // A one-point margin preserves exact ties. Fail-low scores
                        // are strictly below the incumbent and cannot join its pool.
                        alpha: configuration.choicePoolSize > 1 ? Int.min / 4 : max(Int.min / 4, rootBest - 1),
                        beta: Int.max / 4,
                        candidateLimit: configuration.replyCandidateLimit,
                        budget: &budget,
                        transpositionTable: &transpositionTable
                    )
                }
                _ = removeStone(at: candidate.position)
                guard let score else {
                    completedIteration = false
                    break
                }
                rootBest = max(rootBest, score)
                iteration.append(ScoredPosition(position: candidate.position, score: score))
            }

            guard completedIteration else { break }
            iteration.sort(by: Self.strongerCandidate)
            completedScores = iteration
            rootOrder = iteration
        }

        // Easy keeps a small variety pool. Medium and Hard keep the strongest
        // evaluated score too, but choose among exact ties rather than letting
        // the row/column ordering invent a false directional preference (such
        // as repeatedly choosing the point above an otherwise symmetric move).
        let selectionPool: ArraySlice<ScoredPosition>
        if configuration.choicePoolSize > 1 {
            selectionPool = completedScores.prefix(configuration.choicePoolSize)
        } else if let bestScore = completedScores.first?.score {
            selectionPool = completedScores.prefix { $0.score == bestScore }
        } else {
            selectionPool = []
        }
        return Task.isCancelled ? nil : selectionPool.randomElement()?.position
    }

    private mutating func firstWinningMove(in candidates: [BoardPosition], for stone: Stone) -> BoardPosition? {
        for candidate in candidates {
            guard !Task.isCancelled else { return nil }
            if wouldWin(candidate, for: stone) { return candidate }
        }
        return nil
    }

    private mutating func winningMoves(
        in candidates: [ScoredPosition],
        for stone: Stone,
        budget: inout SearchBudget
    ) -> [ScoredPosition] {
        var winningMoves: [ScoredPosition] = []
        for candidate in candidates {
            guard !budget.isExhausted else { break }
            if wouldWin(candidate.position, for: stone) {
                winningMoves.append(candidate)
            }
        }
        return winningMoves
    }

    private mutating func decisiveFourMoves(
        in candidates: [ScoredPosition],
        for stone: Stone,
        budget: inout SearchBudget
    ) -> [ScoredPosition] {
        var result: [ScoredPosition] = []
        for candidate in candidates {
            guard !budget.isExhausted else { break }
            guard probePlace(stone, at: candidate.position) else { continue }
            var wins = Set<BoardPosition>()
            for (rowStep, columnStep) in [(0, 1), (1, 0), (1, 1), (1, -1)] {
                wins.formUnion(winningContinuations(
                    for: stone, around: candidate.position,
                    rowStep: rowStep, columnStep: columnStep
                ))
            }
            stones.removeValue(forKey: candidate.position)
            if wins.count >= 2 { result.append(candidate) }
        }
        return result
    }

    private mutating func forcingFourMoves(
        in candidates: [ScoredPosition],
        for stone: Stone,
        budget: inout SearchBudget
    ) -> [ScoredPosition] {
        var forcingMoves: [ScoredPosition] = []
        for candidate in candidates {
            guard !budget.isExhausted else { break }
            if createsForcingFour(at: candidate.position, for: stone) {
                forcingMoves.append(candidate)
            }
        }
        return forcingMoves
    }

    private mutating func doubleThreatMoves(
        in candidates: [ScoredPosition],
        for stone: Stone,
        budget: inout SearchBudget
    ) -> [ScoredPosition] {
        var forkMoves: [ScoredPosition] = []
        for candidate in candidates {
            guard !budget.isExhausted else { break }
            if createsDoubleThreat(at: candidate.position, for: stone) {
                forkMoves.append(candidate)
            }
        }
        return forkMoves
    }

    private func wouldWin(_ position: BoardPosition, for stone: Stone) -> Bool {
        guard isEmpty(position) else { return false }
        let axes = [(0, 1), (1, 0), (1, 1), (1, -1)]
        return axes.contains { rowStep, columnStep in
            1
                + count(stone, from: position, rowStep: rowStep, columnStep: columnStep)
                + count(stone, from: position, rowStep: -rowStep, columnStep: -columnStep)
                >= 5
        }
    }

    private mutating func createsForcingFour(at position: BoardPosition, for stone: Stone) -> Bool {
        fourAxisCount(at: position, for: stone) > 0
    }

    private mutating func createsDoubleThreat(at position: BoardPosition, for stone: Stone) -> Bool {
        threatProfile(at: position, for: stone).isFork
    }

    private mutating func fourAxisCount(at position: BoardPosition, for stone: Stone) -> Int {
        guard probePlace(stone, at: position) else { return 0 }
        let axes = [(0, 1), (1, 0), (1, 1), (1, -1)]
        let result = axes.filter { rowStep, columnStep in
            !winningContinuations(
                for: stone,
                around: position,
                rowStep: rowStep,
                columnStep: columnStep
            ).isEmpty
        }.count
        stones.removeValue(forKey: position)
        return result
    }

    private mutating func threatProfile(at position: BoardPosition, for stone: Stone) -> ThreatProfile {
        guard probePlace(stone, at: position) else { return .none }
        let axes = [(0, 1), (1, 0), (1, 1), (1, -1)]
        var fourAxes = 0
        var openFourAxes = 0
        var openThreeAxes = 0

        for (rowStep, columnStep) in axes {
            let winningContinuations = winningContinuations(
                for: stone,
                around: position,
                rowStep: rowStep,
                columnStep: columnStep
            )
            if !winningContinuations.isEmpty { fourAxes += 1 }
            if winningContinuations.count >= 2 { openFourAxes += 1 }

            // A live or broken three has an extension that creates at least
            // two winning continuations on the same axis. This recognizes
            // .XXX., .XX.X., and .X.XX. without relying on fragile strings.
            if winningContinuations.isEmpty,
               hasOpenThreeExtension(
                   for: stone,
                   around: position,
                   rowStep: rowStep,
                   columnStep: columnStep
               ) {
                openThreeAxes += 1
            }
        }
        let result = ThreatProfile(
            fourAxes: fourAxes,
            openFourAxes: openFourAxes,
            openThreeAxes: openThreeAxes
        )
        stones.removeValue(forKey: position)
        return result
    }

    private func winningContinuations(
        for stone: Stone,
        around origin: BoardPosition,
        rowStep: Int,
        columnStep: Int
    ) -> Set<BoardPosition> {
        var continuations = Set<BoardPosition>()
        for offset in -4...4 where offset != 0 {
            let candidate = origin.offset(row: rowStep * offset, column: columnStep * offset)
            guard isEmpty(candidate) else { continue }
            let forward = count(stone, from: candidate, rowStep: rowStep, columnStep: columnStep)
            let backward = count(stone, from: candidate, rowStep: -rowStep, columnStep: -columnStep)
            if 1 + forward + backward >= 5 {
                continuations.insert(candidate)
            }
        }
        return continuations
    }

    private mutating func hasOpenThreeExtension(
        for stone: Stone,
        around origin: BoardPosition,
        rowStep: Int,
        columnStep: Int
    ) -> Bool {
        for offset in -4...4 where offset != 0 {
            let extensionMove = origin.offset(row: rowStep * offset, column: columnStep * offset)
            guard isEmpty(extensionMove) else { continue }
            guard probePlace(stone, at: extensionMove) else { continue }
            let wins = winningContinuations(
                for: stone,
                around: origin,
                rowStep: rowStep,
                columnStep: columnStep
            )
            stones.removeValue(forKey: extensionMove)
            if wins.count >= 2 { return true }
        }
        return false
    }

    private func heuristic(at position: BoardPosition, for stone: Stone, difficulty: AIDifficulty) -> Int {
        let axes = [(0, 1), (1, 0), (1, 1), (1, -1)]
        // Sum all axes so a move that creates two threats (a fork) outranks a
        // superficially longer line in only one direction. Five-cell windows
        // also recognize broken shapes such as XX_XX and X_XX_.
        let attack = patterns[position]?.total(for: stone)
            ?? axes.map { lineValue(at: position, for: stone, rowStep: $0.0, columnStep: $0.1) }.reduce(0, +)
        let defense = patterns[position]?.total(for: stone.opposite)
            ?? axes.map { lineValue(at: position, for: stone.opposite, rowStep: $0.0, columnStep: $0.1) }.reduce(0, +)
        let centerDistance = abs(position.row - size / 2) + abs(position.column - size / 2)
        // The logical board is intentionally very large. Keep the opening
        // preference local so it does not dominate pattern strength or pull a
        // developed game back toward the physical center.
        let centerBonus = max(0, 12 - centerDistance)
        switch difficulty {
        case .easy:
            return attack * 9 + defense * 9 + centerBonus
        case .medium:
            return attack * 12 + defense * 11 + centerBonus
        case .hard:
            return attack * 14 + defense * 13 + centerBonus
        }
    }

    private func rankedCandidates(
        _ candidates: [BoardPosition],
        for stone: Stone,
        difficulty: AIDifficulty
    ) -> [ScoredPosition] {
        candidates.map { position in
            ScoredPosition(position: position, score: heuristic(at: position, for: stone, difficulty: difficulty))
        }.sorted(by: Self.strongerCandidate)
    }

    private static func strongerCandidate(_ lhs: ScoredPosition, _ rhs: ScoredPosition) -> Bool {
        lhs.score == rhs.score
            ? (lhs.position.row, lhs.position.column) < (rhs.position.row, rhs.position.column)
            : lhs.score > rhs.score
    }

    private mutating func searchMoves(
        for stone: Stone,
        candidateLimit: Int,
        forcingOnly: Bool,
        budget: inout SearchBudget
    ) -> [ScoredPosition] {
        let ranked = rankedCandidates(nearbyEmptyPositions(), for: stone, difficulty: .hard)
        guard !ranked.isEmpty else { return [] }

        let wins = winningMoves(in: ranked, for: stone, budget: &budget)
        if !wins.isEmpty { return wins }
        let blocks = winningMoves(in: ranked, for: stone.opposite, budget: &budget)
        if !blocks.isEmpty { return blocks }
        if forcingOnly {
            // Immediate wins must scan every local move. Lower-priority threats
            // rank near the front, so only the horizon extension needs this
            // richer classification. Normal layers evaluate them through the
            // ordered Alpha-Beta tree without repeating the same work.
            let forcingPositions = Set(forcingCandidates(in: ranked, for: stone).map(\.position))
                .union(forcingCandidates(in: ranked, for: stone.opposite).map(\.position))
            let tacticalPool = ranked.filter { forcingPositions.contains($0.position) }
                + ranked.prefix(min(candidateLimit, 8)).filter { !forcingPositions.contains($0.position) }
            let attacks = forcingFourMoves(in: tacticalPool, for: stone, budget: &budget)
            if !attacks.isEmpty { return attacks }
            let forcingBlocks = forcingFourMoves(in: tacticalPool, for: stone.opposite, budget: &budget)
            if !forcingBlocks.isEmpty { return forcingBlocks }
            let forks = doubleThreatMoves(in: tacticalPool, for: stone, budget: &budget)
            if !forks.isEmpty { return forks }
            let forkBlocks = doubleThreatMoves(in: tacticalPool, for: stone.opposite, budget: &budget)
            if !forkBlocks.isEmpty { return forkBlocks }
        }

        guard !forcingOnly else { return [] }
        let retained = Set(ranked.prefix(candidateLimit).map(\.position))
            .union(forcingCandidates(in: ranked, for: stone).map(\.position))
            .union(forcingCandidates(in: ranked, for: stone.opposite).map(\.position))
        return ranked.filter { retained.contains($0.position) }
    }

    mutating func alphaBeta(
        toMove: Stone,
        perspective: Stone,
        remainingDepth: Int,
        forcingDepth: Int,
        alpha: Int,
        beta: Int,
        candidateLimit: Int,
        budget: inout SearchBudget,
        transpositionTable: inout [TranspositionKey: TranspositionEntry]
    ) -> Int? {
        guard !budget.isExhausted else { return nil }
        budget.visit()
        prepareEvaluation()
        let key = TranspositionKey(hash: positionHash, toMove: toMove, perspective: perspective)
        let cachedEntry = transpositionTable[key]
        let startingAlpha = alpha
        let startingBeta = beta
        var alpha = alpha
        var beta = beta

        if let cachedEntry,
           cachedEntry.remainingDepth >= remainingDepth,
           cachedEntry.forcingDepth >= forcingDepth {
            switch cachedEntry.bound {
            case .exact:
                return cachedEntry.score
            case .lower:
                alpha = max(alpha, cachedEntry.score)
            case .upper:
                beta = min(beta, cachedEntry.score)
            }
            if alpha >= beta { return cachedEntry.score }
        }

        let forcingOnly = remainingDepth <= 0
        guard !forcingOnly || forcingDepth > 0 else {
            let score = boardScore(for: perspective)
            storeTransposition(
                key: key,
                score: score,
                bestMove: nil,
                remainingDepth: remainingDepth,
                forcingDepth: forcingDepth,
                bound: .exact,
                in: &transpositionTable,
                limit: budget.limit
            )
            return score
        }

        var moves = searchMoves(
            for: toMove,
            candidateLimit: candidateLimit,
            forcingOnly: forcingOnly,
            budget: &budget
        )
        guard !budget.isExhausted else { return nil }
        if let preferredMove = cachedEntry?.bestMove,
           let preferredIndex = moves.firstIndex(where: { $0.position == preferredMove }) {
            moves.insert(moves.remove(at: preferredIndex), at: 0)
        }
        guard !moves.isEmpty else {
            let score = boardScore(for: perspective)
            storeTransposition(
                key: key,
                score: score,
                bestMove: nil,
                remainingDepth: remainingDepth,
                forcingDepth: forcingDepth,
                bound: .exact,
                in: &transpositionTable,
                limit: budget.limit
            )
            return score
        }
        let nextDepth = max(0, remainingDepth - 1)
        let nextForcingDepth = forcingOnly ? forcingDepth - 1 : forcingDepth

        if toMove == perspective {
            var best = Int.min / 4
            var bestMove: BoardPosition?
            for move in moves {
                guard place(toMove, at: move.position) else { continue }
                let score: Int?
                if isWinningMove(at: move.position) {
                    score = Self.winScore + remainingDepth
                } else {
                    score = alphaBeta(
                        toMove: toMove.opposite,
                        perspective: perspective,
                        remainingDepth: nextDepth,
                        forcingDepth: nextForcingDepth,
                        alpha: alpha,
                        beta: beta,
                        candidateLimit: candidateLimit,
                        budget: &budget,
                        transpositionTable: &transpositionTable
                    )
                }
                _ = removeStone(at: move.position)
                guard let score else { return nil }
                if score > best {
                    best = score
                    bestMove = move.position
                }
                alpha = max(alpha, best)
                guard !budget.isExhausted else { return nil }
                if alpha >= beta { break }
            }
            storeTransposition(
                key: key,
                score: best,
                bestMove: bestMove,
                remainingDepth: remainingDepth,
                forcingDepth: forcingDepth,
                bound: transpositionBound(score: best, alpha: startingAlpha, beta: startingBeta),
                in: &transpositionTable,
                limit: budget.limit
            )
            return best
        }

        var best = Int.max / 4
        var bestMove: BoardPosition?
        for move in moves {
            guard place(toMove, at: move.position) else { continue }
            let score: Int?
            if isWinningMove(at: move.position) {
                score = -Self.winScore - remainingDepth
            } else {
                score = alphaBeta(
                    toMove: toMove.opposite,
                    perspective: perspective,
                    remainingDepth: nextDepth,
                    forcingDepth: nextForcingDepth,
                    alpha: alpha,
                    beta: beta,
                    candidateLimit: candidateLimit,
                    budget: &budget,
                    transpositionTable: &transpositionTable
                )
            }
            _ = removeStone(at: move.position)
            guard let score else { return nil }
            if score < best {
                best = score
                bestMove = move.position
            }
            beta = min(beta, best)
            guard !budget.isExhausted else { return nil }
            if alpha >= beta { break }
        }
        storeTransposition(
            key: key,
            score: best,
            bestMove: bestMove,
            remainingDepth: remainingDepth,
            forcingDepth: forcingDepth,
            bound: transpositionBound(score: best, alpha: startingAlpha, beta: startingBeta),
            in: &transpositionTable,
            limit: budget.limit
        )
        return best
    }

    private func transpositionBound(score: Int, alpha: Int, beta: Int) -> TranspositionBound {
        if score <= alpha { return .upper }
        if score >= beta { return .lower }
        return .exact
    }

    private func storeTransposition(
        key: TranspositionKey,
        score: Int,
        bestMove: BoardPosition?,
        remainingDepth: Int,
        forcingDepth: Int,
        bound: TranspositionBound,
        in table: inout [TranspositionKey: TranspositionEntry],
        limit: Int
    ) {
        guard table.count < limit || table[key] != nil else { return }
        if let existing = table[key],
           existing.remainingDepth > remainingDepth,
           existing.forcingDepth >= forcingDepth {
            return
        }
        table[key] = TranspositionEntry(
            score: score,
            bestMove: bestMove,
            remainingDepth: remainingDepth,
            forcingDepth: forcingDepth,
            bound: bound
        )
    }

    // The same four-axis patterns drive both move ordering and leaf evaluation.
    // Only empty local intersections contribute; shared lines are not counted
    // again for every stone in a contiguous run.
    func boardScore(for perspective: Stone) -> Int {
        let difference: Int
        if evaluationEnabled {
            difference = blackEvaluation - whiteEvaluation
        } else {
            difference = nearbyEmptyPositions().reduce(0) { total, position in
                total + Self.axes.reduce(0) { value, axis in
                    value + lineValue(at: position, for: .black, rowStep: axis.0, columnStep: axis.1)
                        - lineValue(at: position, for: .white, rowStep: axis.0, columnStep: axis.1)
                }
            }
        }
        // A heuristic position must never outrank a proven win.
        return max(-Self.winScore / 2, min(Self.winScore / 2, perspective == .black ? difference : -difference))
    }

    mutating func prepareEvaluation() {
        guard !evaluationEnabled else { return }
        evaluationEnabled = true
        for position in nearbyEmptyPositions() {
            let pattern = makePattern(at: position)
            patterns[position] = pattern
            blackEvaluation += pattern.total(for: .black)
            whiteEvaluation += pattern.total(for: .white)
        }
    }

    private func makePattern(at position: BoardPosition) -> CachedPattern {
        CachedPattern(
            black: Self.axes.map { lineValue(at: position, for: .black, rowStep: $0.0, columnStep: $0.1) },
            white: Self.axes.map { lineValue(at: position, for: .white, rowStep: $0.0, columnStep: $0.1) }
        )
    }

    private mutating func updateEvaluation(around changed: BoardPosition) {
        guard evaluationEnabled else { return }
        // Full affected lines keep this correct even on imported overline boards.
        // Existing entries only recompute the direction that actually changed.
        var affected = Set<BoardPosition>()
        for axis in Self.axes {
            for offset in -(size - 1)...(size - 1) {
                let p = changed.offset(row: axis.0 * offset, column: axis.1 * offset)
                if contains(p) { affected.insert(p) }
            }
        }
        for r in -2...2 {
            for c in -2...2 { affected.insert(changed.offset(row: r, column: c)) }
        }
        for position in affected {
            let old = patterns[position]
            let available = candidateRefCounts[position] != nil && isEmpty(position)
            if let old {
                blackEvaluation -= old.total(for: .black)
                whiteEvaluation -= old.total(for: .white)
            }
            guard available else {
                patterns.removeValue(forKey: position)
                continue
            }
            var next = old ?? makePattern(at: position)
            if old != nil {
                let r = changed.row - position.row
                let c = changed.column - position.column
                for (index, axis) in Self.axes.enumerated() where r * axis.1 == c * axis.0 {
                    next.black[index] = lineValue(at: position, for: .black, rowStep: axis.0, columnStep: axis.1)
                    next.white[index] = lineValue(at: position, for: .white, rowStep: axis.0, columnStep: axis.1)
                }
            }
            patterns[position] = next
            blackEvaluation += next.total(for: .black)
            whiteEvaluation += next.total(for: .white)
        }
        // The empty-board center is synthetic and has no reference count.
        if stones.isEmpty {
            patterns.removeAll(keepingCapacity: true)
            blackEvaluation = 0
            whiteEvaluation = 0
        }
    }

    private mutating func probePlace(_ stone: Stone, at position: BoardPosition) -> Bool {
        guard isEmpty(position) else { return false }
        stones[position] = stone
        return true
    }

    private func forcingCandidates(in candidates: [ScoredPosition], for stone: Stone) -> [ScoredPosition] {
        candidates.filter { candidate in
            let values = patterns[candidate.position]?.values(for: stone)
                ?? Self.axes.map { lineValue(at: candidate.position, for: stone, rowStep: $0.0, columnStep: $0.1) }
            // Every four occupies four cells of an unblocked five-cell window.
            return values.contains { $0 >= 28_000 }
        }
    }

    // A returned move is a proof within this VCF tree. nil means unproven,
    // including timeout; it is never used to assert that no win exists.
    mutating func continuousFourWin(for attacker: Stone, remainingPlies: Int, budget: inout SearchBudget) -> BoardPosition? {
        guard remainingPlies > 0, !budget.isExhausted else { return nil }
        budget.visit()
        let candidates = nearbyEmptyPositions()
        if let win = firstWinningMove(in: candidates, for: attacker) { return win }
        guard !budget.isExhausted else { return nil }
        let opponentWins = candidates.filter { wouldWin($0, for: attacker.opposite) }
        guard opponentWins.count <= 1 else { return nil }
        let ranked = rankedCandidates(opponentWins.isEmpty ? candidates : opponentWins, for: attacker, difficulty: .hard)
        for candidate in forcingCandidates(in: ranked, for: attacker) {
            guard !budget.isExhausted else { return nil }
            guard place(attacker, at: candidate.position) else { continue }
            var proven = false
            let replies = nearbyEmptyPositions()
            // The defender can take its own win instead of answering our four.
            if firstWinningMove(in: replies, for: attacker.opposite) == nil {
                let wins = replies.filter { wouldWin($0, for: attacker) }
                if wins.count >= 2 {
                    proven = true
                } else if let forcedReply = wins.first, remainingPlies >= 3 {
                    _ = place(attacker.opposite, at: forcedReply)
                    proven = continuousFourWin(for: attacker, remainingPlies: remainingPlies - 2, budget: &budget) != nil
                    _ = removeStone(at: forcedReply)
                }
            }
            _ = removeStone(at: candidate.position)
            if proven && !budget.isExhausted { return candidate.position }
        }
        return nil
    }

    private func lineValue(at position: BoardPosition, for stone: Stone, rowStep: Int, columnStep: Int) -> Int {
        let forward = count(stone, from: position, rowStep: rowStep, columnStep: columnStep)
        let backward = count(stone, from: position, rowStep: -rowStep, columnStep: -columnStep)
        let runLength = 1 + forward + backward
        let openEnds = (isEmpty(position.offset(row: rowStep * (forward + 1), column: columnStep * (forward + 1))) ? 1 : 0)
            + (isEmpty(position.offset(row: -rowStep * (backward + 1), column: -columnStep * (backward + 1))) ? 1 : 0)

        let contiguousValue: Int
        switch (runLength, openEnds) {
        case (5..., _): contiguousValue = 500_000
        case (4, 2): contiguousValue = 120_000
        case (4, 1): contiguousValue = 35_000
        case (4, 0): contiguousValue = 0
        case (3, 2): contiguousValue = 8_000
        case (3, 1): contiguousValue = 900
        case (3, 0): contiguousValue = 0
        case (2, 2): contiguousValue = 350
        case (2, 1): contiguousValue = 60
        case (2, 0): contiguousValue = 0
        default: contiguousValue = 8
        }

        var windowValues: [Int] = []
        for startOffset in -4...0 {
            var ownStones = 0
            var isBlocked = false
            for index in 0..<5 {
                let cell = position.offset(
                    row: rowStep * (startOffset + index),
                    column: columnStep * (startOffset + index)
                )
                guard contains(cell) else {
                    isBlocked = true
                    break
                }
                if cell == position || stones[cell] == stone {
                    ownStones += 1
                } else if stones[cell] == stone.opposite {
                    isBlocked = true
                    break
                }
            }
            guard !isBlocked else { continue }
            switch ownStones {
            case 5: windowValues.append(500_000)
            case 4: windowValues.append(28_000)
            case 3: windowValues.append(1_500)
            case 2: windowValues.append(120)
            default: windowValues.append(8)
            }
        }
        windowValues.sort(by: >)
        let brokenShapeValue = (windowValues.first ?? 0) + (windowValues.dropFirst().first ?? 0) / 4
        return max(contiguousValue, brokenShapeValue)
    }

    private func count(_ stone: Stone, from origin: BoardPosition, rowStep: Int, columnStep: Int) -> Int {
        var position = origin.offset(row: rowStep, column: columnStep)
        var total = 0
        while contains(position), stones[position] == stone {
            total += 1
            position = position.offset(row: rowStep, column: columnStep)
        }
        return total
    }

    private func isEmpty(_ position: BoardPosition) -> Bool {
        contains(position) && stones[position] == nil
    }

    private static func zobristValue(at position: BoardPosition, stone: Stone) -> UInt64 {
        var value = UInt64(position.row &* 131_071 &+ position.column &* 8_191 &+ stone.rawValue &* 1_009)
        value &+= stone == .black ? 0x9E3779B97F4A7C15 : 0xD1B54A32D192ED03
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}

private struct CachedPattern {
    var black: [Int]
    var white: [Int]
    func values(for stone: Stone) -> [Int] { stone == .black ? black : white }
    func total(for stone: Stone) -> Int { values(for: stone).reduce(0, +) }
}

private struct ThreatProfile {
    let fourAxes: Int
    let openFourAxes: Int
    let openThreeAxes: Int

    static let none = ThreatProfile(fourAxes: 0, openFourAxes: 0, openThreeAxes: 0)

    var isFork: Bool {
        openFourAxes > 0
            || fourAxes >= 2
            || (fourAxes >= 1 && openThreeAxes >= 1)
            || openThreeAxes >= 2
    }
}

private struct ScoredPosition {
    let position: BoardPosition
    let score: Int
}

struct TranspositionKey: Hashable {
    let hash: UInt64
    let toMove: Stone
    let perspective: Stone
}

struct TranspositionEntry {
    let score: Int
    let bestMove: BoardPosition?
    let remainingDepth: Int
    let forcingDepth: Int
    let bound: TranspositionBound
}

enum TranspositionBound {
    case exact
    case lower
    case upper
}

private struct SearchConfiguration {
    let depth: Int
    let forcingDepth: Int
    let rootCandidateLimit: Int
    let replyCandidateLimit: Int
    let nodeLimit: Int
    let tacticalCandidateLimit: Int
    let timeLimit: TimeInterval
    let choicePoolSize: Int

    init(for difficulty: AIDifficulty) {
        switch difficulty {
        case .easy:
            depth = 1
            forcingDepth = 1
            rootCandidateLimit = 6
            replyCandidateLimit = 4
            nodeLimit = 300
            tacticalCandidateLimit = 6
            timeLimit = 0.10
            choicePoolSize = 3
        case .medium:
            depth = 3
            forcingDepth = 2
            rootCandidateLimit = 10
            replyCandidateLimit = 8
            nodeLimit = 1_200
            tacticalCandidateLimit = 10
            timeLimit = 0.30
            choicePoolSize = 1
        case .hard:
            depth = 5
            forcingDepth = 3
            rootCandidateLimit = 14
            replyCandidateLimit = 10
            nodeLimit = 4_000
            tacticalCandidateLimit = 16
            timeLimit = 0.65
            choicePoolSize = 1
        }
    }
}

struct SearchBudget {
    let limit: Int
    let timeLimit: TimeInterval
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private(set) var visitedNodes = 0

    var remainingTime: TimeInterval {
        max(0, timeLimit - (ProcessInfo.processInfo.systemUptime - startedAt))
    }

    var isExhausted: Bool {
        Task.isCancelled || visitedNodes >= limit || remainingTime <= 0
    }

    mutating func visit(_ count: Int = 1) {
        visitedNodes += count
    }
}

private extension GomokuBoard {
    static let winScore = 100_000_000
}

private extension BoardPosition {
    func offset(row: Int, column: Int) -> BoardPosition {
        BoardPosition(row: self.row + row, column: self.column + column)
    }
}
