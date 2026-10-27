import SwiftUI

/// An email draft you can edit in place: inline in the thread (with an expand button), or full size in DraftsOverlay.
struct DraftEditor: View {
    let id: UUID
    let model: RelayModel
    var expanded = false

    private enum Field { case to, subject, body }
    @FocusState private var field: Field?

    private var block: Block { model.draft(id) ?? Block(type: "email") }
    private var working: String? { model.mailWork[id] }
    /// Sending (or waiting out the undo window): the text is locked, Undo stays live.
    private var locked: Bool { working != nil || model.heldSend(for: id) != nil }

    private func binding(_ key: WritableKeyPath<Block, String?>) -> Binding<String> {
        Binding(get: { block[keyPath: key] ?? "" }, set: { value in model.editDraft(id) { $0[keyPath: key] = value } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !expanded {
                HStack {
                    Text("DRAFT").font(.system(size: 10.5, weight: .semibold)).kerning(0.8).foregroundStyle(.secondary)
                    if let tag = block.tag { savedTag(tag) }
                    Spacer()
                    Button { model.expandDraft(id) } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22).contentShape(.rect)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Expand")
                }
                .padding(.bottom, 6)
                if let quote = block.replyTo { ReplyQuote(quote: quote).padding(.bottom, 6) }
            }
            row("To") {
                TextField("Recipients", text: binding(\.to)).focused($field, equals: .to).disabled(locked)
            }
            Divider().opacity(0.5)
            row("Subject") {
                TextField("Subject", text: binding(\.subject)).focused($field, equals: .subject).disabled(locked)
                    .font(.system(size: expanded ? 15 : 13.5, weight: .semibold))
            }
            Divider().opacity(0.5)
            TextEditor(text: binding(\.body))
                .focused($field, equals: .body)
                .disabled(locked)
                .font(.system(size: expanded ? 14.5 : 12.5))
                .lineSpacing(expanded ? 3 : 1)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, -5)
                .padding(.top, 8)
                .frame(minHeight: expanded ? 240 : 110, maxHeight: expanded ? .infinity : 180)
            actions.padding(.top, 10)
        }
        .textFieldStyle(.plain)
        .font(.system(size: expanded ? 14 : 12.5))
        .padding(expanded ? 0 : 14)
        .onChange(of: field) { model.editingDraft = field != nil }
        .onDisappear { if field != nil { model.editingDraft = false } }
    }

    private func row(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: expanded ? 62 : 52, alignment: .leading)
            content()
        }
        .padding(.vertical, expanded ? 10 : 7)
    }

    private func savedTag(_ tag: String) -> some View {
        Label(tag, systemImage: "checkmark").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.green)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(.green.opacity(0.12), in: .capsule)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if expanded, let tag = block.tag { savedTag(tag) }
            Spacer()
            Button { model.mail(id, action: "draft") } label: {
                HStack(spacing: 5) {
                    if working == "draft" { ProgressView().controlSize(.mini) }
                    Text("Save draft")
                }
            }
            .buttonStyle(.bordered)
            .disabled(locked)
            .help("Save to Gmail drafts")
            sendButton
        }
        .controlSize(expanded ? .large : .regular)
    }

    @ViewBuilder private var sendButton: some View {
        if let held = model.heldSend(for: id) {
            DraftUndoButton(held: held, model: model)
        } else {
            let button = Button { model.mail(id, action: "send") } label: {
                HStack(spacing: 5) {
                    if working == "send" { ProgressView().controlSize(.mini) } else { Image(systemName: "paperplane.fill") }
                    Text("Send")
                }
            }
            .buttonStyle(.borderedProminent)
            .help(expanded ? "Send (⌘↩), with \(Int(RelayModel.bannerSeconds))s to undo" : "Send, with \(Int(RelayModel.bannerSeconds))s to undo")
            if expanded { button.keyboardShortcut(.return, modifiers: .command) } else { button }
        }
    }
}

/// A Slack message draft you can edit in place, like DraftEditor: the agent picks the channel, and you can change it
/// from your channels (except for a thread reply); the message is yours. Save draft puts it in your Slack Drafts & Sent; Send posts it.
struct SlackDraftEditor: View {
    let id: UUID
    let model: RelayModel
    var expanded = false

    @FocusState private var editing: Bool

