import SwiftUI

struct GameView: View {
    @StateObject private var game = GameViewModel()

    var body: some View {
        Group {
            switch game.screen {
            case .modeSelection:
                ModeSelectionView(
                    playerWins: game.playerWins,
                    chooseAI: game.showDifficultySelection,
                    choosePlayer: game.choosePlayerMatch
                )
            case .difficultySelection:
                DifficultySelectionView(back: game.returnToModeSelection, choose: game.chooseAIDifficulty)
            case .colorSelection:
                ColorSelectionView(
                    difficulty: game.pendingDifficulty,
                    back: game.showDifficultySelection,
                    choose: { color in
                        game.chooseAIMatch(difficulty: game.pendingDifficulty, playerColor: color)
                    }
                )
            case .game:
                MatchView(game: game)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: game.screen)
    }
}

private struct ModeSelectionView: View {
    let playerWins: Int
    let chooseAI: () -> Void
    let choosePlayer: () -> Void

    var body: some View {
        VStack(spacing: 5) {
            CompactTopBar(title: "选择游戏模式")
            ScrollView {
                VStack(spacing: 9) {
                    SelectionCard(
                        identifier: "mode.ai",
                        symbol: "cpu",
                        title: "与 AI 对战",
                        subtitle: "玩家胜 \(playerWins) 局",
                        action: chooseAI
                    )
                    SelectionCard(
                        identifier: "mode.player",
                        symbol: "person.2.fill",
                        title: "与朋友对战",
                        subtitle: "轮流落子",
                        action: choosePlayer
                    )
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }
}

private struct DifficultySelectionView: View {
    let back: () -> Void
    let choose: (AIDifficulty) -> Void

    var body: some View {
        VStack(spacing: 4) {
            CompactTopBar(title: "选择难度", action: back)
            VStack(spacing: 4) {
                SelectionCard(identifier: "difficulty.easy", symbol: "leaf.fill", title: "简单", subtitle: "基础判断，适合入门", compact: true) { choose(.easy) }
                SelectionCard(identifier: "difficulty.medium", symbol: "sparkles", title: "中等", subtitle: "多步推演，攻守均衡", compact: true) { choose(.medium) }
                SelectionCard(identifier: "difficulty.hard", symbol: "flame.fill", title: "困难", subtitle: "深度推演，连环攻防", compact: true) { choose(.hard) }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }
}

private struct ColorSelectionView: View {
    let difficulty: AIDifficulty
    let back: () -> Void
    let choose: (Stone) -> Void

    var body: some View {
        VStack(spacing: 5) {
            CompactTopBar(title: "选择执棋", action: back)
            ScrollView {
                VStack(spacing: 7) {
                    SelectionCard(
                        identifier: "color.black",
                        symbol: "circle.fill",
                        title: "玩家执黑",
                        subtitle: "\(difficulty.rawValue) · 你先手"
                    ) { choose(.black) }
                    SelectionCard(
                        identifier: "color.white",
                        symbol: "circle",
                        title: "玩家执白",
                        subtitle: "\(difficulty.rawValue) · AI 先手"
                    ) { choose(.white) }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }
}

private struct CompactTopBar: View {
    let title: String
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            if let action {
                Button(action: action) {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.bold))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                }
                .buttonStyle(.plain)
            }
            Text(title)
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .layoutPriority(1)
            Spacer(minLength: 0)
        }
        .frame(height: 24, alignment: .top)
    }
}

private struct SelectionCard: View {
    let identifier: String
    let symbol: String
    let title: String
    let subtitle: String
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: compact ? 6 : 7) {
                Image(systemName: symbol)
                    .font(compact ? .system(size: 16, weight: .bold) : .title3.weight(.bold))
                    .foregroundStyle(.yellow)
                    .frame(width: compact ? 26 : 30, height: compact ? 26 : 30)
                    .background(Circle().fill(Color.indigo))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(compact ? .system(size: 15, weight: .bold) : .subheadline.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(subtitle)
                        .font(compact ? .system(size: 11) : .caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
            }
            .padding(compact ? 4 : 7)
            .frame(maxHeight: compact ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: compact ? 12 : 15).fill(.thinMaterial))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel("\(title)，\(subtitle)")
    }
}

private struct MatchView: View {
    @ObservedObject var game: GameViewModel
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var boardFocused: Bool
    @State private var crownValue = 0.0
    @State private var scaleIndex = 0
    @State private var showExitConfirmation = false
    // Use several Crown detents for each zoom level. A single detent per level
    // made 1.5× effectively impossible to stop on while rotating the Crown.
    private let crownStepsPerScale = 6.0
    private let headerHeight: CGFloat = 42

    private var scales: [Double] {
        BoardZoomMetrics.surfaceScales(for: game.visibleLineCount)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                // The viewport begins below the controls. This is the only
                // protected edge: a dragged board cannot cover the title or clock.
                IntersectionBoardView(
                    board: game.board,
                    preview: game.selectedPosition,
                    previewStone: game.turn,
                    lastMovePosition: game.lastMovePosition,
                    winningLine: game.winningLine,
                    center: game.viewportCenter,
                    visibleLineCount: game.visibleLineCount,
                    baseSide: geometry.size.width,
                    scale: scales[scaleIndex],
                    resetID: game.viewportResetID,
                    onInteraction: {
                        game.dismissCrownHint()
                        requestBoardFocus(true)
                    },
                    onTap: { position in
                        game.dismissCrownHint()
                        requestBoardFocus(true)
                        game.tap(position)
                    }
                )
                .frame(height: max(0, geometry.size.height - headerHeight), alignment: .top)
                .padding(.top, headerHeight)

                matchHeader(width: geometry.size.width)

                if game.showCrownHint { CrownHintBanner().allowsHitTesting(false) }
                if game.isPaused {
                    PauseOverlay(
                        abandon: game.returnToModeSelection,
                        resume: game.resumeAfterInactivity
                    )
                }
            }
        }
        // Use the complete physical display. The header still protects the top
        // controls, while the board reaches the left, right, and bottom edges.
        .ignoresSafeArea(.container, edges: .all)
        .confirmationDialog("放弃当前对局？", isPresented: $showExitConfirmation, titleVisibility: .visible) {
            Button("放弃并返回首页", role: .destructive) { game.returnToModeSelection() }
            Button("继续对局", role: .cancel) {}
        } message: {
            Text("当前棋局不会保留。")
        }
        .alert(game.resultText, isPresented: $game.showResult) {
            Button("返回首页") { game.returnToModeSelection() }
        } message: {
            Text(game.isDraw ? "棋盘已满。" : "本局已结束。")
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active { game.pauseForInactivity() }
        }
        .onChange(of: game.isPaused) { _, isPaused in
            requestBoardFocus(!isPaused)
        }
        .onChange(of: game.viewportResetID) { _, _ in
            resetViewportAppearance()
        }
        .onAppear {
            requestBoardFocus(!game.isPaused)
        }
    }

    private func matchHeader(width: CGFloat) -> some View {
        // Include the 184-point SE 44 mm display and reserve room for the clock.
        let compact = width < 190
        let controlSide: CGFloat = compact ? 22 : 24
        let labelSize: CGFloat = compact ? 11 : 12

        return HStack(spacing: 4) {
            Button(action: requestExit) {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.bold))
                    .frame(width: controlSide, height: controlSide)
                    .background(Circle().fill(Color.white.opacity(0.16)))
            }
            .buttonStyle(.plain)
            // Keep the Digital Crown focus on an always-available concrete
            // control after removing the dedicated recenter button.
            .focusable(!game.isPaused)
            .focused($boardFocused)
            .digitalCrownRotation(
                $crownValue,
                from: 0,
                through: crownStepsPerScale * Double(scales.count - 1),
                by: 1,
                sensitivity: .low,
                isContinuous: false,
                isHapticFeedbackEnabled: true
            )
            .onChange(of: crownValue) { _, newValue in
                scaleIndex = min(
                    max(Int((newValue / crownStepsPerScale).rounded(.down)), 0),
                    scales.count - 1
                )
                game.dismissCrownHint()
            }
            .digitalCrownAccessory(.hidden)
            .accessibilityIdentifier("match.back")

            HStack(spacing: 3) {
                Text(headerStatusText)
                    .font(.system(size: labelSize, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .layoutPriority(1)

                if !game.isFinished {
                    ZStack {
                        Circle().fill(Color.white.opacity(0.28))
                        Circle()
                            .fill(game.turn == .black ? Color.black : Color.white)
                            .overlay(Circle().stroke(Color.black.opacity(0.7), lineWidth: 0.5))
                            .padding(2)
                    }
                    .frame(width: 13, height: 13)
                    .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("match.turn")
            .accessibilityLabel(
                game.isFinished
                    ? "\(modeText)，\(game.resultText)"
                    : "\(modeText)，\(game.playerName)，\(game.turn.title)回合"
            )

            Spacer(minLength: 0)

            Button(action: game.undoLastTurn) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.caption.weight(.bold))
                    .frame(width: controlSide, height: controlSide)
                    .background(Circle().fill(Color.white.opacity(game.canUndo ? 0.16 : 0.07)))
            }
            .buttonStyle(.plain)
            .disabled(!game.canUndo || game.isPaused)
            .accessibilityIdentifier("match.undo")
            .accessibilityLabel("悔棋")
            .accessibilityHint(
                game.mode == .versusAI
                    ? "撤回玩家上一手和 AI 的应手，可重复操作"
                    : "撤回上一手，可重复操作"
            )

        }
        .padding(.leading, compact ? 14 : 20)
        .padding(.trailing, 48 + min(16, max(0, width - 162)))
        // watchOS owns the clock position. Align our content to its baseline by
        // moving the custom row down inside a slightly taller protected header.
        .padding(.top, 15)
        .padding(.bottom, 3)
        .frame(height: headerHeight)
        .background(.ultraThinMaterial)
    }

    private var modeText: String {
        game.mode == .versusAI ? "AI · \(game.difficulty.rawValue)" : "双人对战"
    }

    private var headerStatusText: String {
        game.isFinished ? game.resultText : game.playerName
    }

    private func requestExit() {
        if game.isFinished {
            game.returnToModeSelection()
        } else {
            showExitConfirmation = true
        }
    }

    private func resetViewportAppearance() {
        crownValue = 0
        scaleIndex = 0
        game.dismissCrownHint()
        requestBoardFocus(!game.isPaused)
    }

    private func requestBoardFocus(_ shouldFocus: Bool) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            boardFocused = shouldFocus
        }
    }
}

