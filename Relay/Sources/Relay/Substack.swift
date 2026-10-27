import AppKit
import SwiftUI
import WebKit

/// Your Substack session. You sign in once in a Relay page (WebKit's default store keeps the cookie across launches),
/// and the sidecar calls Substack's API with that session. Relay watches the store, so signing in or out takes effect at once.
@MainActor @Observable
final class SubstackAccount: NSObject, WKHTTPCookieStoreObserver {
    static let shared = SubstackAccount()
    static let signInURL = "https://substack.com/sign-in"

    /// Set by the sidecar once Substack accepts the session.
    var signedIn = false
    var name = ""
    var publications: [String] = []
    /// Gets the session's Cookie header whenever it changes ("" when signed out).
    var onCookie: ((String) -> Void)?

    private var sent: String?
    private var store: WKHTTPCookieStore { WKWebsiteDataStore.default().httpCookieStore }
    /// Only the session cookies: analytics cookies change on every page and would re-check the account each time.
    private static let names: Set<String> = ["substack.sid", "connect.sid"]

    func start() {
        store.add(self)
        refresh()
    }

    /// The sidecar restarted: hand it the session again.
    func resend() {
        sent = nil
        refresh()
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in self.refresh() }
    }

    func refresh() {
        Task {
            let cookies = await store.allCookies().filter { Self.names.contains($0.name) && Self.isSubstack($0.domain) }
            let header = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            guard header != sent else { return }
            sent = header
            if header.isEmpty { signedIn = false; name = ""; publications = [] }
            onCookie?(header)
        }
    }

    func signOut() {
        Task {
            for cookie in await store.allCookies() where Self.isSubstack(cookie.domain) { await store.deleteCookie(cookie) }
            refresh()
        }
    }

    private static func isSubstack(_ domain: String) -> Bool {
        let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return bare == "substack.com" || bare.hasSuffix(".substack.com")
    }
}

/// The Substack card's strip: who you're signed in as and your publications, or a Sign in button.
struct SubstackStrip: View {
    let model: RelayModel
    private var account: SubstackAccount { SubstackAccount.shared }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(account.signedIn ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
            if account.signedIn {
                Text(account.name.isEmpty ? "Signed in" : account.name).font(.rounded(12, .semibold))
                Text(account.publications.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("Not signed in to Substack").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if !account.signedIn {
                Button("Sign in") { model.signInToSubstack() }.buttonStyle(.borderedProminent).tint(.substack).controlSize(.small)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .contentShape(.rect)
        .contextMenu {
            Button("Sign In…") { model.signInToSubstack() }
            Button("Open Sign-in Link from Clipboard") { model.openSubstackLinkFromClipboard() }
                .help("Substack emailed you a sign-in link: copy it, then open it here so Relay gets the session")
            if account.signedIn { Divider(); Button("Sign Out", role: .destructive) { account.signOut() } }
        }
        .help(account.signedIn ? "Right-click to sign out" : "Sign in once; Relay stays signed in")
    }
}

extension Color {
    static let substack = Color(red: 1, green: 0.404, blue: 0.098)
}

/// A Substack draft you edit in place: the agent writes or revises it, Save to Substack puts it in that publication's
/// drafts (a new one, or over the draft it came from), and Open in Substack shows it in Substack's own editor to publish.
struct SubstackEditor: View {
    let id: UUID
    let model: RelayModel
    var expanded = false

    @FocusState private var editing: Bool

    private var block: Block { model.draft(id) ?? Block(type: "substack") }
    private var saving: Bool { model.mailWork[id] != nil }
    private var words: Int { (block.body ?? "").split { $0.isWhitespace }.count }

    /// Any edit makes a saved draft unsaved again.
    private func field(_ key: WritableKeyPath<Block, String?>) -> Binding<String> {
        Binding(get: { block[keyPath: key] ?? "" }, set: { value in
            model.editDraft(id) { $0[keyPath: key] = value; if $0.status == "saved" { $0.status = "draft" } }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 12 : 8) {
            HStack(spacing: 8) {
                Text("SUBSTACK DRAFT").font(.system(size: 10.5, weight: .semibold)).kerning(0.8).foregroundStyle(.secondary)
                if let pub = block.channel, !pub.isEmpty { pill(pub, .substack) }
                statusPill
                Spacer()
                if !expanded {
                    Button { model.openBlock(block, messageId: id) } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22).contentShape(.rect)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Open")
                }
            }
            TextField("Title", text: field(\.title), axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: expanded ? 24 : 17, weight: .bold)).focused($editing)
            TextField("Subtitle", text: field(\.subtitle), axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: expanded ? 16 : 13)).foregroundStyle(.secondary).focused($editing)
            TextEditor(text: field(\.body))
                .focused($editing)
                .font(.system(size: expanded ? 15 : 13))
                .lineSpacing(expanded ? 4 : 2)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, -5)
                .frame(minHeight: expanded ? 360 : 120, maxHeight: expanded ? .infinity : 280)
            Text("\(words) words · Markdown").font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.tertiary)
            ForEach(Array((block.notes ?? []).enumerated()), id: \.offset) { _, note in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•").foregroundStyle(.tertiary)
                    Text(note).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .font(.system(size: expanded ? 13 : 12))
            }
            actions
        }
        .padding(expanded ? 0 : 14)
        .onChange(of: editing) { model.editingDraft = editing }
        .onDisappear { if editing { model.editingDraft = false } }
    }

    @ViewBuilder private var statusPill: some View {
        if block.status == "saved" { pill("Saved", .green) }
        else if block.postId != nil { pill("Unsaved changes", .orange) }
        else { pill("New", .secondary) }
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 10.5, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.12), in: .capsule)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(block.plainText, forType: .string)
            }
            .buttonStyle(.bordered)
            Spacer()
            if let url = block.url {
                Button { model.openSubstackEditor(url, title: block.title) } label: { Label("Open in Substack", systemImage: "arrow.up.forward.app") }
                    .buttonStyle(.bordered)
                    .help("Substack's editor, in Relay: preview, add images and publish there")
            }
            Button { model.saveSubstack(id) } label: {
                HStack(spacing: 5) {
                    if saving { ProgressView().controlSize(.mini) }
                    Text(block.postId == nil ? "Save to Substack" : "Save changes")
                }
            }
            .buttonStyle(.borderedProminent).tint(.substack)
            .disabled(saving || block.status == "saved" || (block.title ?? "").isEmpty || (block.body ?? "").isEmpty)
            .help(block.postId == nil ? "Adds it to \(block.channel ?? "the publication")'s drafts; nothing is published" : "Saves over the draft in Substack; nothing is published")
        }
        .controlSize(expanded ? .regular : .small)
    }
}

