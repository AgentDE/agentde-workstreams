import AppKit
import AgentDEKit
import SwiftUI
import WorkstreamKit

/// The workstream panel: the tab's agent's active workstream. A picker on top (its name; switch, start or
/// rename one); then sections that appear when they have content, each folding and showing when it was
/// last updated. Rules always shows, since it's where you add one.
struct WorkstreamPanel: View {
    let tab: TabInfo
    @Environment(WorkstreamsModel.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        // Refreshes the "updated" times and countdowns once a minute.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 0) {
                if let error = store.writeError(for: tab) {
                    Label("Changes here aren't being saved: \(error)", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5)).foregroundStyle(Color(hex: 0xE24B4A))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        sections(now: context.date)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.automatic)
            }
        }
    }

    @ViewBuilder private func sections(now: Date) -> some View {
        let workstream = store.workstream(for: tab)
        let agents = workstream.map { store.agentTabs(of: $0) } ?? [tab]
        let asks = workstream?.openAsks ?? []
        let activity = store.activity(of: workstream)
        if !asks.isEmpty {
            PanelSection(key: "waiting", title: "Waiting on you", count: "\(asks.count)", updated: workstream?.waiting?.updated, now: now, tab: tab) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(asks, id: \.id) { ask in AskCard(ask: ask, tab: tab, showAgent: agents.count > 1, now: now) }
                }
            }
        }
        let notes = (workstream?.fyi?.items ?? []).filter { ($0.expires ?? .distantFuture) > now }
        if let fyi = workstream?.fyi, !notes.isEmpty {
            PanelSection(key: "fyi", title: "FYI", count: "\(notes.count)", updated: fyi.updated, now: now, tab: tab) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(notes.reversed(), id: \.id) { note in FYIRow(note: note, tab: tab, now: now) }
                }
            }
        }
        if let overview = workstream?.overview {
            PanelSection(key: "overview", title: "Overview", updated: overview.updated, now: now, tab: tab) {
                // "Goal: …" and "Status: …" lines get their label in the text color; older free text shows as is.
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(overview.text.split(separator: "\n", omittingEmptySubsequences: true).enumerated()), id: \.offset) { _, line in
                        let parts = line.split(separator: ":", maxSplits: 1)
                        if parts.count == 2, ["Goal", "Status"].contains(String(parts[0])) {
                            (Text(parts[0] + ":").fontWeight(.semibold).foregroundColor(theme.text) + Text(parts[1]).foregroundColor(theme.secondary))
                                .font(.system(size: 12.5))
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        } else {
                            Text(line).font(.system(size: 12.5)).foregroundStyle(theme.secondary)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        let tickets = workstream?.tickets?.items ?? []
        if !tickets.isEmpty || !store.ticketProviders.filter(\.isReady).isEmpty, store.workstreamID(of: tab) != nil {
            PanelSection(key: "tickets", title: "Tickets", count: tickets.isEmpty ? nil : "\(tickets.count)", updated: workstream?.tickets?.updated, now: now, tab: tab) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(tickets, id: \.identifier) { ticket in LinkedTicketRow(ticket: ticket, tab: tab) }
                    AddTicketField(tab: tab, linked: Set(tickets.map(\.identifier)))
                }
            }
            .onAppear { if let id = store.workstreamID(of: tab) { store.lookUpTickets(in: id) } }
            .onChange(of: tickets.map(\.identifier)) { if let id = store.workstreamID(of: tab) { store.lookUpTickets(in: id) } }
        }
        let rules = workstream?.activeRules ?? []
        PanelSection(key: "rules", title: "Rules", count: rules.isEmpty ? nil : "\(rules.count)", updated: rules.isEmpty ? nil : workstream?.rules?.updated, now: now, tab: tab) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(rules, id: \.id) { rule in RuleRow(rule: rule, tab: tab) }
                AddRuleField(tab: tab)
            }
        }
        if agents.count >= 2 {
            PanelSection(key: "agents", title: "Agents", count: "\(agents.count)", updated: nil, now: now, tab: tab) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(agents, id: \.id) { agent in AgentRow(agent: agent, current: agent.id == tab.id) }
                }
            }
        }
        let messages = activity.messages()
        if !messages.isEmpty {
            PanelSection(key: "messages", title: "Messages", count: "\(messages.count)", updated: messages.first?.message.at, now: now, tab: tab) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(messages.enumerated()), id: \.offset) { _, row in MessageRow(row: row, now: now) }
                }
            }
        }
        if let memory = workstream?.memory, !memory.items.isEmpty {
            PanelSection(key: "memory", title: "Memory", count: "\(memory.items.count)", updated: memory.updated, now: now, tab: tab, defaultOpen: false) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(memory.items, id: \.id) { item in
                        MemoryRow(item: item, tab: tab, now: now)
                    }
                }
            }
        }
        if let progress = workstream?.progress, !progress.rows.isEmpty {
            let stale = now.timeIntervalSince(progress.updated) > 30 * 60
            PanelSection(key: "progress", title: "Progress", updated: progress.updated, now: now, tab: tab) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(progress.rows.enumerated()), id: \.offset) { _, row in ProgressRowView(row: row, tab: tab) }
                }
                .opacity(stale ? 0.5 : 1)
            }
        }
        planSections(agents: agents, now: now)
        scheduledSection(workstream: workstream, agents: agents, now: now)
        filesSection(workstream: workstream, activity: activity, now: now)
        artifactsSection(workstream: workstream, activity: activity, agents: agents, now: now)
        StatsSection(tab: tab, agents: agents, now: now)
    }

    /// A Memory item's date: "Oct 21", with the year when it isn't this year's.
    static func memoryDate(_ date: Date, now: Date) -> String {
        let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: now)
        return date.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
    }

    private func agentName(_ session: String, _ agents: [TabInfo]) -> String? {
        agents.first { $0.agentSession == session }.map { $0.title }
    }

    /// Pinned files (yours and the agent's, with notes), then the ones the attached agents edited most recently,
    /// then the ones they touched most.
    @ViewBuilder private func filesSection(workstream: Workstream?, activity: WorkstreamActivity, now: Date) -> some View {
        let pinned = workstream?.files?.items ?? []
        let shown = Set(pinned.map(\.path))
        let recent = activity.recentFiles(12).filter { !shown.contains($0.path) && FileManager.default.fileExists(atPath: $0.path) }.prefix(8)
        let listed = shown.union(recent.map(\.path))
        let busy = activity.highActivity(10).filter { !listed.contains($0.path) && FileManager.default.fileExists(atPath: $0.path) }.prefix(5)
        if !pinned.isEmpty || !recent.isEmpty || !busy.isEmpty {
            let updated = [workstream?.files?.updated, recent.first?.lastEdit].compactMap { $0 }.max()
            PanelSection(key: "files", title: "Files", updated: updated, now: now, tab: tab) {
                VStack(alignment: .leading, spacing: 1) {
                    if !pinned.isEmpty {
                        FilesSubheading(title: "Pinned")
                        ForEach(pinned, id: \.path) { item in PinnedFileRow(item: item, tab: tab) }
                    }
                    if !recent.isEmpty {
                        FilesSubheading(title: "Recent").padding(.top, pinned.isEmpty ? 0 : 6)
                        ForEach(Array(recent), id: \.path) { file in
                            ActivityFileRow(path: file.path, detail: PanelSectionTime.short(file.lastEdit ?? now, now: now), tab: tab)
                        }
                    }
                    if !busy.isEmpty {
                        FilesSubheading(title: "High activity").padding(.top, pinned.isEmpty && recent.isEmpty ? 0 : 6)
                        ForEach(Array(busy), id: \.path) { file in ActivityFileRow(path: file.path, detail: "\(file.count)", tab: tab) }
                    }
                }
            }
        }
    }

    /// Artifacts you pinned, then the ones the attached agents made or linked, newest first. Pinning is yours
    /// alone: right-click an artifact (or ◇ Pin in the viewer while it's open).
    @ViewBuilder private func artifactsSection(workstream: Workstream?, activity: WorkstreamActivity, agents: [TabInfo], now: Date) -> some View {
        let pinned = workstream?.pinnedArtifacts?.items ?? []
        let pinnedURLs = Set(pinned.map(\.url))
        let recent = activity.artifacts().filter { !pinnedURLs.contains($0.artifact.url) }
        if !pinned.isEmpty || !recent.isEmpty {
            let updated = [workstream?.pinnedArtifacts?.updated, recent.first?.artifact.at].compactMap { $0 }.max()
            PanelSection(key: "artifacts", title: "Artifacts", count: "\(pinned.count + recent.count)", updated: updated, now: now, tab: tab) {
                VStack(alignment: .leading, spacing: 1) {
                    if !pinned.isEmpty {
                        FilesSubheading(title: "Pinned")
                        ForEach(pinned, id: \.url) { artifact in
                            ArtifactRow(row: WorkstreamActivity.AgentArtifact(agent: "", artifact: artifact), tab: tab, agent: nil, now: now, pinned: true)
                        }
                    }
                    if !recent.isEmpty {
                        if !pinned.isEmpty { FilesSubheading(title: "Recent").padding(.top, 6) }
                        ForEach(recent, id: \.artifact.url) { row in
                            ArtifactRow(row: row, tab: tab, agent: activity.perAgent.count > 1 ? agentName(row.agent, agents) : nil, now: now)
                        }
                    }
                }
            }
        }
    }

    /// This agent's own to-do list, then the other attached agents' lists, folded and labeled.
    @ViewBuilder private func planSections(agents: [TabInfo], now: Date) -> some View {
        let lists = ([tab] + agents.filter { $0.id != tab.id }).compactMap { agent -> (TabInfo, PlanList)? in
            guard agent.kind != .codex, let session = agent.agentSession,
                  let list = store.plan(forSession: session), !list.steps.isEmpty else { return nil }
            return (agent, list)
        }
        ForEach(lists, id: \.0.id) { agent, list in
            let isCurrent = agent.id == tab.id
            let done = list.steps.filter { $0.state == .done }.count
            PanelSection(key: isCurrent ? "plan" : "plan-" + agent.id.uuidString,
                         title: isCurrent ? "Plan" : "Plan · " + agent.title,
                         count: "\(done)/\(list.steps.count)", updated: list.updated, now: now, tab: tab, defaultOpen: isCurrent) {
                let shown = WorkstreamSummary.trimmedPlan(list.steps)
                VStack(alignment: .leading, spacing: 3) {
                    // The done count as a bar, kept current by the agent's own to-do list.
                    ProgressBar(value: Double(done) / Double(list.steps.count)).padding(.bottom, 4)
                    if shown.count < list.steps.count {
                        Text("\(list.steps.count - shown.count) earlier steps done").font(.system(size: 11)).foregroundStyle(theme.muted)
                    }
                    ForEach(shown, id: \.id) { step in PlanStepRow(step: step) }
                }
            }
        }
    }

    /// What the attached agents scheduled with Claude's own tools, soonest first, plus the folder's durable jobs.
    @ViewBuilder private func scheduledSection(workstream: Workstream?, agents: [TabInfo], now: Date) -> some View {
        let perAgent = agents.compactMap { agent -> [(TabInfo?, ScheduledItem)]? in
            guard let session = agent.agentSession else { return nil }
            let items = store.scheduledItems(forSession: session, now: now)
            return items.isEmpty ? nil : items.map { (agent, $0) }
        }.flatMap { $0 }
        let seen = Set(perAgent.map(\.1.id))
        let durable = store.durableJobs(folder: workstream?.folder, now: now).filter { !seen.contains($0.id) }.map { (TabInfo?.none, $0) }
        let rows = (perAgent + durable).sorted { $0.1.next < $1.1.next }
        if !rows.isEmpty {
            PanelSection(key: "scheduled", title: "Scheduled", count: "\(rows.count)", updated: nil, now: now, tab: tab) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        ScheduledRow(item: row.1, agent: agents.count > 1 ? row.0.map { $0.title } : nil, now: now)
                    }
                }
            }
        }
    }
}

