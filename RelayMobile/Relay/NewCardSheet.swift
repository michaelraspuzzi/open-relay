import SwiftUI

/// Start a card on the Mac from the phone: pick a connector, and for Claude Code a repo and a worktree.
struct NewCardSheet: View {
    let link: MacLink
    @Environment(\.dismiss) private var dismiss
    @State private var connector: MConnector?
    @State private var folder: String?
    @State private var worktree = true
    @State private var text = ""
    @FocusState private var focused: Bool

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(link.connectors) { item in
                            Button { withAnimation(.snappy) { connector = item } } label: {
                                VStack(spacing: 8) {
                                    Logo(connector: item.id, size: 36, symbol: item.symbol)
                                    Text(item.name).font(.caption.weight(.medium)).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 14)
                                .background(.white.opacity(connector == item ? 0.18 : 0.06), in: .rect(cornerRadius: 16, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(.white.opacity(connector == item ? 0.6 : 0), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if connector?.code == true {
                        VStack(spacing: 0) {
                            Picker("Repo", selection: Binding(get: { folder ?? link.folders.first?.path ?? "" }, set: { folder = $0 })) {
                                ForEach(link.folders) { Text($0.name).tag($0.path) }
                            }
                            .pickerStyle(.navigationLink)
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            Divider().padding(.leading, 14)
                            Toggle("Run in its own worktree", isOn: $worktree).padding(.horizontal, 14).padding(.vertical, 10)
                        }
                        .background(.white.opacity(0.06), in: .rect(cornerRadius: 16, style: .continuous))
                        Text("A worktree gives this card its own branch, so it can't collide with other cards working in the same repo.")
                            .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
                    }

                    TextField(connector.map { "What should \($0.name) do?" } ?? "Pick a card type first", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($focused)
                        .padding(14)
                        .background(.white.opacity(0.06), in: .rect(cornerRadius: 16, style: .continuous))
                }
                .padding(18)
            }
            .navigationTitle("New card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(text.isEmpty ? "Open" : "Start") {
                        guard let connector else { return }
                        link.newCard(connector, folder: connector.code ? (folder ?? link.folders.first?.path) : nil,
                                     worktree: connector.code && worktree, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(connector == nil)
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(.thinMaterial)
        .onAppear { connector = connector ?? link.connectors.first }
    }
}