extension RelayModel {
    /// Substack's sign-in page in Relay's own browser, which keeps you signed in.
    func signInToSubstack() {
        openBlock(Block(type: "link", title: "Sign in to Substack", url: SubstackAccount.signInURL))
    }

    /// Substack's emailed sign-in link opens in your default browser; opened here instead, Relay gets the session.
    func openSubstackLinkFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text), url.host?.hasSuffix("substack.com") == true else {
            show("Copy the sign-in link from Substack's email first")
            return
        }
        openBlock(Block(type: "link", title: "Sign in to Substack", url: url.absoluteString))
    }

    func openSubstackEditor(_ url: String, title: String?) {
        openBlock(Block(type: "link", title: title ?? "Substack", url: url))
    }

    /// Save to Substack: the draft exactly as edited, into its publication's drafts. Never publishes.
    func saveSubstack(_ id: UUID) {
        guard mailWork[id] == nil, let (card, index) = locate(id), let block = card.messages[index].block else { return }
        guard let publication = block.publication else { show("This draft doesn't say which publication it's for"); return }
        withAnimation(.smooth(duration: 0.2)) { mailWork[id] = "substack" }
        var command: [String: Any] = [
            "op": "substack", "cardId": card.id.uuidString, "draftId": id.uuidString, "publication": publication,
            "title": block.title ?? "", "subtitle": block.subtitle ?? "", "body": block.body ?? "",
        ]
        command["postId"] = block.postId
        command["synced"] = block.synced
        bridge.send(command)
    }

    func substackSaved(_ card: Card, _ event: [String: Any]) {
        guard let id = (event["draftId"] as? String).flatMap(UUID.init) else { return }
        withAnimation(.smooth(duration: 0.2)) { mailWork[id] = nil }
        guard event["ok"] as? Bool == true else {
            show("Couldn't save to Substack — \(event["error"] as? String ?? "unknown error")")
            return
        }
        guard let index = card.messages.firstIndex(where: { $0.id == id }), var block = card.messages[index].block else { return }
        let pub = event["pub"] as? String ?? block.channel ?? "Substack"
        let first = block.postId == nil
        block.postId = event["postId"] as? Int ?? block.postId
        block.url = event["url"] as? String ?? block.url
        block.synced = event["updated"] as? String
        block.status = "saved"
        card.pendingContext.append("I saved the Substack draft “\(block.title ?? "")” to \(pub) from Relay, as edited (draft id \(block.postId.map(String.init) ?? "?"))")
        show(first ? "Added to \(pub) drafts" : "Saved to \(pub)", from: card.connector)
        withAnimation(.smooth(duration: 0.3)) { card.messages[index].block = block }
        save()
    }

    func substackAccount(_ event: [String: Any]) {
        let account = SubstackAccount.shared
        let wasIn = account.signedIn
        account.signedIn = event["signedIn"] as? Bool == true
        account.name = event["name"] as? String ?? ""
        account.publications = event["pubs"] as? [String] ?? []
        if let error = event["error"] as? String { show("Substack: \(error)") }
        // Signed in from the sign-in page: close it and say so.
        if account.signedIn && !wasIn {
            if page?.type == "link", page?.title == "Sign in to Substack" { closePage() }
            show("Signed in to Substack as \(account.name)", from: Connector.find("substack"))
        }
    }
}
