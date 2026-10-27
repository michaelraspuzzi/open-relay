import SwiftUI

/// The whole surface: a carousel (or pinch-out grid) of cards with one shared composer underneath.
struct RootView: View {
    let model: RelayModel
    /// Something is dragged over empty space: dropping there goes to the focused card.
    @State private var backgroundTargeted = false

    var body: some View {
        ZStack {
            Backdrop().ignoresSafeArea()
            VStack(spacing: 0) {
                TitleBar(model: model)
                if model.cards.isEmpty { BlankSlate(model: model) } else { content }
            }
            VStack(spacing: 10) {
                if let notice = model.notice { NoticeToast(text: notice, connector: model.noticeConnector) }
                UndoBar(model: model)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, TitleBar.height + 12)
            .zIndex(4)
            VStack(alignment: .trailing, spacing: 10) {
                ForEach(model.toasts) { toast in
                    ToastView(toast: toast).onTapGesture { model.openToast(toast) }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, TitleBar.height + 10).padding(.trailing, 20)
            if let block = model.page {
                PageOverlay(block: block, model: model)
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
                    .zIndex(2)
            }
            if !model.draftTabs.isEmpty {
                DraftsOverlay(model: model)
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
                    .zIndex(3)
            }
            if model.paletteOpen {
                Color.black.opacity(0.12).ignoresSafeArea()
                    .onTapGesture { model.togglePalette() }
                    .transition(.opacity)
                Palette(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 140)
                    .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            }
            WindowSheen().ignoresSafeArea().zIndex(10)
        }
        .clipShape(.rect(cornerRadius: windowCornerRadius, style: .continuous))
        .alert("Saved to Gmail drafts", isPresented: Binding(get: { model.savedDraft != nil }, set: { if !$0 { model.savedDraft = nil } })) {
            Button("Finish in browser") { model.finishSavedDraftInBrowser() }
            Button("Close card") { model.closeSavedDraftCard() }
            Button("Keep editing", role: .cancel) { model.savedDraft = nil }
        } message: {
            Text("Open Gmail here to finish it, or close this card.")
        }
    }

    private var content: some View {
        GeometryReader { geo in
            let narrow = geo.size.width < 1100
            let cardWidth = model.isZoomed || narrow ? geo.size.width * 0.86 : min(860, geo.size.width * 0.58)
            let cardHeight = model.isZoomed ? geo.size.height * 0.78 : min(720, geo.size.height * 0.72)
            VStack(spacing: 0) {
                if model.isGrid {
                    GridView(model: model, cardSize: CGSize(width: min(860, geo.size.width * 0.58), height: min(720, geo.size.height * 0.72)),
                             width: geo.size.width)
                        .transition(.scale(scale: 1.12).combined(with: .opacity))
                } else {
                    Spacer(minLength: 24)
                    Carousel(model: model, cardWidth: cardWidth, cardHeight: cardHeight, width: geo.size.width)
                        .transition(.scale(scale: 0.88).combined(with: .opacity))
                    Spacer(minLength: 24)
                    PageDots(model: model)
                        .opacity(model.dragActive ? 0 : 1)
                        .overlay {
                            if model.dragActive {
                                DropDock(model: model).fixedSize()
                                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                            }
                        }
                        .zIndex(1)
                }
                Composer(model: model)
                    .frame(width: narrow ? geo.size.width * 0.8 : min(660, geo.size.width * 0.5))
                    .padding(.top, 14).padding(.bottom, 36)
            }
            .contentShape(.rect)
            .onDrop(of: Drop.types, isTargeted: $backgroundTargeted) { providers in
                guard let card = model.focused else { return false }
                model.drop(providers, on: card)
                return true
            }
            .onChange(of: backgroundTargeted) { model.setDropTarget("background", backgroundTargeted) }
        }
    }
}

/// Cards laid out around the focused one. Position = (index offset × stride) + the live trackpad drag,
/// so the carousel follows your fingers and springs to the nearest card when you let go.
struct Carousel: View {
    let model: RelayModel
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let width: CGFloat

    private var stride: CGFloat { cardWidth + 28 }

