import AppKit
import SwiftUI

/// Meeting Prep's brief: the meeting, who's coming and what you know about each of them, threads that bear on it,
/// and what to cover. Compact in the card; full size (every person, thread and link) when expanded.
struct BriefBlock: View {
    let block: Block
    let model: RelayModel
    var expanded = false

    private var attendees: [Block.Attendee] { block.attendees ?? [] }
    private var threads: [Block.BriefThread] { block.threads ?? [] }
    private var points: [String] { block.points ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 18 : 12) {
            header
            if let summary = block.summary {
                Text(summary).font(.system(size: expanded ? 14.5 : 13)).lineSpacing(2).textSelection(.enabled)
            }
            if !attendees.isEmpty {
                section("People", count: attendees.count) {
                    ForEach(Array(attendees.prefix(expanded ? .max : 4).enumerated()), id: \.offset) { _, person in
                        PersonRow(person: person, expanded: expanded)
                    }
                    more(attendees.count - 4)
                }
            }
            if !points.isEmpty {
                section("To cover", count: nil) {
                    ForEach(Array(points.prefix(expanded ? .max : 4).enumerated()), id: \.offset) { index, point in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(index + 1)").font(.rounded(11, .bold).monospacedDigit()).foregroundStyle(.white)
                                .frame(width: 18, height: 18).background(Color.accentColor.gradient, in: .circle)
                            Text(point).font(.system(size: expanded ? 14 : 12.5)).textSelection(.enabled)
                        }
                    }
                    more(points.count - 4)
                }
            }
            if !threads.isEmpty && (expanded || attendees.count < 4) {
                section("Threads", count: threads.count) {
                    ForEach(Array(threads.prefix(expanded ? .max : 2).enumerated()), id: \.offset) { _, thread in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "envelope").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(thread.subject).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                    if let date = thread.date { Text(date).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1) }
                                }
                                Text(thread.gist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(expanded ? nil : 2)
                            }
                        }
                    }
                    more(threads.count - 2)
                }
            }
            if let links = block.links, !links.isEmpty {
                FlowChips(links: expanded ? links : Array(links.prefix(3)), model: model)
            }
        }
        .padding(expanded ? 0 : 14)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            ConnectorIcon(connector: Connector.find("prep"), size: expanded ? 34 : 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(block.title ?? "Meeting").font(.system(size: expanded ? 18 : 14, weight: .semibold)).lineLimit(2)
                HStack(spacing: 6) {
                    if let when = block.when { Label(when, systemImage: "clock") }
                    if let location = block.location, !location.hasPrefix("http") { Label(location, systemImage: "mappin").lineLimit(1) }
                }
                .font(.system(size: expanded ? 13 : 11.5)).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            }
            Spacer(minLength: 4)
            if let link = joinLink {
                Button { NSWorkspace.shared.open(link) } label: { Label("Join", systemImage: "video.fill").font(.rounded(12, .semibold)) }
                    .buttonStyle(.borderedProminent).controlSize(.small).help(link.absoluteString)
            }
            if !expanded {
                Button { model.openBlock(block) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22).contentShape(.rect)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Open the full brief")
            }
        }
    }

    /// A video link from the event (Meet, Zoom, Teams) gets a Join button.
    private var joinLink: URL? {
        [block.location, block.url].compactMap { $0 }.lazy
            .filter { ["meet.google", "zoom.us", "teams.microsoft", "whereby", "around.co"].contains(where: $0.contains) }
            .compactMap(URL.init(string:)).first
    }

    private func section(_ title: String, count: Int?, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: expanded ? 10 : 7) {
            HStack(spacing: 5) {
                Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).kerning(0.8).foregroundStyle(.secondary)
                if let count, count > 1 { Text("\(count)").font(.rounded(10.5, .semibold)).foregroundStyle(.tertiary) }
            }
            content()
        }
    }

    @ViewBuilder private func more(_ hidden: Int) -> some View {
        if !expanded, hidden > 0 {
            Button("+\(hidden) more") { model.openBlock(block) }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

private struct PersonRow: View {
    let person: Block.Attendee
    let expanded: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Initials(name: person.name, size: expanded ? 34 : 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(person.name).font(.system(size: expanded ? 14 : 13, weight: .semibold)).lineLimit(1)
                    if let role = person.role { Text(role).font(.system(size: expanded ? 12.5 : 11.5)).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer(minLength: 4)
                    SourceTag(source: person.source, link: person.link)
                }
                Text(person.about).font(.system(size: expanded ? 13.5 : 12)).foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 3).textSelection(.enabled)
                if expanded, let email = person.email {
                    Text(email).font(.system(size: 12)).foregroundStyle(.tertiary).textSelection(.enabled)
                }
            }
        }
    }
}

/// Where Meeting Prep learned about someone; web results are marked so you know to double-check them.
private struct SourceTag: View {
    let source: String?
    let link: String?

    var body: some View {
        if let source, source != "none" {
            let web = source == "web"
            let label = HStack(spacing: 3) {
                Image(systemName: web ? "globe" : symbol).font(.system(size: 9, weight: .semibold))
                Text(web ? "Web" : source.capitalized).font(.rounded(10.5, .medium))
            }
            .foregroundStyle(web ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(web ? AnyShapeStyle(.orange.opacity(0.12)) : AnyShapeStyle(.fill.tertiary), in: .capsule)
            if let url = link.flatMap(URL.init(string:)) {
                Button { NSWorkspace.shared.open(url) } label: { label }.buttonStyle(.plain).help(url.absoluteString)
            } else {
                label
            }
        }
    }

    private var symbol: String {
        switch source {
        case "inbox": "envelope"
        case "calendar": "calendar"
        case "slack": "number"
        case "notion": "doc.text"
        default: "info.circle"
        }
    }
}

/// A person's initials on a soft gradient circle.
struct Initials: View {
    let name: String
    var size: CGFloat = 30

    private var letters: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "." }).filter { $0.first?.isLetter == true }
        return String((words.first?.prefix(1) ?? "") + (words.count > 1 ? words.last!.prefix(1) : "")).uppercased()
    }

    private var colors: [Color] {
        let palettes: [[Color]] = [[.blue, .indigo], [.purple, .pink], [.orange, .red], [.teal, .blue], [.green, .teal], [.pink, .orange], [.indigo, .purple]]
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palettes[hash % palettes.count]
    }

    var body: some View {
        Circle().fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Text(letters).font(.rounded(size * 0.38, .bold)).foregroundStyle(.white))
            .frame(width: size, height: size)
    }
}

/// Docs and pages to have open: chips that open the page in Relay.
private struct FlowChips: View {
    let links: [Block.LinkItem]
    let model: RelayModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                Button { model.openBlock(Block(type: "link", title: link.title, url: link.url)) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text").font(.system(size: 10.5))
                        Text(link.title).lineLimit(1)
                    }
                    .font(.rounded(12, .medium))
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.fill.tertiary, in: .capsule)
                }
                .buttonStyle(.plain)
                .help(link.url)
            }
        }
    }
}
