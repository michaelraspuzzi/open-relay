import MapKit
import SwiftUI

/// Calendar invite drafts: times are kept as local ISO strings ("2026-10-06T14:00:00"), the shape create-event takes.
enum Invite {
    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        // Agents sometimes drop the seconds or add an offset; the first 16 characters are always date and time.
        return iso.date(from: text) ?? iso.date(from: String(text.prefix(16)) + ":00")
    }

    static func string(_ date: Date) -> String { iso.string(from: date) }

    /// "Mon, Oct 6 · 2:00 – 2:30 PM"
    static func when(_ start: String?, _ end: String?) -> String? {
        guard let start = date(start) else { return nil }
        let day = start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        guard let end = date(end) else { return "\(day) · \(start.formatted(date: .omitted, time: .shortened))" }
        let range = Calendar.current.isDate(start, inSameDayAs: end)
            ? (start..<max(end, start)).formatted(.interval.hour().minute())
            : "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
        return "\(day) · \(range)"
    }

    static func guests(_ text: String?) -> [String] {
        (text ?? "").split(whereSeparator: { ",;\n".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func count(_ guests: [String]) -> String { guests.count == 1 ? guests[0] : "\(guests.count) guests" }

    static func holdTitle(_ block: Block) -> String {
        let guests = guests(block.to)
        return guests.isEmpty ? "Adding “\(block.title ?? "")” to your calendar" : "Inviting \(count(guests)) to “\(block.title ?? "")”"
    }

    /// A new invite: the next half hour, for 30 minutes.
    static func blank() -> Block {
        let now = Date.now
        let minute = Calendar.current.component(.minute, from: now)
        let start = Calendar.current.date(byAdding: .minute, value: (minute < 30 ? 30 : 60) - minute, to: now)
            .flatMap { Calendar.current.date(bySetting: .second, value: 0, of: $0) } ?? now
        var block = Block(type: "invite", status: "draft", to: "", body: "")
        block.title = ""
        block.start = string(start)
        block.end = string(start.addingTimeInterval(30 * 60))
        return block
    }
}

/// An invite you can edit in place, like an email draft: title, time, guests, place and notes, then Create invite
/// (held for the undo window, since it sends invitations). Inline in the thread, or full size in DraftsOverlay.
struct InviteEditor: View {
    let id: UUID
    let model: RelayModel
    var expanded = false

    private enum Field { case title, guests, location, notes }
    @FocusState private var field: Field?
    @State private var places = Places()

    private func pick(_ place: Places.Place) {
        places.clear(picked: place.address)
        model.editDraft(id) { $0.location = place.address }
    }

    private var block: Block { model.draft(id) ?? Invite.blank() }
    private var working: String? { model.mailWork[id] }
    private var locked: Bool { working != nil || model.heldSend(for: id) != nil }

    private func binding(_ key: WritableKeyPath<Block, String?>) -> Binding<String> {
        Binding(get: { block[keyPath: key] ?? "" }, set: { value in model.editDraft(id) { $0[keyPath: key] = value } })
    }

    /// Moving the start keeps the length; moving the end changes it (on the start's day).
    private var start: Binding<Date> {
        Binding(get: { Invite.date(block.start) ?? .now }, set: { value in
            model.editDraft(id) {
                let length = (Invite.date($0.end) ?? value).timeIntervalSince(Invite.date($0.start) ?? value)
                $0.start = Invite.string(value)
                $0.end = Invite.string(value.addingTimeInterval(max(length, 15 * 60)))
            }
        })
    }

    private var end: Binding<Date> {
        Binding(get: { Invite.date(block.end) ?? .now }, set: { value in model.editDraft(id) { $0.end = Invite.string(value) } })
    }

    private var meet: Binding<Bool> {
        Binding(get: { block.meet ?? false }, set: { value in model.editDraft(id) { $0.meet = value } })
    }

    private var length: String? {
        guard let start = Invite.date(block.start), let end = Invite.date(block.end), end > start else { return nil }
        let minutes = Int(end.timeIntervalSince(start) / 60)
        return minutes < 60 ? "\(minutes) min" : minutes % 60 == 0 ? "\(minutes / 60) hr" : "\(minutes / 60) hr \(minutes % 60) min"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !expanded {
                HStack {
                    Text("INVITE").font(.system(size: 10.5, weight: .semibold)).kerning(0.8).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.expandDraft(id) } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22).contentShape(.rect)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Expand")
                }
                .padding(.bottom, 6)
            }
            row("Title") {
                TextField("Event title", text: binding(\.title)).focused($field, equals: .title).disabled(locked)
                    .font(.system(size: expanded ? 15 : 13.5, weight: .semibold))
            }
            Divider().opacity(0.5)
            row("When") {
                DayPill(date: start, large: expanded)
                TimePill(date: start, large: expanded)
                Text("–").foregroundStyle(.secondary)
                TimePill(date: end, after: start.wrappedValue, large: expanded)
                if let length { Text(length).font(.system(size: expanded ? 12.5 : 11.5)).foregroundStyle(.tertiary).lineLimit(1) }
                Spacer(minLength: 0)
            }
            .disabled(locked)
            Divider().opacity(0.5)
            row("Guests") {
                TextField("Email addresses, comma-separated", text: binding(\.to)).focused($field, equals: .guests).disabled(locked)
            }
            Divider().opacity(0.5)
            row("Where") {
                TextField("Room or address", text: binding(\.location)).focused($field, equals: .location).disabled(locked)
                    .onChange(of: block.location ?? "") { _, text in if field == .location { places.search(text) } }
                    .onChange(of: field) { _, now in if now != .location { places.clear() } }
                    .onKeyPress(.downArrow) { places.move(1) }
                    .onKeyPress(.upArrow) { places.move(-1) }
                    .onKeyPress(.escape) { places.results.isEmpty ? .ignored : { places.clear(); return .handled }() }
                    .onSubmit { if let place = places.highlighted { pick(place) } }
                Toggle(isOn: meet) {
                    Label("Google Meet", systemImage: "video").font(.system(size: expanded ? 12.5 : 11.5))
                }
                .toggleStyle(.button).controlSize(.small).disabled(locked)
                .help(block.meet == true ? "A Meet link will be added" : "Add a Google Meet link")
            }
            if !places.results.isEmpty && field == .location {
                PlaceSuggestions(places: places, large: expanded, pick: pick).padding(.leading, expanded ? 70 : 60).padding(.bottom, 6)
                    .transition(.opacity)
            }
            Divider().opacity(0.5)
            TextEditor(text: binding(\.body))
                .focused($field, equals: .notes)
                .disabled(locked)
                .font(.system(size: expanded ? 14.5 : 12.5))
                .lineSpacing(expanded ? 3 : 1)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, -5)
                .padding(.top, 8)
                .frame(minHeight: expanded ? 200 : 70, maxHeight: expanded ? .infinity : 140)
                .overlay(alignment: .topLeading) {
                    if (block.body ?? "").isEmpty {
                        Text("Notes or agenda").foregroundStyle(.tertiary).padding(.top, 8).allowsHitTesting(false)
                    }
                }
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

    private var actions: some View {
        HStack(spacing: 8) {
            let guests = Invite.guests(block.to)
            if !guests.isEmpty {
                Text(guests.count == 1 ? "Sends 1 invitation" : "Sends \(guests.count) invitations")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
            Spacer()
            if let held = model.heldSend(for: id) {
                DraftUndoButton(held: held, model: model)
            } else {
                let button = Button { model.mail(id, action: "send") } label: {
                    HStack(spacing: 5) {
                        if working != nil { ProgressView().controlSize(.mini) } else { Image(systemName: "calendar.badge.plus") }
                        Text("Create invite")
                    }
                }
                .buttonStyle(.borderedProminent)
                .help((expanded ? "Create (⌘↩)" : "Create") + ", with \(Int(RelayModel.undoSeconds))s to undo")
                if expanded { button.keyboardShortcut(.return, modifiers: .command) } else { button }
            }
        }
        .controlSize(expanded ? .large : .regular)
    }
}

/// An invite that's been created (or one an agent showed as created): read-only, with a link to it in Calendar.
struct InviteBlock: View {
    let block: Block
    var lines: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text((block.status == "draft" ? "Invite" : "Invite sent").uppercased())
                    .font(.rounded(10.5, .bold)).kerning(0.8).foregroundStyle(.secondary)
                Spacer()
                if block.status == "created" {
                    Label("Created", systemImage: "checkmark").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.green)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.green.opacity(0.12), in: .capsule)
                }
            }
            HStack(alignment: .top, spacing: 0) {
                Rectangle().fill(Color.accentColor).frame(width: 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(block.title ?? "Untitled event").font(.system(size: 13.5, weight: .semibold))
                    if let when = Invite.when(block.start, block.end) {
                        Text(when).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    let place = [block.location, block.meet == true ? "Google Meet" : nil].compactMap { $0 }.filter { !$0.isEmpty }
                    if !place.isEmpty {
                        Label(place.joined(separator: " · "), systemImage: block.meet == true ? "video" : "mappin")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    let guests = Invite.guests(block.to)
                    if !guests.isEmpty {
                        Label(guests.joined(separator: ", "), systemImage: "person.2").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(.fill.tertiary)
            .clipShape(.rect(cornerRadius: 7, style: .continuous))
            if let notes = block.body, !notes.isEmpty {
                Text(notes).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(lines)
            }
            if let url = block.url.flatMap(URL.init(string:)) {
                Link("Open in Calendar", destination: url).font(.system(size: 12))
            }
        }
        .padding(14)
    }
}

// MARK: - Apple Calendar–style pickers

/// A tappable field-like pill, the way Calendar shows a date or time.
private struct Pill<Content: View>: View {
    var large = false
    @ViewBuilder var content: Content
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        content
            .font(.system(size: large ? 13.5 : 12.5).monospacedDigit())
            .padding(.horizontal, large ? 9 : 7).padding(.vertical, large ? 4 : 3)
            .background(hover && enabled ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.fill.tertiary), in: .rect(cornerRadius: 6, style: .continuous))
            .contentShape(.rect)
            .onHover { hover = $0 }
    }
}

