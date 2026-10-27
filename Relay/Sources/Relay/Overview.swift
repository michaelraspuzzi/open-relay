import SwiftUI

/// Pinch-out overview: every card, scaled down, three columns; scrolls when there are more than fit.
/// Drag a tile to reorder: the others shuffle into place under it, and the carousel follows the new order.
struct GridView: View {
    let model: RelayModel
    let cardSize: CGSize
    let width: CGFloat

    private let columns = 3
    private let spacing: CGFloat = 32
    private let inset: CGFloat = 40
    /// The tile being dragged, where the pointer is, and where on the tile it grabbed.
    @State private var dragging: UUID?
    @State private var pointer: CGPoint = .zero
    @State private var grab: CGSize = .zero

    private var margin: CGFloat { max(60, width * 0.08) }
    private var cell: CGFloat { (width - margin * 2 - spacing * CGFloat(columns - 1)) / CGFloat(columns) }
    private var scale: CGFloat { cell / cardSize.width }
    private var tile: CGSize { CGSize(width: cell, height: cardSize.height * scale) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: spacing), count: columns), spacing: spacing) {
                    ForEach(model.cards) { card in
                        GridCell(card: card, model: model, size: cardSize, scale: scale)
                            .opacity(card.id == dragging ? 0 : 1)
                            .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.space))
                                .onChanged { dragChanged(card, $0) }
                                .onEnded { _ in dragEnded() })
                            .id(card.id)
                    }
                }
                .padding(.horizontal, margin).padding(.vertical, inset)
                .coordinateSpace(.named(Self.space))
                .overlay(alignment: .topLeading) {
                    if let id = dragging, let card = model.cards.first(where: { $0.id == id }) {
                        GridTile(card: card, model: model, size: cardSize, scale: scale)
                            .scaleEffect(1.05)
                            .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
                            .offset(x: pointer.x - grab.width, y: pointer.y - grab.height)
                            .allowsHitTesting(false)
                    }
                }
            }
            .scrollIndicators(.never)
            .onAppear { proxy.scrollTo(model.focusedId, anchor: .center) }
        }
    }

    private static let space = "grid"

    /// Top-left of slot `index`, in the grid's coordinate space.
    private func origin(_ index: Int) -> CGPoint {
        CGPoint(x: margin + CGFloat(index % columns) * (tile.width + spacing),
                y: inset + CGFloat(index / columns) * (tile.height + spacing))
    }

    /// The slot whose cell (plus half the gutter around it) contains `point`.
    private func slot(at point: CGPoint) -> Int {
        let column = Int(((point.x - margin + spacing / 2) / (tile.width + spacing)).rounded(.down))
        let row = Int(((point.y - inset + spacing / 2) / (tile.height + spacing)).rounded(.down))
        return max(row, 0) * columns + min(max(column, 0), columns - 1)
    }

    private func dragChanged(_ card: Card, _ value: DragGesture.Value) {
        if dragging == nil {
            guard let index = model.cards.firstIndex(where: { $0.id == card.id }) else { return }
            let start = origin(index)
            grab = CGSize(width: value.startLocation.x - start.x, height: value.startLocation.y - start.y)
            dragging = card.id
        }
        pointer = value.location
        // Reorder by where the tile's center is, not the pointer, so it feels like moving the card.
        let center = CGPoint(x: pointer.x - grab.width + tile.width / 2, y: pointer.y - grab.height + tile.height / 2)
        model.moveCard(card.id, to: slot(at: center))
    }

    /// Let go: the tile glides into its new slot, then the real cell takes over.
    private func dragEnded() {
        guard let id = dragging, let index = model.cards.firstIndex(where: { $0.id == id }) else { dragging = nil; return }
        let end = origin(index)
        withAnimation(.snappy(duration: 0.2)) {
            pointer = CGPoint(x: end.x + grab.width, y: end.y + grab.height)
        } completion: {
            dragging = nil
        }
        model.save()
    }
}

/// A card scaled down to a grid tile, with the focus ring.
private struct GridTile: View {
    let card: Card
    let model: RelayModel
    let size: CGSize
    let scale: CGFloat

    var body: some View {
        CardPreview(card: card, model: model)
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
            .overlay {
                RoundedRectangle(cornerRadius: 28 * scale, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: card.id == model.focusedId ? 3 : 0)
            }
    }
}

private struct GridCell: View {
    let card: Card
    let model: RelayModel
    let size: CGSize
    let scale: CGFloat
    @State private var hovering = false

    var body: some View {
        GridTile(card: card, model: model, size: size, scale: scale)
            .cardDrop(card, model: model, cornerRadius: 28 * scale, showsLabel: false)
            .scaleEffect(hovering ? 1.02 : 1)
            .animation(.snappy(duration: 0.2), value: hovering)
            .contentShape(.rect)
            .onHover { hovering = $0 }
            .onTapGesture { model.open(card) }
            .contextMenu {
                Button("New \(card.connector.name) card") { model.newCard(like: card) }
                Button("Close card", role: .destructive) { model.close(card) }
            }
    }
}

