import SwiftUI

/// A to-do list you tick off and edit in place: inline in the thread (with an open button), or full size in PageOverlay.
/// Return adds a to-do below; an empty to-do goes away when you leave it; the grip on a row's right drags it up or down.
struct ChecklistEditor: View {
    let id: UUID
    let model: RelayModel
    var expanded = false

    private enum Field: Hashable { case title, item(Int) }
    @FocusState private var field: Field?
    /// Rows' frames in the list, and the row being dragged (its index, which follows it as it moves).
    @State private var frames: [Int: CGRect] = [:]
    @State private var dragging: Int?
    @State private var hovered: Int?
    private static let space = "checklist"

    private var block: Block { model.draft(id) ?? Block(type: "checklist") }
    private var items: [Block.Item] { block.items ?? [] }

    private func edit(_ change: (inout [Block.Item]) -> Void) {
        model.editDraft(id) { block in
            var items = block.items ?? []
            change(&items)
            block.items = items
        }
    }

    private var title: Binding<String> {
        Binding(get: { block.title ?? "" }, set: { value in model.editDraft(id) { $0.title = value } })
    }

    private func text(_ index: Int) -> Binding<String> {
        Binding(get: { items.indices.contains(index) ? items[index].text : "" },
                set: { value in edit { if $0.indices.contains(index) { $0[index].text = value } } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 12 : 8) {
            HStack(alignment: .firstTextBaseline) {
                TextField("Title", text: title, axis: .vertical)
                    .focused($field, equals: .title)
                    .font(.system(size: expanded ? 20 : 13.5, weight: .semibold))
                    .onSubmit { insert(at: 0) }
                if !expanded {
                    Button { model.openBlock(block, messageId: id) } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22).contentShape(.rect)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Open")
                }
            }
            ForEach(items.indices, id: \.self) { index in
                row(index)
                    .padding(.vertical, 2).padding(.horizontal, 6)
                    .background(dragging == index ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8, style: .continuous))
                    .padding(.vertical, -2).padding(.horizontal, -6)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames[index] = $0 }
                    .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
            }
            Button { insert(at: items.count) } label: {
                Label("Add a to-do", systemImage: "plus").font(.system(size: expanded ? 14 : 12.5))
            }
            .buttonStyle(.plain).foregroundStyle(.tertiary)
        }
        .textFieldStyle(.plain)
        .coordinateSpace(.named(Self.space))
        .padding(expanded ? 0 : 14)
        .onChange(of: field) { old, new in
            model.editingDraft = new != nil
            // Leaving an empty to-do removes it.
            if case .item(let index)? = old, old != new, items.indices.contains(index),
               items[index].text.trimmingCharacters(in: .whitespaces).isEmpty {
                edit { $0.remove(at: index) }
                if case .item(let next)? = new, next > index { field = .item(next - 1) }
            }
        }
        .onDisappear { if field != nil { model.editingDraft = false } }
    }

    private func row(_ index: Int) -> some View {
        // A closing card empties `items` before SwiftUI drops the old rows; don't index past the end.
        let done = items.indices.contains(index) && items[index].done
        return HStack(alignment: .firstTextBaseline, spacing: expanded ? 10 : 8) {
            Button { toggle(index) } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: expanded ? 17 : 14))
                    .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(done ? "Mark not done" : "Mark done")
            // A done to-do reads struck through and gray; clicking it falls through to the field to edit.
            let struck = done && field != .item(index)
            TextField("To-do", text: text(index), axis: .vertical)
                .focused($field, equals: .item(index))
                .font(.system(size: expanded ? 15 : 13))
                .opacity(struck ? 0 : 1)
                .overlay(alignment: .topLeading) {
                    if struck {
                        Text(items[index].text).font(.system(size: expanded ? 15 : 13))
                            .strikethrough(color: .secondary).foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                    }
                }
                .onSubmit {
                    // Return on an empty to-do ends the list instead of adding another blank one.
                    if items.indices.contains(index), items[index].text.trimmingCharacters(in: .whitespaces).isEmpty { field = nil }
                    else { insert(at: index + 1) }
                }
            grip(index)
        }
        .contextMenu {
            Button(done ? "Mark Not Done" : "Mark Done") { toggle(index) }
            Button("Delete", role: .destructive) { edit { if $0.indices.contains(index) { $0.remove(at: index) } } }
        }
    }

    /// Shown on hover: drag it and the row swaps places with the ones it passes.
    private func grip(_ index: Int) -> some View {
        Image(systemName: "line.3.horizontal").font(.system(size: expanded ? 13 : 11, weight: .medium))
            .foregroundStyle(.tertiary)
            .frame(width: 18, height: 18).contentShape(.rect)
            .opacity(hovered == index || dragging == index ? 1 : 0)
            .pointerStyle(.grabIdle)
            .help("Drag to reorder")
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
                .onChanged { value in
                    if dragging == nil { field = nil; dragging = index }
                    guard let from = dragging,
                          let to = frames.filter({ $0.key < items.count && $0.value.minY <= value.location.y }).map(\.key).max()
                            ?? (value.location.y < (frames[0]?.minY ?? 0) ? 0 : nil),
                          to != from else { return }
                    edit { $0.insert($0.remove(at: from), at: to) }
                    dragging = to
                }
                .onEnded { _ in withAnimation(.snappy(duration: 0.2)) { dragging = nil } })
    }

    private func toggle(_ index: Int) {
        withAnimation(.snappy(duration: 0.2)) { edit { if $0.indices.contains(index) { $0[index].done.toggle() } } }
    }

    private func insert(at index: Int) {
        edit { $0.insert(.init(text: "", done: false), at: min(index, $0.count)) }
        Task { @MainActor in field = .item(index) }
    }
}