/// "Sat, Oct 3": click for a month calendar; picking a day keeps the time.
struct DayPill: View {
    @Binding var date: Date
    var large = false
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Pill(large: large) { Text(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            MonthCalendar(selected: date) { day in
                let calendar = Calendar.current
                let time = calendar.dateComponents([.hour, .minute], from: date)
                date = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: day) ?? day
                open = false
            }
        }
    }
}

/// "12:00 PM": click for a list of times in 15-minute steps, scrolled to the current one. An end time
/// (with `after`) lists the times after the start, each with its length, like Calendar and Google Calendar.
struct TimePill: View {
    @Binding var date: Date
    var after: Date? = nil
    var large = false
    @State private var open = false

    private var choices: [Date] {
        let calendar = Calendar.current
        if let after {
            return (1...96).compactMap { calendar.date(byAdding: .minute, value: $0 * 15, to: after) }
        }
        let day = calendar.startOfDay(for: date)
        return (0..<96).compactMap { calendar.date(byAdding: .minute, value: $0 * 15, to: day) }
    }

    /// The listed time nearest the current one, to scroll to and mark.
    private var nearest: Date? { choices.min { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) } }

    private func length(_ end: Date) -> String {
        let minutes = Int(end.timeIntervalSince(after ?? end) / 60)
        if minutes < 60 { return "\(minutes) min" }
        let hours = Double(minutes) / 60
        return hours == hours.rounded() ? "\(Int(hours)) hr" : String(format: "%.2g hr", hours)
    }

    var body: some View {
        Button { open.toggle() } label: {
            Pill(large: large) { Text(date.formatted(date: .omitted, time: .shortened)) }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(choices, id: \.self) { time in
                            TimeRow(time: time, detail: after == nil ? nil : length(time), selected: time == nearest) {
                                date = time
                                open = false
                            }
                            .id(time)
                        }
                    }
                    .padding(5)
                }
                .frame(width: after == nil ? 130 : 170, height: 240)
                .onAppear { if let nearest { proxy.scrollTo(nearest, anchor: .center) } }
            }
        }
    }
}