    private var block: Block { model.draft(id) ?? Block(type: "slack") }
    private var working: String? { model.mailWork[id] }
    private var locked: Bool { working != nil || model.heldSend(for: id) != nil }
    private var text: Binding<String> {
        Binding(get: { block.body ?? "" }, set: { value in model.editDraft(id) { $0.body = value } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !expanded {
                HStack {
                    Text("SLACK DRAFT").font(.system(size: 10.5, weight: .semibold)).kerning(0.8).foregroundStyle(.secondary)
                    if let tag = block.tag { savedTag(tag) }
                    Spacer()
                    Button { model.expandDraft(id) } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22).contentShape(.rect)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Expand")
                }
                .padding(.bottom, 6)
                if let quote = block.replyTo { ReplyQuote(quote: quote).padding(.bottom, 6) }
            }
            HStack(spacing: 8) {
                Text(block.threadTs == nil ? "In" : "Thread in").foregroundStyle(.secondary)
                    .frame(width: expanded ? 62 : 52, alignment: .leading)
                if block.threadTs == nil {
                    ChannelPicker(id: id, model: model, channel: block.channel, openAtStart: expanded).disabled(locked)
                } else {
                    Text(block.channel ?? "No channel").fontWeight(.medium).lineLimit(1)
                        .help("A thread reply stays in its channel")
                }
                Spacer()
            }
            .padding(.vertical, expanded ? 10 : 7)
            Divider().opacity(0.5)
            TextEditor(text: text)
                .focused($editing)
                .disabled(locked)
                .font(.system(size: expanded ? 14.5 : 12.5))
                .lineSpacing(expanded ? 3 : 1)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, -5)
                .padding(.top, 8)
                .frame(minHeight: expanded ? 240 : 110, maxHeight: expanded ? .infinity : 180)
                .overlay(alignment: .topLeading) {
                    if (block.body ?? "").isEmpty {
                        Text("Message \(block.channel ?? "")").foregroundStyle(.tertiary).padding(.top, 8).allowsHitTesting(false)
                    }
                }
            actions.padding(.top, 10)
        }
        .font(.system(size: expanded ? 14 : 12.5))
        .padding(expanded ? 0 : 14)
        .onChange(of: editing) { model.editingDraft = editing }
        .onDisappear { if editing { model.editingDraft = false } }
    }

    private func savedTag(_ tag: String) -> some View {
        Label(tag, systemImage: "checkmark").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.green)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(.green.opacity(0.12), in: .capsule)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if expanded, let tag = block.tag { savedTag(tag) }
            if block.tag != nil, let url = block.url.flatMap(URL.init(string:)) {
                Link("Open in Slack", destination: url).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.mail(id, action: "draft") } label: {
                HStack(spacing: 5) {
                    if working == "draft" { ProgressView().controlSize(.mini) }
                    Text("Save draft")
                }
            }
            .buttonStyle(.bordered)
            .disabled(locked)
            .help("Save to your Slack drafts")
            sendButton
        }
        .controlSize(expanded ? .large : .regular)
    }

    @ViewBuilder private var sendButton: some View {
        if let held = model.heldSend(for: id) {
            DraftUndoButton(held: held, model: model)
        } else {
            let button = Button { model.mail(id, action: "send") } label: {
                HStack(spacing: 5) {
                    if working == "send" { ProgressView().controlSize(.mini) } else { Image(systemName: "paperplane.fill") }
                    Text("Send")
                }
            }
            .buttonStyle(.borderedProminent)
            .help(expanded ? "Post (⌘↩), with \(Int(RelayModel.bannerSeconds))s to undo" : "Post, with \(Int(RelayModel.bannerSeconds))s to undo")
            if expanded { button.keyboardShortcut(.return, modifiers: .command) } else { button }
        }
    }
}

/// Drafts opened full size, with a tab per unsent draft (like a mail client's compose window).
struct DraftsOverlay: View {
    let model: RelayModel

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.25)).ignoresSafeArea()
                .onTapGesture { model.collapseDrafts() }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button { model.collapseDrafts() } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 12, weight: .semibold))
                            .frame(width: 26, height: 26).contentShape(.rect)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Collapse (Esc)")
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(model.draftTabs, id: \.self) { tab($0) }
                            Button { model.newDraftTab() } label: {
                                Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                                    .frame(width: 28, height: 28).contentShape(.rect)
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("New draft")
                        }
                    }
                    .scrollIndicators(.never)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                Divider().opacity(0.5)
                if let id = model.activeDraft, let draft = model.draft(id) {
                    HStack(alignment: .top, spacing: 26) {
                        if let quote = draft.replyTo {
                            ReplyQuote(quote: quote, expanded: true).frame(width: 330)
                        }
                        if draft.type == "slack" { SlackDraftEditor(id: id, model: model, expanded: true) }
                        else if draft.type == "invite" { InviteEditor(id: id, model: model, expanded: true) }
                        else { DraftEditor(id: id, model: model, expanded: true) }
                    }
                    .id(id)
                    .padding(.horizontal, 30).padding(.top, 10).padding(.bottom, 22)
                    .frame(maxWidth: draft.replyTo == nil ? 900 : 1080)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("No drafts open").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: 1180, maxHeight: .infinity)
            .glassCard(cornerRadius: 24)
            .clipShape(.rect(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 80).padding(.vertical, 50)
        }
    }

    private func tab(_ id: UUID) -> some View {
        let active = id == model.activeDraft
        let draft = model.draft(id)
        let slack = draft?.type == "slack"
        let invite = draft?.type == "invite"
        let subject = (slack ? draft?.channel : invite ? draft?.title : draft?.subject) ?? ""
        let reply = draft?.replyTo != nil
        return HStack(spacing: 6) {
            Image(systemName: reply ? "arrowshape.turn.up.left" : slack ? "number" : invite ? "calendar" : "envelope").font(.system(size: 11)).foregroundStyle(.secondary)
            Text(subject.isEmpty ? (invite ? "New invite" : "New draft") : subject).font(.system(size: 12.5, weight: active ? .semibold : .regular)).lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)
            if model.mailWork[id] != nil { ProgressView().controlSize(.mini) }
            Button { model.closeDraftTab(id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 16, height: 16).contentShape(.rect)
            }
            .buttonStyle(.plain).foregroundStyle(.tertiary).help("Close tab (the draft stays in its card)")
        }
        .contextMenu {
            Button("Close Tab") { model.closeDraftTab(id) }
            Button("Discard Draft", role: .destructive) { model.discardDraft(id) }
        }
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 6)
        .background(active ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 9, style: .continuous))
        .contentShape(.rect)
        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { model.activeDraft = id } }
    }
}

