import SwiftUI

/// One glass card per screen: swipe sideways between cards, scroll inside one, zoom out to see them all.
struct RootView: View {
    let link: MacLink
    @State private var currentID: String?
    @State private var progress: CGFloat = 0
    @State private var showAll = false
    @State private var showNew = false
    @State private var drafts: [String: String] = [:]
    @FocusState private var typing: Bool

    private var current: MCard? { link.cards.first { $0.id == currentID } ?? link.cards.first }

    var body: some View {
        ZStack {
            Wallpaper()
            VStack(spacing: 0) {
                TopBar(cards: link.cards, progress: progress, compact: typing, state: link.state, demo: link.demo) {
                    typing = false
                    withAnimation(.smooth(duration: 0.35)) { showAll = true }
                }
                if link.cards.isEmpty { empty } else { pager }
                if !link.cards.isEmpty { composer }
            }
            .opacity(showAll ? 0 : 1)
            .scaleEffect(showAll ? 0.92 : 1)
            .allowsHitTesting(!showAll)

            if showAll {
                Overview(link: link, current: currentID) { id in
                    if let id { currentID = id }
                    withAnimation(.smooth(duration: 0.35)) { showAll = false }
                } onNew: { showNew = true }
                .transition(.scale(scale: 1.06).combined(with: .opacity))
            }

            if let notice = link.notice { banner(notice) }
        }
        .sheet(isPresented: $showNew) { NewCardSheet(link: link) }
        .onChange(of: link.cards.map(\.id)) { _, ids in
            if currentID == nil || !ids.contains(currentID ?? "") { currentID = ids.first }
        }
        .onAppear { currentID = currentID ?? link.cards.first?.id }
    }

    // MARK: Pager