private struct TimeRow: View {
    let time: Date
    let detail: String?
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).opacity(selected ? 1 : 0)
                Text(time.formatted(date: .omitted, time: .shortened)).monospacedDigit()
                if let detail { Text(detail).foregroundStyle(hover ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary)) }
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .foregroundStyle(hover ? .white : .primary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(hover ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 5, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// A month grid in the macOS 26 style: glass arrows, round days, the chosen day a tinted glass disc, today in red as in Calendar.
struct MonthCalendar: View {
    let selected: Date
    let pick: (Date) -> Void
    @State private var month: Date
    @State private var forward = true
    private let calendar = Calendar.current

    init(selected: Date, pick: @escaping (Date) -> Void) {
        self.selected = selected
        self.pick = pick
        _month = State(initialValue: Calendar.current.dateInterval(of: .month, for: selected)?.start ?? selected)
    }

    /// Always six weeks, so the popover never changes height between months.
    private var days: [Date] {
        let first = calendar.dateInterval(of: .month, for: month)?.start ?? month
        let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -lead, to: first) ?? first
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private var weekdays: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { symbols[($0 + calendar.firstWeekday - 1) % 7] }
    }

    private func go(_ step: Int) {
        forward = step > 0
        withAnimation(.smooth(duration: 0.28)) { month = calendar.date(byAdding: .month, value: step, to: month) ?? month }
    }

    private var showingToday: Bool { calendar.isDate(month, equalTo: .now, toGranularity: .month) }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Text(month.formatted(.dateTime.month(.wide))).font(.system(size: 16, weight: .bold))
                    Text(month.formatted(.dateTime.year())).font(.system(size: 16, weight: .regular)).foregroundStyle(.secondary)
                }
                .id(month)
                .transition(.push(from: forward ? .trailing : .leading).combined(with: .opacity))
                Spacer()
                if !showingToday {
                    Button("Today") {
                        forward = Date.now > month
                        withAnimation(.smooth(duration: 0.28)) { month = calendar.dateInterval(of: .month, for: .now)?.start ?? .now }
                    }
                    .buttonStyle(.glass).controlSize(.small)
                    .transition(.scale.combined(with: .opacity))
                }
                Button { go(-1) } label: { Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)).frame(width: 14, height: 14) }
                    .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.small)
                Button { go(1) } label: { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).frame(width: 14, height: 14) }
                    .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.small)
            }
            .padding(.horizontal, 4)
            .animation(.smooth(duration: 0.2), value: showingToday)

            HStack(spacing: 0) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, day in
                    Text(day).font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 2), count: 7), spacing: 2) {
                ForEach(days, id: \.self) { day in
                    DayCell(day: day,
                            inMonth: calendar.isDate(day, equalTo: month, toGranularity: .month),
                            isSelected: calendar.isDate(day, inSameDayAs: selected),
                            isToday: calendar.isDateInToday(day)) { pick(day) }
                }
            }
            .id(month)
            .transition(.push(from: forward ? .trailing : .leading).combined(with: .opacity))
        }
        .padding(14)
        .frame(width: 34 * 7 + 2 * 6 + 28)
        .clipped()
    }
}