/// A Slack draft's channel: click to pick from your channels (loaded once, then cached), type to filter.
struct ChannelPicker: View {
    let id: UUID
    let model: RelayModel
    let channel: String?
    /// A new full-size draft with no channel yet opens the list right away.
    var openAtStart = false
    @State private var open = false
    @State private var filter = ""
    @FocusState private var searching: Bool

    private var matches: [SlackChannel] {
        let query = filter.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()
        return query.isEmpty ? model.slackChannels : model.slackChannels.filter { $0.name.lowercased().contains(query) }
    }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 4) {
                Text(channel ?? "Choose a channel").fontWeight(.medium).lineLimit(1)
                    .foregroundStyle(channel == nil ? .secondary : .primary)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Change where it goes")
        .onAppear { if channel == nil { model.loadSlackChannels(); open = openAtStart } }
        .popover(isPresented: $open, arrowEdge: .bottom) { list }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a channel", text: $filter).textFieldStyle(.plain).focused($searching)
                    .onSubmit { if let first = matches.first { pick(first) } }
                // Refreshing over a saved list happens quietly; the spinner is only for a first load.
                if model.loadingChannels && model.slackChannels.isEmpty { ProgressView().controlSize(.mini) }
                else {
                    Button { model.loadSlackChannels(force: true) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Reload channels")
                }
            }
            .padding(10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(matches, id: \.id) { item in
                        Button { pick(item) } label: {
                            HStack {
                                Text("#" + item.name).lineLimit(1)
                                Spacer()
                                if "#" + item.name == channel { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                    if matches.isEmpty {
                        Text(model.loadingChannels ? "Loading your channels…" : model.slackChannels.isEmpty ? "No channels yet" : "No match")
                            .foregroundStyle(.secondary).padding(10)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 260)
        }
        .font(.system(size: 13))
        .frame(width: 260)
        .onAppear { model.loadSlackChannels(); searching = true }
    }

    private func pick(_ item: SlackChannel) {
        model.setDraftChannel(id, to: item)
        filter = ""
        open = false
    }
}

/// The email a draft answers: a two-line strip in the card that opens on click, or a full read-only pane when expanded.
struct ReplyQuote: View {
    let quote: Block.Quote
    var expanded = false
    @State private var open = false

    var body: some View {
        if expanded {
            VStack(alignment: .leading, spacing: 10) {
                header
                Divider().opacity(0.5)
                ScrollView {
                    Text(quote.body).font(.system(size: 13.5)).lineSpacing(3).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.automatic)
            }
            .padding(16)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(.fill.quaternary, in: .rect(cornerRadius: 14, style: .continuous))
        } else {
            VStack(alignment: .leading, spacing: 3) {
                header
                // Closed, blank lines fold away so the two lines are the message, not just "Hi …,".
                Text(open ? quote.body : quote.body.split(whereSeparator: \.isNewline).joined(separator: " "))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(open ? nil : 2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) { RoundedRectangle(cornerRadius: 1.5).fill(.secondary.opacity(0.4)).frame(width: 3) }
            .contentShape(.rect)
            .onTapGesture { withAnimation(.snappy(duration: 0.25)) { open.toggle() } }
            .help(open ? "Collapse" : "Show the whole email")
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrowshape.turn.up.left").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(quote.from).font(.system(size: expanded ? 13 : 11.5, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 4)
            if let date = quote.date {
                Text(date).font(.system(size: expanded ? 12 : 11)).foregroundStyle(.tertiary).lineLimit(1)
            }
            if !expanded {
                Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
        }
    }
}