    var body: some View {
        let focus = model.focusedIndex
        ZStack {
            ForEach(Array(model.cards.enumerated()), id: \.element.id) { index, card in
                let x = CGFloat(index - focus) * stride + model.dragOffset
                let distance = min(abs(x) / stride, 1.5)
                if abs(index - focus) <= (model.dragOffset == 0 ? 1 : 2) {   // only what can be on screen
                    CardView(card: card, isFocused: index == focus, model: model)
                        .frame(width: cardWidth, height: cardHeight)
                        .cardDrop(card, model: model)
                        .scaleEffect(1 - 0.07 * min(distance, 1))
                        .opacity(1 - 0.45 * min(distance, 1))
                        .offset(x: x, y: 10 * min(distance, 1))
                        .zIndex(-distance)
                        .onTapGesture { if index != focus { model.jump(to: index) } }
                        .contextMenu {
                            Button("New \(card.connector.name) card") { model.newCard(like: card) }
                            Button("Close card", role: .destructive) { model.close(card) }
                            Button("Close all cards", role: .destructive) { model.closeAll() }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        }
        .frame(width: width, height: cardHeight + 60)
        .onAppear { model.stride = stride }
        .onChange(of: stride) { model.stride = stride }
    }
}

struct PageDots: View {
    let model: RelayModel
    var body: some View {
        HStack(spacing: 7) {
            ForEach(model.cards) { card in
                Circle()
                    .fill(card.id == model.focusedId ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .frame(width: 6, height: 6)
                    .overlay(alignment: .topTrailing) {
                        if card.ask != nil { Circle().fill(.orange).frame(width: 5, height: 5).offset(x: 3, y: -3) }
                    }
            }
        }
        .animation(.smooth, value: model.focusedId)
    }
}

struct Composer: View {
    @Bindable var model: RelayModel
    @FocusState private var focused: Bool
    // The chip's drum: what it shows, what it just turned away from, and how far it has turned.
    @State private var face: ChipFace?
    @State private var lastFace: ChipFace?
    @State private var turns = 0.0
    @State private var turnFrom = -1.0
    @State private var rollDown = false

    private var running: Bool { model.focused?.running ?? false }
    private var recording: Bool { model.dictation.isRecording }
    private var staged: [Attachment] { model.focused?.staged ?? [] }
    private var empty: Bool { model.draft.isEmpty && staged.isEmpty }
    private var symbol: String {
        if running { return "stop.fill" }
        return empty ? "waveform" : "arrow.up"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let card = model.focused, !staged.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(staged) { item in
                            Group {
                                if item.isImage { ImageChip(attachment: item) { model.unstage(item, from: card) } }
                                else { DragChip(symbol: item.symbol, title: item.name) { model.unstage(item, from: card) } }
                            }
                            .transition(.scale(scale: 0.7).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 4).padding(.top, 6).padding(.trailing, 6)
                }
                .scrollIndicators(.never)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        HStack(spacing: 10) {
            // The chip follows the focused card, or the card an "@name " at the start will send to.
            if let shown = face ?? liveFace {
                ChipDrum(turns: turns, from: turnFrom, previous: lastFace, current: shown, down: rollDown) {
                    connectorChip($0.connector, from: $0.source)
                }
                .animation(Self.turn, value: turns)
                .transition(.blurReplace)
                .help(shown.source == nil ? "Type @ to send to another card" : "Sends to \(shown.connector.name) with this card's conversation as context; you stay here")
            }
            TextField(recording ? "Listening…" : "Ask me anything, @ to send to another card", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...8)
                .focused($focused)
                .onSubmit { model.submitDraft() }
                // Shift-Return starts a new line at the cursor; plain Return still sends.
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    NSApp.sendAction(#selector(NSText.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
                    return .handled
                }
            // One fixed-width slot: a field that narrows mid-edit keeps wrapping at its old width and clips the right edge.
            ZStack {
                if recording { RecordingBadge(level: model.dictation.level) { model.toggleDictation() } }
                // Once there's text the main button sends, so the mic moves here: dictation picks up after what's typed.
                else if !empty && !running {
                    Button { model.toggleDictation() } label: {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .background(.fill.tertiary, in: .circle)
                    }
                    .buttonStyle(.plain)
                    .help("Dictate, continuing from what you've typed")
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .frame(width: 30, height: 30)
            Button(action: primaryAction) {
                Image(systemName: symbol)
                    .contentTransition(.symbolEffect(.replace))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(recording && empty ? Color.red.gradient : Color.accentColor.gradient, in: .circle)
                    .symbolEffect(.variableColor.iterative, isActive: recording && empty)
            }
            .buttonStyle(.plain)
            .help(running ? "Stop" : (empty ? "Dictate" : "Send"))
        }
        }
        .animation(.spring(duration: 0.35, bounce: 0.2), value: staged)
        .padding(.leading, 8).padding(.trailing, 8).padding(.vertical, 8)
        .glassCard(cornerRadius: 26)
        .overlay(alignment: .topLeading) {
            if !model.mentionChoices.isEmpty {
                MentionList(model: model)
                    .alignmentGuide(.top) { $0[.bottom] + 10 }
                    .transition(.scale(scale: 0.95, anchor: .bottomLeading).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: model.mentionChoices.map(\.id))
        .animation(.snappy(duration: 0.2), value: model.mentionTarget?.id)
        .onChange(of: model.draft) { if model.mentionIndex >= max(model.mentionChoices.count, 1) { model.mentionIndex = 0 } }
        .animation(Self.turn, value: model.focusedId)
        .animation(.snappy(duration: 0.25), value: recording)
        .onAppear { focused = true; face = liveFace }
        .onChange(of: liveFace) { turnChip(to: liveFace) }
        .onChange(of: model.focusedId) { focused = true }
        .onChange(of: model.paletteOpen) { if !model.paletteOpen { focused = true } }
    }

    /// `from`: the focused card, when an @mention sends elsewhere ("Gmail → Calendar", tinted).
    private func connectorChip(_ connector: Connector, from source: Connector? = nil) -> some View {
        HStack(spacing: 7) {
            if let source {
                ConnectorIcon(connector: source, size: 16).opacity(0.6)
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            }
            ConnectorIcon(connector: connector, size: 20)
            Text(connector.name).font(.rounded(13.5, .medium))
        }
        .padding(.leading, 6).padding(.trailing, 11).padding(.vertical, 6)
        .background(source == nil ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(Color.accentColor.opacity(0.18)), in: .capsule)
        .fixedSize()
    }

    /// The chip's turn; card changes use the same curve so the field slides in step with it.
    static let turn = Animation.smooth(duration: 0.55)

    private var liveFace: ChipFace? {
        guard let card = model.focused else { return nil }
        let target = model.mentionTarget
        return ChipFace(connector: target ?? card.connector, source: target == nil ? nil : card.connector)
    }

    /// One full turn of the drum per change: moving right rolls up, moving left rolls down.
    private func turnChip(to new: ChipFace?) {
        guard let new, let old = face else { face = new; return }
        lastFace = old
        // Moving right brings the new name down from the top; moving left brings it up from the bottom.
        rollDown = new.source != nil || old.source != nil || !model.focusMovedBack
        turnFrom = turns
        withAnimation(Self.turn) {
            face = new
            turns += 1
        }
    }

    private func primaryAction() {
        if running, let card = model.focused { model.interrupt(card) }
        else if empty { model.toggleDictation() }
        else { model.submitDraft() }
    }
}

struct ChipFace: Equatable {
    let connector: Connector
    let source: Connector?
}

/// The composer chip flipping like a card. `turns` animates by one per change: the old face
/// flips away edge-on, then the new one flips in, both solid so the names stay crisp. `down`:
/// the new name comes down from the top (moving right); otherwise it comes up from the bottom.
/// A hidden copy of the new face holds the slot so the field beside it glides to the new width.
struct ChipDrum<Label: View>: View, Animatable {
    var turns: Double
    let from: Double
    let previous: ChipFace?
    let current: ChipFace
    let down: Bool
    @ViewBuilder let label: (ChipFace) -> Label

    nonisolated var animatableData: Double {
        get { turns }
        set { turns = newValue }
    }

    var body: some View {
        let progress = min(max(turns - from, 0), 1)
        let way: Double = down ? 1 : -1
        ZStack(alignment: .leading) {
            label(current).hidden()
            if let previous, progress < 0.5 {
                let half = progress * 2   // 0 → 1 while the old face flips away
                label(previous).modifier(ChipFlip(angle: -way * 90 * half, drop: way * 8 * half))
                    .frame(width: 0, alignment: .leading)
            } else {
                let half = previous == nil ? 1 : progress * 2 - 1   // 0 → 1 while the new face flips in
                label(current).modifier(ChipFlip(angle: way * 90 * (1 - half), drop: -way * 8 * (1 - half)))
                    .frame(width: 0, alignment: .leading)
            }
        }
    }
}

/// One face of the card at `angle` degrees about its horizontal axis (±90 = edge-on), nudged by `drop` points.
struct ChipFlip: ViewModifier {
    let angle: Double
    let drop: Double
    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(angle), axis: (x: 1, y: 0, z: 0), anchor: .center, perspective: 0.6)
            .offset(y: drop)
            .opacity(abs(angle) < 89.5 ? 1 : 0)
    }
}

/// Live mic level while dictating; click to stop listening and keep the text.
struct RecordingBadge: View {
    let level: Float
    let stop: () -> Void
    var body: some View {
        Button(action: stop) {
            // Sized like the mic button it replaces, so the text field beside it never changes width.
            HStack(spacing: 2) {
                ForEach(0..<4) { i in
                    Capsule().fill(.red)
                        .frame(width: 2.5, height: 4 + CGFloat(level) * 14 * [0.6, 1, 0.8, 0.5][i])
                }
            }
            .animation(.linear(duration: 0.08), value: level)
            .frame(width: 30, height: 30)
            .background(.red.opacity(0.12), in: .circle)
        }
        .buttonStyle(.plain)
        .help("Stop dictating")
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}

/// Nothing open: a calm empty state; ⌘K (open automatically) starts something.
struct BlankSlate: View {
    let model: RelayModel
    var body: some View {
        VStack(spacing: 14) {
            if let icon = Assets.appIcon { Image(nsImage: icon).resizable().frame(width: 84, height: 84) }
            Text("Start something").font(.system(size: 22, weight: .semibold))
            Button { model.togglePalette() } label: {
                HStack(spacing: 6) {
                    Text("Open a card").font(.rounded(13.5, .medium))
                    Text("⌘K").font(.rounded(12, .medium)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.fill.tertiary, in: .capsule)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Glass notice, top right: another card just acted on this connector.
struct ToastView: View {
    let toast: CrossToast
    var body: some View {
        HStack(spacing: 12) {
            ConnectorIcon(connector: toast.connector, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title).font(.system(size: 13.5, weight: .semibold))
                Text(toast.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(width: 320)
        .glassCard(cornerRadius: 18)
        .contentShape(.rect)
    }
}