/// The active workstream's name; its menu switches this agent to another of the group's workstreams,
/// starts a new one, or renames this one.
private struct AgentRow: View {
    let agent: TabInfo
    let current: Bool
    @Environment(WorkstreamsModel.self) private var store
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button { store.host.selectTab(agent.id, focus: true) } label: {
            HStack(spacing: 7) {
                Group {
                    if agent.state != .none {
                        StatusDot(state: agent.state, animated: store.host.animations, size: 6)
                    } else {
                        Circle().fill(agent.agentPresent ? Theme.working.opacity(0.6) : theme.muted.opacity(0.5))
                            .frame(width: 6, height: 6)
                    }
                }
                .frame(width: 12)
                Text(agent.title).font(.system(size: 12.5)).lineLimit(1)
                    .foregroundStyle(current ? theme.text : theme.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(current ? theme.selected : hovering ? theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct FYIRow: View {
    let note: Workstream.Note
    let tab: TabInfo
    let now: Date
    @Environment(WorkstreamsModel.self) private var store
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(note.text).font(.system(size: 12.5)).foregroundStyle(theme.secondary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 4)
            if hovering {
                Button { store.dismissFYI(note.id, in: tab) } label: {
                    Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(theme.muted)
                }
                .buttonStyle(.plain)
                .hint("Dismiss")
            } else {
                Text(PanelSectionTime.short(note.at, now: now)).font(.system(size: 11)).monospacedDigit().foregroundStyle(theme.muted)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct RuleRow: View {
    let rule: Workstream.Rule
    let tab: TabInfo
    @Environment(WorkstreamsModel.self) private var store
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(theme.muted)
            Text(rule.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 4)
            if hovering {
                Button { store.removeRule(rule.id, in: tab) } label: {
                    Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(theme.muted)
                }
                .buttonStyle(.plain)
                .hint("Remove")
            }
        }
        .font(.system(size: 12.5)).foregroundStyle(theme.secondary)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// A linked ticket: live from Linear when it's been looked up (state colour, priority), else what the file has.
private struct LinkedTicketRow: View {
    let ticket: Workstream.Ticket
    let tab: TabInfo
    @Environment(WorkstreamsModel.self) private var store
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        let issue = store.ticketInfo[ticket.identifier]
            ?? TicketInfo(identifier: ticket.identifier, title: ticket.title ?? "", url: ticket.url ?? "")
        TicketRow(ticket: issue, trailing: hovering ? AnyView(
            Button { store.unlinkTicket(ticket.identifier, in: tab) } label: {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(theme.muted)
            }
            .buttonStyle(.plain)
            .hint("Unlink")
        ) : nil)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy \(ticket.identifier)") { copy(ticket.identifier) }
            if !issue.url.isEmpty { Button("Copy Link") { copy(issue.url) } }
            Button("Unlink") { store.unlinkTicket(ticket.identifier, in: tab) }
        }
    }
}

/// Link a ticket by identifier or link, or pick one of yours from the menu beside it.
private struct AddTicketField: View {
    let tab: TabInfo
    let linked: Set<String>
    @Environment(WorkstreamsModel.self) private var store
    @Environment(\.theme) private var theme
    @State private var text = ""
    @State private var invalid = false

    var body: some View {
        let mine = store.myTickets.filter { !linked.contains($0.identifier) }
        HStack(spacing: 4) {
            TextField("Link ticket (ENG-123, owner/repo#12 or link)", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(invalid ? Color(hex: 0xFF6B5E) : theme.text)
                .padding(.vertical, 3)
                .onChange(of: text) { invalid = false }
                .onSubmit {
                    if store.linkTicket(text, in: tab) { text = "" } else { invalid = !text.isEmpty }
                }
            if !mine.isEmpty {
                Menu {
                    ForEach(Array(mine.prefix(25)), id: \.identifier) { issue in
                        Button("\(issue.identifier)  \(issue.title)") { store.linkTicket(issue.url, title: issue.title, in: tab) }
                    }
                } label: {
                    Image(systemName: "plus.circle").font(.system(size: 11)).foregroundStyle(theme.muted)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .hint("Link one of your tickets")
            }
        }
        .onAppear { store.loadMyTickets() }
    }
}

private struct AddRuleField: View {
    let tab: TabInfo
    @Environment(WorkstreamsModel.self) private var store
    @Environment(\.theme) private var theme
    @State private var text = ""

    var body: some View {
        TextField("Add rule", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(theme.text)
            .padding(.vertical, 3)
            .onSubmit {
                store.addRule(text, in: tab)
                text = ""
            }
    }
}

private struct ScheduledRow: View {
    let item: ScheduledItem
    let agent: String?
    let now: Date
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.text.isEmpty ? (item.kind == .wakeup ? "Wake-up" : "Scheduled prompt") : item.text)
                .font(.system(size: 12.5)).foregroundStyle(theme.secondary).lineLimit(1)
            Text(when + (agent.map { " · \($0)" } ?? ""))
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(theme.muted).lineLimit(1)
        }
        .help(item.text)
    }

    private var when: String {
        let clock = ScheduledRow.clock(item.next, now: now)
        if item.recurring { return (item.schedule ?? "Recurring") + " · next " + clock }
        return "in " + ScheduledRow.until(item.next, now: now) + " · " + clock
    }

    static func until(_ date: Date, now: Date) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        if seconds < 90 { return "1m" }
        if seconds < 5400 { return "\(Int((seconds / 60).rounded()))m" }
        if seconds < 172_800 { return "\(Int((seconds / 3600).rounded()))h" }
        return "\(Int((seconds / 86_400).rounded()))d"
    }

    static func clock(_ date: Date, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        return formatter.string(from: date)
    }
}

/// A folding section: chevron, title, count, and how long ago it was updated.
private struct PanelSection<Content: View>: View {
    let key: String
    let title: String
    var count: String? = nil
    let updated: Date?
    let now: Date
    let tab: TabInfo
    var defaultOpen = true
    @ViewBuilder let content: () -> Content
    @Environment(WorkstreamsModel.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        let open = store.panelSections(of: tab)?[key] ?? defaultOpen
        VStack(alignment: .leading, spacing: 0) {
            Button { store.setPanelSection(key, open: !open, in: tab.id) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 10)
                    Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.7).lineLimit(1)
                    if let count { Text(count).font(.system(size: 11)).monospacedDigit().foregroundStyle(theme.secondary) }
                    Spacer(minLength: 6)
                    if let updated { Text(PanelSectionTime.short(updated, now: now)).font(.system(size: 11)).monospacedDigit() }
                }
                .foregroundStyle(theme.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                content().padding(.top, 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 0.5) }
    }
}

enum PanelSectionTime {
    /// "now", "3m", "2h", "4d".
    static func short(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}

private struct AskCard: View {
    let ask: Workstream.Ask
    let tab: TabInfo
    let showAgent: Bool
    let now: Date
    @Environment(WorkstreamsModel.self) private var store
    @Environment(\.theme) private var theme

    @State private var hovering = false
    @State private var reply = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ask.question).font(.system(size: 12.5)).foregroundStyle(theme.text)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Spacer(minLength: 4)
                if hovering || NSWorkspace.shared.isVoiceOverEnabled { DismissButton(help: "Dismiss, and tell the agent no answer is needed") { store.dismissAsk(ask, in: tab) } }
            }
            if !ask.answers.isEmpty {
                FlowRow(spacing: 6) {
                    ForEach(ask.answers, id: \.self) { option in
                        let isDefault = option == ask.defaultOption
                        Button { store.answer(ask, with: option, in: tab) } label: {
                            Text(option).font(.system(size: 12, weight: isDefault ? .semibold : .medium))
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.needsYou.opacity(isDefault ? 0.34 : 0.2)))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.needsYou.opacity(isDefault ? 0.7 : 0), lineWidth: 1))
                                .foregroundStyle(theme.text)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            // An answer the buttons don't cover: typed here, sent like a button's (with the question).
            TextField("Or type a reply", text: $reply)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.text.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.needsYou.opacity(0.3), lineWidth: 0.5))
                .onSubmit {
                    let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    store.answer(ask, with: text, in: tab)
                    reply = ""
                }
            if let meta {
                Text(meta).font(.system(size: 11)).monospacedDigit().foregroundStyle(theme.muted)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.needsYou.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.needsYou.opacity(0.4), lineWidth: 0.5))
        .onHover { hovering = $0 }
    }

    private var meta: String? {
        var parts: [String] = []
        if showAgent, let session = ask.agent,
           let agent = store.tabs.first(where: { $0.agentSession == session }) {
            parts.append(agent.title)
        }
        if let option = ask.defaultOption {
            if let deadline = ask.decideBy {
                parts.append(deadline > now ? "defaults to \(option) in \(ScheduledRow.until(deadline, now: now))" : "defaulting to \(option)")
            } else {
                parts.append("default: \(option)")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct ProgressRowView: View {
    let row: Workstream.ProgressRow
    let tab: TabInfo
    @Environment(WorkstreamsModel.self) private var store
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        // The label gets its own line, so it uses the panel's full width rather than a fixed column.
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(row.label).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if hovering || NSWorkspace.shared.isVoiceOverEnabled { DismissButton(help: "Remove") { store.removeProgressRow(row, in: tab) } }
            }
            VStack(alignment: .leading, spacing: 4) {
                if let value = row.value { ProgressBar(value: value) }
                Text(row.text).font(.system(size: 11.5)).monospacedDigit()
                    .foregroundStyle(row.value == nil ? theme.secondary : theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// A thin bar for a fraction done (0 to 1).
private struct ProgressBar: View {
    let value: Double
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.hover)
                Capsule().fill(LinearGradient(colors: [Color(hex: 0x2AF6AE), Color(hex: 0x23C1F3)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: 6)
    }
}

/// The ✕ that removes an entry, shown while the pointer is over it.
private struct DismissButton: View {
    let help: String
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(theme.muted)
        }
        .buttonStyle(.plain)
        .hint(help)
    }
}

private struct MemoryRow: View {
    let item: Workstream.MemoryItem
    let tab: TabInfo
    let now: Date
    @Environment(WorkstreamsModel.self) private var store
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(theme.muted)
            (item.name.map { Text($0 + "  ").fontWeight(.semibold).foregroundColor(theme.text) } ?? Text(""))
                + Text(item.text)
                + (item.at.map { Text("  " + WorkstreamPanel.memoryDate($0, now: now)).foregroundColor(theme.muted) } ?? Text(""))
            Spacer(minLength: 4)
            if hovering || NSWorkspace.shared.isVoiceOverEnabled { DismissButton(help: "Remove") { store.removeMemory(item.id, in: tab) } }
        }
        .fixedSize(horizontal: false, vertical: true)
        .font(.system(size: 12.5)).foregroundStyle(theme.secondary).textSelection(.enabled)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct PlanStepRow: View {
    let step: PlanStep
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: step.state == .done ? "checkmark" : step.state == .current ? "play.fill" : "circle")
                .font(.system(size: step.state == .current ? 7 : 8.5, weight: .semibold))
                .foregroundStyle(step.state == .current ? Color(hex: 0x3DF2A6) : theme.muted)
                .frame(width: 12)
            Text(step.text).font(.system(size: 12.5, weight: step.state == .current ? .medium : .regular))
                .foregroundStyle(step.state == .done ? theme.muted : step.state == .current ? theme.text : theme.secondary)
                .strikethrough(step.state == .done, color: theme.muted.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct FilesSubheading: View {
    let title: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.muted).padding(.bottom, 2)
    }
}

private struct PinnedFileRow: View {
    let item: Workstream.FileItem
    let tab: TabInfo
    @Environment(WorkstreamsModel.self) private var store
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        let open = tab.viewerItem == item.path
        let missing = !FileManager.default.fileExists(atPath: item.path)
        Button { store.host.openInViewer(item.path, tab: tab.id, select: true) } label: {
            HStack(spacing: 6) {
                Image(systemName: FileIcons.symbol(for: URL(fileURLWithPath: item.path), isDirectory: false))
                    .font(.system(size: 10.5)).foregroundStyle(theme.muted).frame(width: 14)
                Text((item.path as NSString).lastPathComponent).font(.system(size: 12.5)).foregroundStyle(open ? theme.text : theme.secondary)
                    .lineLimit(1)
                    .strikethrough(missing, color: theme.muted)
                if missing {
                    Text("missing").font(.system(size: 11)).foregroundStyle(theme.muted)
                } else if let note = item.note, !note.isEmpty {
                    Text(note).font(.system(size: 11)).foregroundStyle(theme.muted).lineLimit(1)
                }
                Spacer(minLength: 4)
                if hovering {
                    DismissButton(help: "Unpin") { store.togglePinned(item.path, in: tab) }
                } else if item.by == "you" {
                    Text("◆").font(.system(size: 9)).foregroundStyle(theme.muted)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(open ? theme.selected : hovering ? theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(missing ? "No longer at \(item.path.abbreviatingHome)" : item.path.abbreviatingHome)
    }
}

/// Lays out its children left to right, wrapping onto new lines.
private struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews, width: bounds.width)
        for (index, point) in rows.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxWidth = max(maxWidth, x - spacing)
        }
        return (points, maxWidth, y + rowHeight)
    }
}

/// One cross-session message: who to whom, its first line, and its age; click to see all of it.
private struct MessageRow: View {
    let row: WorkstreamActivity.AgentMessage
    let now: Date
    @Environment(WorkstreamsModel.self) private var store
    @Environment(\.theme) private var theme
    @State private var expanded = false

    var body: some View {
        let me = store.tabs.first { $0.agentSession == row.agent }.map { $0.title }
            ?? String(row.agent.prefix(8))
        let (from, to) = row.message.outgoing ? (me, row.message.peer) : (row.message.peer, me)
        Button { expanded.toggle() } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("\(from) → \(to)").font(.system(size: 11)).foregroundStyle(theme.muted).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(PanelSectionTime.short(row.message.at, now: now)).font(.system(size: 11)).monospacedDigit().foregroundStyle(theme.muted)
                }
                Text(expanded ? row.message.text : firstLine)
                    .font(.system(size: 12.5)).foregroundStyle(theme.secondary)
                    .lineLimit(expanded ? nil : 1)
                    .fixedSize(horizontal: false, vertical: expanded)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textSelection(.enabled)
    }

    private var firstLine: String {
        row.message.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? row.message.text
    }
}