/// ⌘K: type to jump to a card or start a new one.
struct Palette: View {
    @Bindable var model: RelayModel
    @FocusState private var focused: Bool

    var body: some View {
        let items = model.paletteItems
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Switch to a card or start a new one", text: $model.paletteQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($focused)
                    .onSubmit { model.runPalette() }
                    .onChange(of: model.paletteQuery) { model.paletteIndex = 0 }
                Text("esc").font(.rounded(11, .medium)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18).padding(.vertical, 15)
            Divider().opacity(0.5)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            // Identity is the item, not its position, so rows redraw as the query filters them.
                            VStack(alignment: .leading, spacing: 2) {
                                if index == 0 || items[index - 1].section != item.section {
                                    Text(item.section.title)
                                        .font(.rounded(11, .semibold)).foregroundStyle(.secondary)
                                        .padding(.horizontal, 10).padding(.top, index == 0 ? 2 : 10).padding(.bottom, 2)
                                }
                                PaletteRow(item: item, selected: index == model.paletteIndex)
                                    .onTapGesture { model.paletteIndex = index; model.runPalette() }
                            }
                        }
                        if items.isEmpty {
                            Text("No matches").foregroundStyle(.secondary).padding(.vertical, 24)
                        }
                    }
                    .padding(8)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 380)
                .onChange(of: model.paletteIndex) {
                    if items.indices.contains(model.paletteIndex) { proxy.scrollTo(items[model.paletteIndex].id) }
                }
            }
        }
        .frame(width: 600)
        .glassCard(cornerRadius: 22)
        .onAppear { focused = true }
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            if let connector = Connector.all.first(where: { $0.logo == item.logo }) {
                ConnectorIcon(connector: connector, size: 26)
            } else if item.logo == "night" {
                Image(systemName: "moon.stars.fill").font(.system(size: 16)).foregroundStyle(.indigo).frame(width: 26, height: 26)
            } else {
                Image(systemName: "xmark.square").font(.system(size: 17)).foregroundStyle(.secondary).frame(width: 26, height: 26)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.title).font(.system(size: 13.5, weight: .medium))
                    if item.current {
                        Text("Current").font(.rounded(10.5, .semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1.5)
                            .background(.fill.tertiary, in: .capsule)
                    }
                }
                Text(item.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if selected { Image(systemName: "return").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(selected ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 10, style: .continuous))
        .contentShape(.rect)
    }
}

/// Close / minimize / zoom, drawn like the system's, top-left of the screen.
struct TrafficLights: View {
    let model: RelayModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            light(.init(red: 1, green: 0.37, blue: 0.34), "xmark", help: "Hide Relay") { model.onDismiss() }
            light(.init(red: 1, green: 0.74, blue: 0.18), "minus", help: "Minimize") { model.onMinimize() }
            light(.init(red: 0.16, green: 0.79, blue: 0.25), model.isZoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                  help: model.isZoomed ? "Exit focus" : "Focus on this card") { model.toggleZoom() }
        }
        .onHover { hovering = $0 }
    }

    private func light(_ color: Color, _ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle().fill(color)
                .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                .overlay {
                    Image(systemName: symbol).font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.black.opacity(0.55)).opacity(hovering ? 1 : 0)
                }
                .frame(width: 12, height: 12)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A small glass toast for things like missing permissions.
struct NoticeToast: View {
    let text: String
    var connector: Connector? = nil
    var body: some View {
        HStack(spacing: 10) {
            if let connector { ConnectorIcon(connector: connector, size: 22) }
            else { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange) }
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: 420, alignment: .leading)
        .glassCard(cornerRadius: 16)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// What a grid tile shows: the card's header and its last few messages, without the live thread's
/// scroll view, menus or interactive blocks, so the overview stays cheap with many cards.
private struct CardPreview: View {
    let card: Card
    let model: RelayModel

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(.secondary.opacity(0.35)).frame(width: 36, height: 4).padding(.top, 8)
            CardHeader(card: card, model: model)
            Divider().opacity(0.4)
            VStack(spacing: 10) {
                Spacer(minLength: 0)
                if card.messages.isEmpty { EmptyCard(connector: card.connector) }
                ForEach(card.messages.suffix(6)) { message in
                    if let block = message.block {
                        HStack(spacing: 8) {
                            Image(systemName: block.symbol).foregroundStyle(.secondary)
                            Text(block.title ?? block.subject ?? block.date ?? block.name ?? block.file ?? block.type.capitalized)
                                .font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Spacer()
                        }
                        .padding(12)
                        .background(.fill.quaternary, in: .rect(cornerRadius: 14, style: .continuous))
                    } else if message.note == true {
                        NoteLine(text: message.text)
                    } else {
                        Bubble(message: Message(fromUser: message.fromUser, text: String(message.text.prefix(400))))
                    }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .clipped()
        }
        .glassCard(cornerRadius: 28)
    }
}
