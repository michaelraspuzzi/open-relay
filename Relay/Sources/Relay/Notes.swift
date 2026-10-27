import SwiftUI

/// A note you write in place, like a to-do list: inline in the thread (with an open button), or full size in PageOverlay.
/// Return in the title moves to the body; the body takes as many lines as you like.
struct NoteEditor: View {
    let id: UUID
    let model: RelayModel
    var expanded = false

    private enum Field: Hashable { case title, body }
    @FocusState private var field: Field?

    private var block: Block { model.draft(id) ?? Block(type: "note") }

    private var title: Binding<String> {
        Binding(get: { block.title ?? "" }, set: { value in model.editDraft(id) { $0.title = value } })
    }

    private var text: Binding<String> {
        Binding(get: { block.body ?? "" }, set: { value in model.editDraft(id) { $0.body = value } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 12 : 6) {
            HStack(alignment: .firstTextBaseline) {
                TextField("Title", text: title, axis: .vertical)
                    .focused($field, equals: .title)
                    .font(.system(size: expanded ? 20 : 13.5, weight: .semibold))
                    .onSubmit { field = .body }
                if !expanded {
                    Button { model.openBlock(block, messageId: id) } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22).contentShape(.rect)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Open")
                }
            }
            TextEditor(text: text)
                .focused($field, equals: .body)
                .font(.system(size: expanded ? 15 : 13))
                .lineSpacing(expanded ? 4 : 2)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, -5)
                .frame(minHeight: expanded ? 320 : inlineHeight, maxHeight: expanded ? .infinity : inlineHeight)
                .overlay(alignment: .topLeading) {
                    if (block.body ?? "").isEmpty {
                        Text("Write your thoughts…").font(.system(size: expanded ? 15 : 13))
                            .foregroundStyle(.tertiary).allowsHitTesting(false)
                    }
                }
        }
        .textFieldStyle(.plain)
        .padding(expanded ? 0 : 14)
        .onChange(of: field) { model.editingDraft = field != nil }
        .onDisappear { if field != nil { model.editingDraft = false } }
    }

    /// Inline, a short note grows with its lines; a long one scrolls inside the card.
    private var inlineHeight: CGFloat {
        let lines = (block.body ?? "").split(separator: "\n", omittingEmptySubsequences: false).count
        return min(max(CGFloat(lines) * 18 + 12, 70), 240)
    }
}

/// A note read-only: in drag previews and when it isn't in a card anymore.
struct NoteBlock: View {
    let block: Block
    var lines = Int.max

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = block.title, !title.isEmpty { Text(title).font(.system(size: 13.5, weight: .semibold)) }
            Text(block.body ?? "").font(.system(size: 13)).lineSpacing(2).lineLimit(lines == .max ? nil : lines)
                .textSelection(.enabled)
        }
        .padding(14)
    }
}