/// A file from the agents' transcripts (Recent or High activity): opens in the viewer.
private struct ActivityFileRow: View {
    let path: String
    let detail: String
    let tab: TabInfo
    @Environment(WorkstreamsModel.self) private var store
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        let open = tab.viewerItem == path
        Button { store.host.openInViewer(path, tab: tab.id, select: true) } label: {
            HStack(spacing: 6) {
                Image(systemName: FileIcons.symbol(for: URL(fileURLWithPath: path), isDirectory: false))
                    .font(.system(size: 10.5)).foregroundStyle(theme.muted).frame(width: 14)
                Text((path as NSString).lastPathComponent).font(.system(size: 12.5)).foregroundStyle(open ? theme.text : theme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(detail).font(.system(size: 11)).monospacedDigit().foregroundStyle(theme.muted)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(open ? theme.selected : hovering ? theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(path.abbreviatingHome)
    }
}

/// An artifact an agent published or linked: opens in the viewer (sign in there once; it remembers).
private struct ArtifactRow: View {
    let row: WorkstreamActivity.AgentArtifact
    let tab: TabInfo
    let agent: String?
    let now: Date
    var pinned = false
    @Environment(WorkstreamsModel.self) private var store
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        let url = row.artifact.url
        let title = row.artifact.title ?? ArtifactLinks.title(for: url)
        let open = tab.viewerItem == url
        Button { store.host.openInViewer(url, tab: tab.id, select: true) } label: {
            HStack(spacing: 6) {
                Image(systemName: url.hasPrefix("https://claude.ai/") ? "sparkles.rectangle.stack" : url.hasPrefix("/") ? "doc.text" : "doc.richtext")
                    .font(.system(size: 10.5)).foregroundStyle(theme.muted).frame(width: 14)
                Text(title).font(.system(size: 12.5))
                    .foregroundStyle(open ? theme.text : theme.secondary).lineLimit(1)
                if let agent { Text(agent).font(.system(size: 11)).foregroundStyle(theme.muted).lineLimit(1) }
                Spacer(minLength: 4)
                Text(PanelSectionTime.short(row.artifact.at, now: now)).font(.system(size: 11)).monospacedDigit().foregroundStyle(theme.muted)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(open ? theme.selected : hovering ? theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(url.hasPrefix("/") ? url.abbreviatingHome : url)
        .contextMenu {
            Button(pinned ? "Unpin" : "Pin") {
                store.togglePinnedArtifact(TranscriptFacts.Artifact(url: url, title: title, at: row.artifact.at), in: tab)
            }
            Divider()
            Button("Copy Title") { copy(title) }
            Button(url.hasPrefix("/") ? "Copy Path" : "Copy Link") { copy(url) }
        }
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// Usage for the agent in this tab, from its transcript, with Claude's exact figures from the status line
/// when the wrapper saves them; and a total when several agents share the workstream. Folded by default.
private struct StatsSection: View {
    let tab: TabInfo
    let agents: [TabInfo]
    let now: Date
    @Environment(WorkstreamsModel.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        let session = tab.agentSession
        let facts = session.flatMap { store.transcriptFacts[$0] }
        let status = session.flatMap { store.statusLine(forSession: $0, now: now) }
        if let facts, facts.firstAt != nil, !facts.usage.isEmpty || status != nil {
            PanelSection(key: "stats", title: "Stats", updated: nil, now: now, tab: tab, defaultOpen: false) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(rows(facts, status).enumerated()), id: \.offset) { _, row in
                        StatRow(label: row.0, value: row.1)
                    }
                }
            }
        }
    }

    private func rows(_ facts: TranscriptFacts, _ status: StatusLineFeed.Status?) -> [(String, String)] {
        var rows: [(String, String)] = []
        rows.append(("Cost", status?.costUSD.map { Stat.money($0) } ?? "≈ " + Stat.money(Pricing.cost(facts))))
        let wall = status?.durationSeconds ?? facts.lastAt.flatMap { last in facts.firstAt.map { last.timeIntervalSince($0) } } ?? 0
        let api = status?.apiDurationSeconds.map { Stat.duration($0) + " API" } ?? (facts.activeSeconds > 0 ? Stat.duration(facts.activeSeconds) + " in turns" : nil)
        rows.append(("Time", [Stat.duration(wall) + " wall", api].compactMap { $0 }.joined(separator: " · ")))
        for (model, usage) in facts.usage.sorted(by: { Pricing.cost($0.value, model: $0.key) > Pricing.cost($1.value, model: $1.key) }) {
            rows.append((model.replacingOccurrences(of: "claude-", with: ""),
                         "\(Stat.tokens(usage.input)) in · \(Stat.tokens(usage.output)) out · \(Stat.tokens(usage.cacheRead)) cache read · \(Stat.tokens(usage.cacheWrite)) cache write"))
        }
        let total = facts.totalUsage
        if total.allInput > 0 { rows.append(("Cache", "\(Int((Double(total.cacheRead) / Double(total.allInput) * 100).rounded()))% of input from cache")) }
        let added = status?.linesAdded ?? facts.linesAdded, removed = status?.linesRemoved ?? facts.linesRemoved
        let edited = facts.files.values.filter { $0.edits > 0 }.count
        rows.append(("Work", "+\(Stat.count(added)) −\(Stat.count(removed)) lines · \(Stat.count(edited)) files · \(Stat.count(facts.toolCalls)) tool calls"
                     + (facts.compactions > 0 ? " · \(facts.compactions) compaction\(facts.compactions == 1 ? "" : "s")" : "")))
        var current: [String] = []
        if let percent = status?.contextUsedPercent { current.append("context \(Int(percent.rounded()))%") }
        if let five = store.host.rateLimitsUsed.fiveHour { current.append("5h \(Int(five.rounded()))%") }
        if let seven = store.host.rateLimitsUsed.sevenDay { current.append("7d \(Int(seven.rounded()))%") }
        if !current.isEmpty { rows.append(("Now", current.joined(separator: " · "))) }
        let others = agents.filter { $0.id != tab.id }.compactMap { agent -> (TranscriptFacts, StatusLineFeed.Status?)? in
            guard let session = agent.agentSession, let facts = store.transcriptFacts[session] else { return nil }
            return (facts, store.statusLine(forSession: session, now: now))
        }
        if !others.isEmpty {
            let all = [(facts, status)] + others
            let exact = all.allSatisfy { $0.1?.costUSD != nil }
            let cost = all.reduce(0) { $0 + ($1.1?.costUSD ?? Pricing.cost($1.0)) }
            let tokens = all.reduce(0) { $0 + $1.0.totalUsage.allInput + $1.0.totalUsage.output }
            rows.append(("All agents", (exact ? "" : "≈ ") + Stat.money(cost) + " · \(Stat.tokens(tokens)) tokens · \(all.count) agents"))
        }
        return rows
    }
}

private struct StatRow: View {
    let label: String
    let value: String
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(theme.secondary).lineLimit(1).frame(width: 76, alignment: .leading)
            Text(value).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
}

/// Number formats for Stats.
enum Stat {
    static func money(_ dollars: Double) -> String {
        dollars >= 100 ? String(format: "$%.0f", dollars) : String(format: "$%.2f", dollars)
    }

    /// 950, 12.4k, 3.0M, 2.1B.
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        if d >= 1e9 { return String(format: "%.1fB", d / 1e9) }
        if d >= 1e6 { return String(format: "%.1fM", d / 1e6) }
        if d >= 1e4 { return String(format: "%.0fk", d / 1e3) }
        if d >= 1e3 { return String(format: "%.1fk", d / 1e3) }
        return "\(n)"
    }

    static func count(_ n: Int) -> String { n.formatted(.number.grouping(.automatic)) }

    /// 45s, 12m, 3h 20m, 10d 13h.
    static func duration(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86_400)d \(s % 86_400 / 3600)h"
    }
}