private struct CrownHintBanner: View {
    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "digitalcrown.arrow.counterclockwise")
                Text("表冠缩放 · 拖动棋盘")
            }
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Capsule().fill(.regularMaterial))
            .padding(.bottom, 7)
        }
        .accessibilityHidden(true)
    }
}

private struct PauseOverlay: View {
    let abandon: () -> Void
    let resume: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 240
            ZStack {
                Color.black.opacity(0.42)
                VStack(spacing: compact ? 5 : 8) {
                    Text("😊").font(.system(size: compact ? 20 : 28))
                    Text("对局已暂停")
                        .font(.system(size: compact ? 14 : 16, weight: .bold))
                    Text("继续还是放弃本局？")
                        .font(.system(size: compact ? 10 : 12))
                        .foregroundStyle(.secondary)
                    Button(action: resume) {
                        Label("继续对局", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                            .frame(height: compact ? 30 : 36)
                            .background(Capsule().fill(Color.yellow))
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("pause.resume")
                    Button(role: .destructive, action: abandon) {
                        Label("放弃对局", systemImage: "xmark")
                            .frame(maxWidth: .infinity)
                            .frame(height: compact ? 30 : 36)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("pause.abandon")
                }
                .font(.system(size: compact ? 12 : 14, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(compact ? 10 : 13)
                .frame(width: min(160, geometry.size.width - 24))
                .background(RoundedRectangle(cornerRadius: 22).fill(.regularMaterial))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

private struct IntersectionBoardView: View {
    let board: GomokuBoard
    let preview: BoardPosition?
    let previewStone: Stone
    let lastMovePosition: BoardPosition?
    let winningLine: [BoardPosition]
    let center: BoardPosition
    let visibleLineCount: Int
    let baseSide: CGFloat
    let scale: Double
    let resetID: UUID
    let onInteraction: () -> Void
    let onTap: (BoardPosition) -> Void
    @State private var settledOffset = CGSize.zero
    @State private var dragExceededThreshold = false
    @GestureState private var dragOffset = CGSize.zero

    var body: some View {
        GeometryReader { geometry in
            let visibleCount = min(visibleLineCount, board.size)
            let step = max(1, baseSide) * scale / CGFloat(max(visibleCount - 1, 1))
            // Keep two off-screen grid lines on each edge so dragging still
            // feels continuous without constructing the complete 101x101 UI.
            let lineCount = min(visibleCount + 4, board.size)
            let playableSide = max(1, baseSide) * scale
            let rawOffset = CGSize(
                width: settledOffset.width + dragOffset.width,
                height: settledOffset.height + dragOffset.height
            )
            let offset = clampedOffset(rawOffset, playableSide: playableSide, viewport: geometry.size)
            let layout = BoardViewportLayout(
                boardSize: board.size, center: center, lineCount: lineCount,
                step: step, viewport: geometry.size, offset: offset
            )

            ZStack {
                // The board background reaches the left, right, and bottom
                // edges. Only the enclosing viewport above protects the title.
                Rectangle().fill(Color(red: 0.81, green: 0.57, blue: 0.32))

                IntersectionBoardSurface(
                    board: board, preview: preview, previewStone: previewStone,
                    lastMovePosition: lastMovePosition, winningLine: winningLine,
                    layout: layout, onTap: onTap
                )
                // The rendered grid is visually repetitive. Animating only the
                // reused intersection views makes stones appear to slide across
                // stationary lines when automatic panning changes `center`.
                // Apply the new viewport atomically so every stone stays tied to
                // its logical intersection.
                .transaction { transaction in
                    transaction.animation = nil
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragOffset) { value, state, _ in
                        let moved = hypot(value.translation.width, value.translation.height) >= 8
                        state = scale > 1 && moved ? value.translation : .zero
                    }
                    .onChanged { value in
                        if hypot(value.translation.width, value.translation.height) >= 8 {
                            dragExceededThreshold = true
                        }
                    }
                    .onEnded { value in
                        let isDrag = dragExceededThreshold
                            || hypot(value.translation.width, value.translation.height) >= 8
                        if isDrag && scale > 1 {
                            let proposed = CGSize(
                                width: settledOffset.width + value.translation.width,
                                height: settledOffset.height + value.translation.height
                            )
                            settledOffset = clampedOffset(proposed, playableSide: playableSide, viewport: geometry.size)
                        } else if !isDrag, let position = layout.position(at: value.location) {
                            onTap(position)
                        }
                        dragExceededThreshold = false
                        onInteraction()
                    }
            )
            .onChange(of: scale) { _, _ in
                settledOffset = clampedOffset(
                    settledOffset,
                    playableSide: playableSide,
                    viewport: geometry.size
                )
            }
            .onChange(of: visibleLineCount) { _, _ in
                settledOffset = .zero
            }
            .onChange(of: resetID) { _, _ in
                settledOffset = .zero
            }
        }
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("五子棋棋盘，逻辑范围 \(board.size) 行 \(board.size) 列，当前显示 \(visibleLineCount) 行 \(visibleLineCount) 列")
        .accessibilityValue(
            "格子大小为初始的 \(BoardZoomMetrics.cellScale(surfaceScale: scale, visibleLineCount: visibleLineCount).formatted(.number.precision(.fractionLength(0...1)))) 倍"
        )
        .accessibilityIdentifier("match.board")
    }

    private func clampedOffset(_ offset: CGSize, playableSide: CGFloat, viewport: CGSize) -> CGSize {
        let horizontalLimit = max(0, (playableSide - viewport.width) / 2)
        let verticalLimit = max(0, (playableSide - viewport.height) / 2)
        return CGSize(
            width: min(max(offset.width, -horizontalLimit), horizontalLimit),
            height: min(max(offset.height, -verticalLimit), verticalLimit)
        )
    }
}

private struct IntersectionBoardSurface: View {
    let board: GomokuBoard
    let preview: BoardPosition?
    let previewStone: Stone
    let lastMovePosition: BoardPosition?
    let winningLine: [BoardPosition]
    let layout: BoardViewportLayout
    let onTap: (BoardPosition) -> Void
    @State private var accessibilityCursor = BoardPosition(row: 50, column: 50)

    private var step: CGFloat { layout.step }
    private var diameter: CGFloat { max(step * 0.78, 4) }
    private var accessiblePositions: [BoardPosition] {
        guard layout.usesIndividualAccessibilityTargets else { return [] }
        return board.positions(rows: layout.visibleRows, columns: layout.visibleColumns)
    }

    var body: some View {
        ZStack {
            Canvas { context, _ in
                let first = layout.point(for: BoardPosition(row: layout.rows.lowerBound, column: layout.columns.lowerBound))
                let last = layout.point(for: BoardPosition(row: layout.rows.upperBound - 1, column: layout.columns.upperBound - 1))
                var grid = Path()
                for row in layout.visibleRows {
                    let y = layout.point(for: BoardPosition(row: row, column: layout.columns.lowerBound)).y
                    grid.move(to: CGPoint(x: first.x, y: y))
                    grid.addLine(to: CGPoint(x: last.x, y: y))
                }
                for column in layout.visibleColumns {
                    let x = layout.point(for: BoardPosition(row: layout.rows.lowerBound, column: column)).x
                    grid.move(to: CGPoint(x: x, y: first.y))
                    grid.addLine(to: CGPoint(x: x, y: last.y))
                }
                context.stroke(grid, with: .color(.black.opacity(0.7)), lineWidth: max(0.45, step * 0.05))
                context.stroke(Path(CGRect(x: first.x, y: first.y, width: last.x - first.x, height: last.y - first.y)),
                               with: .color(.black.opacity(0.88)), lineWidth: max(1.2, step * 0.1))
                for (position, stone) in board.stones where layout.isVisible(position) {
                    drawStone(stone, at: position, preview: false, context: &context)
                }
                if let preview, layout.isVisible(preview) {
                    drawStone(previewStone, at: preview, preview: true, context: &context)
                }
                if let first = winningLine.first, let last = winningLine.last {
                    var line = Path()
                    line.move(to: layout.point(for: first))
                    line.addLine(to: layout.point(for: last))
                    context.stroke(line, with: .color(.red),
                                   style: StrokeStyle(lineWidth: max(2, min(5, step * 0.18)), lineCap: .round))
                }
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)

            // The enclosing viewport owns a single touch/drag gesture.
            // These bounded targets serve accessibility, not hit testing.
            ForEach(accessiblePositions, id: \.self) { position in
                Rectangle().fill(Color.black.opacity(0.001))
                    .frame(width: step, height: step)
                    .position(layout.point(for: position))
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityLabel("第 \(position.row + 1) 行，第 \(position.column + 1) 列")
                    .accessibilityIdentifier("board.\(position.row).\(position.column)")
                    .accessibilityValue(accessibilityValue(at: position))
                    .accessibilityHint("操作一次选择，再次操作确认落子")
                    .accessibilityAddTraits(board.stone(at: position) == nil ? .isButton : [])
                    .accessibilityAction { onTap(position) }
            }
            if !layout.usesIndividualAccessibilityTargets {
                // Dense overview remains touchable; VoiceOver uses one movable
                // cursor instead of thousands of tiny accessibility elements.
                Rectangle().fill(Color.black.opacity(0.001))
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityLabel("棋盘光标，第 \(accessibilityCursor.row + 1) 行，第 \(accessibilityCursor.column + 1) 列")
                    .accessibilityValue(accessibilityValue(at: accessibilityCursor))
                    .accessibilityHint("上下轻扫调列，操作菜单可调行或确认落子")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: moveAccessibilityCursor(row: 0, column: 1)
                        case .decrement: moveAccessibilityCursor(row: 0, column: -1)
                        @unknown default: break
                        }
                    }
                    .accessibilityAction(named: Text("上一行")) { moveAccessibilityCursor(row: -1, column: 0) }
                    .accessibilityAction(named: Text("下一行")) { moveAccessibilityCursor(row: 1, column: 0) }
                    .accessibilityAction { onTap(accessibilityCursor) }
            }
            if !winningLine.isEmpty {
                Rectangle().fill(Color.black.opacity(0.001)).frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityIdentifier("match.winningLine")
                    .accessibilityLabel("五连红线")
            }
        }
        .frame(width: layout.viewport.width, height: layout.viewport.height)
        .clipped()
    }

    private func moveAccessibilityCursor(row: Int, column: Int) {
        accessibilityCursor = BoardPosition(
            row: min(max(accessibilityCursor.row + row, layout.rows.lowerBound), layout.rows.upperBound - 1),
            column: min(max(accessibilityCursor.column + column, layout.columns.lowerBound), layout.columns.upperBound - 1)
        )
    }

    private func drawStone(_ stone: Stone, at position: BoardPosition, preview: Bool, context: inout GraphicsContext) {
        let point = layout.point(for: position)
        let rect = CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2, width: diameter, height: diameter)
        let circle = Path(ellipseIn: rect)
        let color: Color = stone == .black ? .black : .white
        if !preview {
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.35), radius: 1.2, x: 0, y: 0.7))
                layer.fill(circle, with: .color(color))
            }
        } else {
            context.fill(circle, with: .color(color.opacity(stone == .black ? 0.42 : 0.68)))
        }
        context.stroke(circle, with: .color(preview ? .accentColor : .black.opacity(0.45)), lineWidth: preview ? 1.1 : 0.6)
        if !preview, lastMovePosition == position {
            let dot = max(2, min(4, diameter * 0.25))
            context.fill(Path(ellipseIn: CGRect(x: point.x - dot / 2, y: point.y - dot / 2, width: dot, height: dot)), with: .color(.red))
        }
    }

    private func accessibilityValue(at position: BoardPosition) -> String {
        if let stone = board.stone(at: position) {
            return lastMovePosition == position ? "\(stone.title)，最后落子" : stone.title
        }
        if preview == position { return "已选择 \(previewStone.title)，再次操作确认落子" }
        return "空位"
    }
}