private struct DayCell: View {
    let day: Date
    let inMonth: Bool
    let isSelected: Bool
    let isToday: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(day.formatted(.dateTime.day()))
                .font(.system(size: 13.5, weight: isSelected || isToday ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : isToday ? AnyShapeStyle(Color.red)
                                 : inMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
                .frame(width: 34, height: 34)
                .background {
                    if isSelected {
                        Circle().fill(Color.accentColor.gradient).shadow(color: .accentColor.opacity(0.35), radius: 6, y: 2)
                    } else if hover {
                        Circle().fill(.fill.secondary)
                    }
                }
                .glassEffect(isSelected ? .regular.tint(.accentColor).interactive() : .identity, in: .circle)
                .scaleEffect(hover && !isSelected ? 1.06 : 1)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { over in withAnimation(.snappy(duration: 0.15)) { hover = over } }
    }
}

// MARK: - Place suggestions

/// Apple Maps search-as-you-type for the Where field (MKLocalSearchCompleter, what Calendar uses): no key, no location permission.
@MainActor @Observable
final class Places: NSObject, MKLocalSearchCompleterDelegate {
    struct Place: Hashable { let title: String; let subtitle: String
        /// What goes in the invite: "Blue Bottle Coffee, 705 Market St, San Francisco, CA 94103, United States".
        var address: String { subtitle.isEmpty || subtitle == title ? title : "\(title), \(subtitle)" }
    }

    private(set) var results: [Place] = []
    var index = 0
    var highlighted: Place? { results.indices.contains(index) ? results[index] : nil }

    @ObservationIgnored private lazy var completer: MKLocalSearchCompleter = {
        let completer = MKLocalSearchCompleter()
        completer.resultTypes = [.address, .pointOfInterest]
        completer.delegate = self
        return completer
    }()
    /// The text a pick just wrote into the field, so it doesn't search again.
    @ObservationIgnored private var picked: String?

    func search(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2, query != picked else { results = []; return }
        completer.queryFragment = query
    }

    /// `picked`: the address a pick just wrote into the field.
    func clear(picked: String? = nil) {
        self.picked = picked
        results = []
        index = 0
        if !completer.queryFragment.isEmpty { completer.cancel() }
    }

    func move(_ step: Int) -> KeyPress.Result {
        guard !results.isEmpty else { return .ignored }
        index = (index + step + results.count) % results.count
        return .handled
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let found = completer.results.prefix(5).map { Place(title: $0.title, subtitle: $0.subtitle) }
        MainActor.assumeIsolated {
            results = found
            index = 0
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated { results = [] }
    }
}

struct PlaceSuggestions: View {
    let places: Places
    var large = false
    let pick: (Places.Place) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(places.results.enumerated()), id: \.element) { index, place in
                Button { pick(place) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "mappin.circle.fill").font(.system(size: large ? 17 : 15)).foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(place.title).font(.system(size: large ? 13.5 : 12.5, weight: .medium)).lineLimit(1)
                            if !place.subtitle.isEmpty {
                                Text(place.subtitle).font(.system(size: large ? 12 : 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(index == places.index ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 7, style: .continuous))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { if $0 { places.index = index } }
            }
        }
        .padding(4)
        .background(.fill.quaternary, in: .rect(cornerRadius: 10, style: .continuous))
    }
}