    private var pager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 10) {
                ForEach(link.cards) { card in
                    CardPane(card: card, link: link, typing: typing,
                             onChip: { text in drafts[card.id] = text; typing = true },
                             onNew: { showNew = true },
                             onHeader: { typing = false })
                        .containerRelativeFrame(.horizontal)
                        .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                            content
                                .scaleEffect(1 - min(abs(phase.value), 1) * 0.05)
                                .opacity(1 - min(abs(phase.value), 1) * 0.22)
                        }
                        .id(card.id)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, 22, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
        .scrollIndicators(.hidden)
        .scrollPosition(id: $currentID)
        // The top bar follows the finger, not the page change: titles and dots read this every frame.
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            // containerSize is already inside the 22pt margins, so one page is a card plus the 10pt gap.
            let step = geometry.containerSize.width + 10
            return step > 0 ? (geometry.contentOffset.x + geometry.contentInsets.leading) / step : 0
        } action: { _, value in
            progress = value
        }
        .sensoryFeedback(.selection, trigger: currentID)
        .padding(.bottom, 10)
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Spacer()
            switch link.state {
            case .connected:
                Text("No cards open on \(link.macName.isEmpty ? "your Mac" : link.macName)").font(.title3.weight(.semibold))
                Text("Start one here and it opens on the Mac too.").foregroundStyle(.white.opacity(0.7))
                Button("New card") { showNew = true }.buttonStyle(.glassProminent).controlSize(.large)
            case .offline(let reason):
                Text("Not connected").font(.title3.weight(.semibold))
                Text(reason).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center).padding(.horizontal, 32)
                Button("Try again") { link.resume() }.buttonStyle(.glass).controlSize(.large)
            default:
                ProgressView().tint(.white).controlSize(.large)
                Text("Connecting to \(link.pairing?.name ?? "your Mac")…").foregroundStyle(.white.opacity(0.8))
            }
            Spacer()
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
    }

    // MARK: Composer

    private var draft: Binding<String> {
        Binding(get: { drafts[current?.id ?? ""] ?? "" }, set: { drafts[current?.id ?? ""] = $0 })
    }

    private var composer: some View {
        let card = current
        let hasText = !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(spacing: 8) {
            // The card's suggestions ride above the keyboard, like QuickType.
            if typing, let card, !card.suggestions.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(card.suggestions, id: \.self) { text in
                            Button(text) { drafts[card.id] = text }
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .glassEffect(.regular.interactive(), in: .capsule)
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .scrollIndicators(.hidden)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    typing = false
                    withAnimation(.smooth(duration: 0.35)) { showAll = true }
                } label: {
                    HStack(spacing: 6) {
                        Logo(connector: card?.connector ?? "", size: 22)
                        Text(card?.name ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                    .padding(.leading, 6).padding(.trailing, 10).padding(.vertical, 6)
                    .background(.white.opacity(0.12), in: .capsule)
                    .contentTransition(.opacity)
                }
                .accessibilityLabel("Switch card, now \(card?.name ?? "")")
                .padding(.bottom, 3)

                TextField("Ask \(card?.name ?? "")", text: draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($typing)
                    .padding(.vertical, 9)

                Button {
                    guard let card else { return }
                    if hasText {
                        link.send(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines), to: card)
                        drafts[card.id] = ""
                    } else if card.running {
                        link.interrupt(card)
                    } else {
                        typing = true
                    }
                } label: {
                    Image(systemName: !hasText && card?.running == true ? "stop.fill" : "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 40, height: 40)
                        .background(.white.opacity(hasText || card?.running == true ? 1 : 0.35), in: .circle)
                        .foregroundStyle(.black)
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(hasText ? "Send" : card?.running == true ? "Stop" : "Write a message")
                .sensoryFeedback(.impact(weight: .light), trigger: card?.messages.count)
            }
            .foregroundStyle(.white)
            .padding(7)
            .glassEffect(.regular, in: .rect(cornerRadius: 27, style: .continuous))
            .padding(.horizontal, 14)
        }
        .padding(.bottom, typing ? 6 : 2)
        .animation(.smooth(duration: 0.3), value: typing)
    }

    private func banner(_ text: String) -> some View {
        VStack {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
                .padding(.horizontal, 14)
                .onTapGesture { link.notice = nil }
                .task(id: text) {
                    try? await Task.sleep(for: .seconds(4))
                    withAnimation { link.notice = nil }
                }
            Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: Top bar

/// The current card's name crossfades and slides with the swipe; one pill glides along the dots.
struct TopBar: View {
    let cards: [MCard]
    let progress: CGFloat
    let compact: Bool
    let state: MacLink.State
    let demo: Bool
    let onGrid: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .leading) {
                    ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                        let distance = CGFloat(index) - progress
                        HStack(spacing: 8) {
                            Text(card.name)
                            if card.needsYou {
                                Circle().fill(.orange).frame(width: 8, height: 8)
                                    .accessibilityLabel("needs you")
                            }
                        }
                        .font(.system(size: compact ? 17 : 26, weight: .bold))
                        .lineLimit(1)
                        .offset(x: distance * 70)
                        .opacity(max(0, 1 - abs(distance) * 1.6))
                        .accessibilityHidden(abs(distance) > 0.5)
                    }
                    if cards.isEmpty { Text("Relay").font(.system(size: compact ? 17 : 26, weight: .bold)) }
                }
                .frame(height: compact ? 22 : 32, alignment: .leading)

                HStack(spacing: 6) {
                    ZStack(alignment: .leading) {
                        HStack(spacing: 5) {
                            ForEach(cards) { card in
                                Circle().fill(card.needsYou ? Color.orange : .white.opacity(0.35)).frame(width: 5, height: 5)
                            }
                        }
                        if !cards.isEmpty {
                            Capsule().fill(.white).frame(width: 5, height: 5)
                                .offset(x: min(max(progress, 0), CGFloat(cards.count - 1)) * 10)
                        }
                    }
                    connection
                }
            }
            .foregroundStyle(.white)
            .shadow(color: Color(red: 0, green: 0.15, blue: 0.45).opacity(0.25), radius: 10)
            .animation(.smooth(duration: 0.3), value: compact)

            Spacer(minLength: 0)

            Button(action: onGrid) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 40, height: 40)
            }
            .foregroundStyle(.white)
            .glassEffect(.regular.interactive(), in: .circle)
            .opacity(compact ? 0 : 1)
            .accessibilityLabel("All cards")
        }
        .padding(.leading, 24).padding(.trailing, 18)
        .padding(.top, 4).padding(.bottom, 12)
    }

    @ViewBuilder
    private var connection: some View {
        switch state {
        case .connecting:
            Text("Connecting…").font(.caption2.weight(.medium)).foregroundStyle(.white.opacity(0.75))
        case .offline:
            Text("Offline").font(.caption2.weight(.medium)).foregroundStyle(.orange)
        case .connected where demo:
            Text("Demo").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                .background(.white.opacity(0.2), in: .capsule)
        default:
            EmptyView()
        }
    }
}
