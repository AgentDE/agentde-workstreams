import AgentDEKit
import AppKit
import Observation
import SwiftUI
import WorkstreamKit

/// Workstreams (docs/WORKSTREAMS.md): information objects attached to agents. Each agent tab has one active
/// workstream (kept with the tab as this extension's "id" value); a workstream can have several agents. The
/// session index (agent session → workstream, from the files' `agents`) is the source of truth for a running
/// agent, so when an agent switches through the MCP server its tab follows. Files are read off the main
/// thread and published here; the folder, Claude's task lists and its transcripts are watched with FSEvents.
@Observable
public final class WorkstreamsModel {
    /// Workstreams by id, as last read from their files.
    var workstreams: [String: Workstream] = [:]
    /// Agent sessions' own to-do lists (Claude's task lists), by session id, loaded when first shown.
    var plans: [String: PlanList] = [:]
    /// What agent sessions scheduled with Claude's own tools, read from their transcripts, by session id.
    var schedules: [String: Schedule] = [:]
    /// What each agent session's transcript says it touched, published, sent and spent (`TranscriptFacts`).
    var transcriptFacts: [String: TranscriptFacts] = [:]

    @ObservationIgnored unowned let ext: WorkstreamsExtension
    @ObservationIgnored var host: AgentDEHost { ext.host! }
    /// Workstream files: `WORKSTREAM_DIR`, else beside a test instance's state file, else `~/.config/workstreams`.
    @ObservationIgnored lazy var workstreamStore: WorkstreamStore = {
        let env = ProcessInfo.processInfo.environment
        if env["WORKSTREAM_DIR"] == nil, let state = env["AGENTDE_STATE"] {
            return WorkstreamStore(directory: URL(fileURLWithPath: state).deletingLastPathComponent().appendingPathComponent("workstreams"))
        }
        return WorkstreamStore()
    }()
    @ObservationIgnored let workstreamQueue = DispatchQueue(label: "agentde.workstreams", qos: .utility)
    /// Reads transcripts (long ones can take a while the first time), apart from the workstream files.
    @ObservationIgnored let transcriptQueue = DispatchQueue(label: "agentde.transcripts", qos: .utility)
    @ObservationIgnored var workstreamWatcher: FileWatcher?
    @ObservationIgnored var workstreamSessionIndex: [String: String] = [:]
    @ObservationIgnored var workstreamsLoaded = false
    @ObservationIgnored var pendingSessionAttachments = Set<String>()
    /// Transcript readers (schedule and facts); used only on `transcriptQueue`. `saved` is the offset last
    /// written to the snapshot cache.
    @ObservationIgnored var transcriptScanners: [String: (url: URL, scanner: TranscriptScanner, saved: UInt64, savedAt: Date)] = [:]
    /// Overlapping edits already noted, by key (file and pair of agents), with when; kept a day.
    @ObservationIgnored var notedOverlaps: [String: Date] = [:]
    /// Status line input saved by the `workstream-mcp statusline` wrapper, read for Stats, cached by file date.
    @ObservationIgnored var statusLineCache: [String: (checked: Date, status: StatusLineFeed.Status?)] = [:]
    /// Registry polls in a row each asking agent session has been missing for.
    @ObservationIgnored var missingAskSessions: [String: Int] = [:]
    /// Fires at the next ask deadline.
    @ObservationIgnored var askDeadlineTimer: DispatchSourceTimer?
    /// Tickets looked up in their trackers, by identifier.
    var ticketInfo: [String: TicketInfo] = [:]
    /// The user's own open tickets in every signed-in tracker, for linking one.
    var myTickets: [TicketInfo] = []

    init(ext: WorkstreamsExtension) { self.ext = ext }

    // MARK: Tabs

    /// The workstream a tab shows (kept with the tab).
    func workstreamID(of tab: TabInfo) -> String? { host.value("id", tab: tab.id, for: ext) }
    func setWorkstreamID(_ id: String?, of tab: UUID) { host.setValue(id, "id", tab: tab, for: ext) }
    var tabs: [TabInfo] { host.allTabs }

    /// Panel sections the user opened or collapsed in a tab (key → open); others use their default.
    func panelSections(of tab: TabInfo) -> [String: Bool]? {
        host.value("sections", tab: tab.id, for: ext).flatMap { try? JSONDecoder().decode([String: Bool].self, from: Data($0.utf8)) }
    }

    func setPanelSection(_ key: String, open: Bool, in tab: UUID) {
        guard let info = host.tabInfo(tab) else { return }
        let sections = (panelSections(of: info) ?? [:]).merging([key: open]) { $1 }
        host.setValue((try? JSONEncoder().encode(sections)).map { String(decoding: $0, as: UTF8.self) }, "sections", tab: tab, for: ext)
    }

    /// Refreshes `myTickets` from every signed-in tracker.
    func loadMyTickets() {
        var collected: [ObjectIdentifier: [TicketInfo]] = [:]
        for provider in ticketProviders where provider.isReady {
            provider.myTickets { [weak self] found in
                collected[ObjectIdentifier(provider)] = found
                let all = collected.values.flatMap { $0 }
                if self?.myTickets != all { self?.myTickets = all }
            }
        }
    }

    // MARK: Lookup

    func workstream(for tab: TabInfo) -> Workstream? { workstreamID(of: tab).flatMap { workstreams[$0] } }

    func workstreamID(forSession session: String) -> String? { workstreamSessionIndex[session] }

    /// Open asks from this tab's agent (or from no agent in particular).
    func openAsks(for tab: TabInfo) -> [Workstream.Ask] {
        let session = tab.agentSession
        return (workstream(for: tab)?.openAsks ?? []).filter { $0.agent == nil || $0.agent == session }
    }

    func hasOpenAsk(_ tab: TabInfo) -> Bool { !openAsks(for: tab).isEmpty }

    /// The tabs (agents) attached to a workstream, in the order they joined.
    func agentTabs(of workstream: Workstream) -> [TabInfo] {
        let tabs = self.tabs
        var result: [TabInfo] = []
        for agent in workstream.agents {
            if let tab = tabs.first(where: { $0.agentSession == agent.session || $0.id.uuidString == agent.tab }),
               !result.contains(where: { $0.id == tab.id }) {
                result.append(tab)
            }
        }
        // Tabs pointing at it whose agent hasn't started yet.
        for tab in tabs where workstreamID(of: tab) == workstream.id && !result.contains(where: { $0.id == tab.id }) { result.append(tab) }
        return result
    }

    /// Its own name, else its first agent's, else (before the tab's agent has joined it) the tab's.
    func workstreamName(_ workstream: Workstream?, tab: TabInfo? = nil) -> String {
        if let name = workstream?.name, !name.isEmpty { return name }
        if let workstream, let first = agentTabs(of: workstream).first { return first.title }
        if let tab { return tab.title }
        return "Untitled workstream"
    }

    /// Workstreams a tab's agent can switch to: those of its group's folder and those its group's tabs use.
    func workstreams(forGroupOf tab: TabInfo) -> [Workstream] {
        let used = Set(tabs.filter { $0.groupID == tab.groupID }.compactMap { workstreamID(of: $0) })
        return workstreams.values.filter { used.contains($0.id) || $0.folder == tab.groupFolder }
            .sorted { workstreamName($0).localizedCaseInsensitiveCompare(workstreamName($1)) == .orderedAscending }
    }

    // MARK: Startup and following agents

    /// Gives each agent tab without one a workstream id of its own.
    func assignWorkstreams() {
        for tab in tabs where tab.isAgent && workstreamID(of: tab) == nil { setWorkstreamID(UUID().uuidString, of: tab.id) }
    }

    /// Gives restored tabs without one a workstream id, then loads the workstreams and starts watching.
    func startWorkstreams() {
        assignWorkstreams()
        try? FileManager.default.createDirectory(at: workstreamStore.directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // FSEvents reports real paths (`/private/tmp/…`), which `resolvingSymlinksInPath` would shorten.
        let workstreamsPath = FileWatcher.realPath(workstreamStore.directory.path)
        let tasksPath = FileWatcher.realPath(NativePlan.claudeTasksDirectory.path)
        let projectsPath = FileWatcher.realPath(NativeSchedule.projectsDirectory.path)
        let claudePath = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude").path
        let codexPath = FileWatcher.realPath(CodexLogs.directory.path)
        let watched = [workstreamsPath] + [tasksPath, projectsPath, codexPath].filter { FileManager.default.fileExists(atPath: $0) }
            + (FileManager.default.fileExists(atPath: tasksPath) ? [] : [claudePath])
        workstreamWatcher = FileWatcher(paths: watched, latency: 0.5, queue: workstreamQueue) { [weak self] paths in
            var workstreamsChanged = false
            var planSessions = Set<String>()
            var transcriptSessions = Set<String>()
            for path in paths {
                if path.hasPrefix(workstreamsPath + "/") || path == workstreamsPath {
                    workstreamsChanged = true
                } else if path.hasPrefix(tasksPath + "/") {
                    let rest = path.dropFirst(tasksPath.count + 1)
                    if let folder = rest.split(separator: "/").first { planSessions.insert(String(folder)) }
                } else if path.hasPrefix(projectsPath + "/"), path.hasSuffix(".jsonl") {
                    transcriptSessions.insert(((path as NSString).lastPathComponent as NSString).deletingPathExtension)
                } else if path.hasPrefix(codexPath + "/"), path.hasSuffix(".jsonl") {
                    // rollout-<time>-<session id>.jsonl
                    let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                    if name.count > 36 { transcriptSessions.insert(String(name.suffix(36))) }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if workstreamsChanged { self.reloadWorkstreams() }
                let loaded = planSessions.filter { self.plans[$0] != nil }
                if !loaded.isEmpty { self.loadPlans(Array(loaded)) }
                let attached = transcriptSessions.filter { self.workstreamSessionIndex[$0] != nil }
                if !attached.isEmpty { self.loadTranscripts(Array(attached)) }
            }
        }
        reloadWorkstreams()
    }

    /// Re-reads every workstream file (they're small), publishes the ones that changed, and takes requests.
    func reloadWorkstreams() {
        let store = workstreamStore
        workstreamQueue.async { [weak self] in
            let all = store.all()
            let requests = store.takeRequests()
            DispatchQueue.main.async {
                guard let self else { return }
                let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                if byID != self.workstreams { self.workstreams = byID }
                let index = WorkstreamStore.sessionIndex(all)
                let newSessions = Set(index.keys).subtracting(self.workstreamSessionIndex.keys)
                self.workstreamSessionIndex = index
                self.workstreamsLoaded = true
                self.followSessionIndex()
                self.attachAgentSessions()
                for request in requests { self.handle(request) }
                if !newSessions.isEmpty { self.loadTranscripts(Array(newSessions)) }
                self.takeDueDefaults()
                self.removeExpiredNotes()
            }
        }
    }

    /// A running agent's workstream is whichever one lists its session; its tab follows (an agent can
    /// switch through the MCP server).
    func followSessionIndex() {
        for tab in tabs {
            guard let session = tab.agentSession, let id = workstreamSessionIndex[session], workstreamID(of: tab) != id else { continue }
            setWorkstreamID(id, of: tab.id)
        }
    }

    /// Attaches each tab's agent session to the tab's workstream when no workstream lists it yet (a new
    /// agent, or a `/clear` in the tab), or back to the one it left (a resume), and records the tab on its entry. Writes only what's missing.
    func attachAgentSessions() {
        guard workstreamsLoaded else { return }
        let former = WorkstreamStore.formerIndex(Array(workstreams.values))
        assignWorkstreams()
        do {
            for tab in tabs {
                guard let id = workstreamID(of: tab), let session = tab.agentSession else { continue }
                let current = workstreamSessionIndex[session]
                let entry = current.flatMap { workstreams[$0] }?.agents.first { $0.session == session }
                if current != nil, entry?.tab == tab.id.uuidString { continue }
                // A resumed session rejoins the workstream it left when its tab closed; the tab follows it there.
                let target = current ?? former[session] ?? id
                let key = target + "/" + session
                guard !pendingSessionAttachments.contains(key) else { continue }
                pendingSessionAttachments.insert(key)
                let store = workstreamStore
                let kind = tab.kind == .codex ? "codex" : "claude"
                let tabID = tab.id.uuidString
                let folder = tab.groupFolder
                workstreamQueue.async { [weak self] in
                    do {
                        // Decided from the index as last read; `adopt` checks the files again, so an agent that
                        // switched in the meantime (say, a fork that started its own workstream) stays put.
                        try store.adopt(session: session, kind: kind, tab: tabID, fallback: target, folder: folder)
                    } catch {
                        DebugLog.log("couldn't attach session \(session.prefix(8)) to workstream \(target.prefix(8)): \(error)", "workstream")
                    }
                    DispatchQueue.main.async { self?.pendingSessionAttachments.remove(key) }
                }
            }
        }
    }

    /// A tab closed: its agent leaves its workstream (its open asks go too); the workstream stays.
    func detachAgent(of tab: TabInfo) {
        guard let id = workstreamID(of: tab), let session = tab.agentSession else { return }
        modifyWorkstream(id) { $0.detach(session: session) }
    }

    /// Agent sessions that ended: their open asks are cleared. Called with each registry poll; a Claude
    /// session counts as ended after three polls without it.
    func updateLiveSessions(_ live: Set<String>) {
        guard workstreamsLoaded else { return }
        for workstream in workstreams.values {
            for ask in workstream.openAsks {
                guard let session = ask.agent,
                      workstream.agents.first(where: { $0.session == session })?.kind ?? "claude" == "claude" else { continue }
                if live.contains(session) {
                    missingAskSessions[session] = nil
                } else {
                    missingAskSessions[session, default: 0] += 1
                    if missingAskSessions[session] == 3 {
                        DebugLog.log("session \(session.prefix(8)) ended; clearing its asks in \(workstream.id.prefix(8))", "workstream")
                        modifyWorkstream(workstream.id) { $0.clearAsks(of: session) }
                    }
                }
            }
        }
    }

    /// Something an agent asked for through the MCP server.
    private func handle(_ request: WorkstreamStore.Request) {
        let tabs = self.tabs
        let tab = tabs.first { request.session != nil && $0.agentSession == request.session }
            ?? tabs.first { $0.id.uuidString == request.tab }
        guard let tab else { return }
        switch request.action {
        case "open":
            if let path = request.path { host.openInViewer(path, tab: tab.id, select: false) }
        default:
            DebugLog.log("unknown workstream request \(request.action)", "workstream")
        }
    }

    // MARK: Ask deadlines

    /// Resolves asks whose deadline passed with their default: the default is typed into the asking agent's
    /// chat like an answer, once that agent is idle (otherwise when it next goes idle). An agent whose tab
    /// isn't open gets it when the tab reappears. Then sets the one timer for the next deadline.
    func takeDueDefaults(now: Date = Date()) {
        let tabs = self.tabs
        for workstream in workstreams.values {
            for ask in workstream.openAsks {
                guard let option = ask.defaultOption, let deadline = ask.decideBy, deadline <= now, let session = ask.agent,
                      let tab = tabs.first(where: { $0.agentSession == session }),
                      tab.agentPresent, tab.state == .none || tab.state == .doneUnseen else { continue }
                DebugLog.log("ask \(ask.id) in \(workstream.id.prefix(8)) defaulted to \(option)", "workstream")
                host.type(ask.reply(option, byDefault: true) + "\r", into: tab.id)
                modifyWorkstream(workstream.id) { $0.resolve(ask: ask.id, by: "default", answer: option) }
            }
        }
        askDeadlineTimer?.cancel()
        askDeadlineTimer = nil
        let next = workstreams.values.flatMap(\.openAsks)
            .compactMap { $0.defaultOption != nil ? $0.decideBy : nil }.filter { $0 > now }.min()
        guard let next else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + next.timeIntervalSince(now) + 0.5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.takeDueDefaults() }
        timer.resume()
        askDeadlineTimer = timer
    }

    // MARK: Switching

    /// Makes `id` the tab's workstream; its agent moves over (its open asks stay where they were asked).
    func switchWorkstream(of tabID: UUID, to id: String) {
        guard let tab = host.tabInfo(tabID), workstreamID(of: tab) != id else { return }
        setWorkstreamID(id, of: tabID)
        let folder = tab.groupFolder
        guard let session = tab.agentSession else {
            if workstreams[id] == nil { modifyWorkstream(id) { $0.folder = folder } }
            return
        }
        workstreamSessionIndex[session] = id
        for (other, workstream) in workstreams where other != id && workstream.agents.contains(where: { $0.session == session }) {
            workstreams[other]?.detach(session: session, clearAsks: false)
        }
        workstreams[id, default: Workstream(id: id, folder: folder)].attach(session: session, kind: tab.kind == .codex ? "codex" : "claude", tab: tab.id.uuidString)
        let store = workstreamStore
        let kind = tab.kind == .codex ? "codex" : "claude"
        workstreamQueue.async {
            do { try store.moveAgent(session: session, kind: kind, tab: tab.id.uuidString, to: id, folder: folder) } catch {
                DebugLog.log("couldn't move session \(session.prefix(8)) to workstream \(id.prefix(8)): \(error)", "workstream")
            }
        }
    }

    func newWorkstream(for tabID: UUID) {
        guard let tab = host.tabInfo(tabID) else { return }
        let id = UUID().uuidString
        let folder = tab.groupFolder
        modifyWorkstream(id) { $0.folder = folder }
        switchWorkstream(of: tabID, to: id)
    }

    /// New → Workstream… in a group's menu: asks for a name, makes a branch and worktree of that name beside the
    /// group's repo (`Worktrees`), and opens a Claude tab there on a new workstream of the same name. A group
    /// whose folder isn't in a git repo gets the named tab and workstream in its own folder.
    func newWorkstreamWithWorktree(in groupID: UUID) {
        guard let group = host.allGroups.first(where: { $0.id == groupID }) else { return }
        let root = Worktrees.repoRoot(of: group.folder)
        let alert = NSAlert()
        alert.messageText = "New workstream in \(group.name)"
        alert.informativeText = root.map {
            "Makes a branch of this name from \(Worktrees.baseBranch(repoRoot: $0) ?? "what's checked out"), "
                + "checks it out in \(Worktrees.path(repoRoot: $0, name: "…").abbreviatingHome), and starts Claude there."
        } ?? "\(group.folder.abbreviatingHome) isn't in a git repo, so Claude starts there, without a worktree."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "cold-match"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let name = Worktrees.validName(field.stringValue) else {
            host.showProblem("“\(field.stringValue)” can't be a branch name",
                        "Use letters, digits, dots, dashes and underscores, starting with a letter or digit.")
            return
        }
        guard let root else { return openWorkstreamTab(name, folder: group.folder, in: groupID) }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Worktrees.add(repoRoot: root, name: name)
            DispatchQueue.main.async { [self] in
                switch result {
                case .failure(let error): host.showProblem("Couldn't make the worktree for \(name)", error.message)
                case .success(let base):
                    DebugLog.log("new worktree \(name) from \(base) for group \(group.name)", "workstream")
                    openWorkstreamTab(name, folder: Worktrees.path(repoRoot: root, name: name), in: groupID)
                }
            }
        }
    }

    private func openWorkstreamTab(_ name: String, folder: String, in groupID: UUID) {
        let workstream = UUID().uuidString
        modifyWorkstream(workstream) { $0.folder = folder; $0.name = name }
        guard let id = host.openTab(kind: .claude, in: groupID, folder: folder, title: name) else { return }
        setWorkstreamID(workstream, of: id)
    }

    func renameWorkstream(_ id: String) {
        let alert = NSAlert()
        alert.messageText = "Rename workstream"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = workstreams[id]?.name ?? workstreamName(workstreams[id])
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        modifyWorkstream(id) { $0.name = name.isEmpty ? nil : name }
    }

    // MARK: Plans and schedules

    /// The agent session's own to-do list, loading it in the background the first time it's asked for.
    func plan(forSession session: String) -> PlanList? {
        if let plan = plans[session] { return plan }
        loadPlans([session])
        return nil
    }

    func loadPlans(_ sessions: [String]) {
        workstreamQueue.async { [weak self] in
            let loaded = sessions.map { ($0, NativePlan.claudeTasks(session: $0)) }
            DispatchQueue.main.async {
                guard let self else { return }
                for (session, steps) in loaded where self.plans[session] != steps { self.plans[session] = steps }
            }
        }
    }

    /// What an agent session has scheduled with Claude's own tools, read from its transcript.
    func scheduledItems(forSession session: String, now: Date) -> [ScheduledItem] {
        schedules[session]?.items(now: now, sessionLive: host.liveSessions.contains(session)) ?? []
    }

    /// Re-reads the new part of these sessions' transcripts (each scanner reads only what was appended), for
    /// Scheduled, Files, Messages, Artifacts and Stats, then looks for overlapping edits. A scanner starts from
    /// its snapshot in the cache (`TranscriptCache`), and the snapshot is refreshed as it reads, so a long
    /// transcript is read once rather than on every launch.
    func loadTranscripts(_ sessions: [String]) {
        let kinds = Dictionary(workstreams.values.flatMap(\.agents).map { ($0.session, $0.kind) }, uniquingKeysWith: { a, _ in a })
        transcriptQueue.async { [weak self] in
            guard let self else { return }
            var updated: [(String, Schedule, TranscriptFacts)] = []
            for session in sessions {
                if self.transcriptScanners[session] == nil {
                    let format: TranscriptScanner.Format = kinds[session] == "codex" ? .codex : .claude
                    let url = format == .codex ? CodexLogs.log(session: session) : NativeSchedule.transcript(session: session)
                    guard let url else { continue }
                    let scanner = TranscriptCache.scanner(session: session, format: format)
                    self.transcriptScanners[session] = (url, scanner, scanner.offset, Date())
                }
                guard var entry = self.transcriptScanners[session] else { continue }
                entry.scanner.scan(entry.url)
                let advanced = entry.scanner.offset > entry.saved
                if advanced, entry.scanner.offset - entry.saved >= 2 << 20 || Date().timeIntervalSince(entry.savedAt) > 120 {
                    TranscriptCache.save(entry.scanner, session: session)
                    entry.saved = entry.scanner.offset
                    entry.savedAt = Date()
                    self.transcriptScanners[session] = entry
                }
                updated.append((session, entry.scanner.schedule, entry.scanner.currentFacts))
            }
            DispatchQueue.main.async {
                for (session, schedule, facts) in updated {
                    if self.schedules[session] != schedule { self.schedules[session] = schedule.isEmpty ? nil : schedule }
                    if self.transcriptFacts[session] != facts { self.transcriptFacts[session] = facts }
                }
                if !updated.isEmpty { self.noteOverlaps() }
            }
        }
    }

    /// Writes every scanner's snapshot that's behind (at quit), so the next launch picks up where this one stopped.
    func saveTranscriptSnapshots() {
        transcriptQueue.sync {
            for (session, entry) in transcriptScanners where entry.scanner.offset > entry.saved {
                TranscriptCache.save(entry.scanner, session: session)
            }
        }
    }

    /// The transcript facts of a workstream's agents, merged (Files' Recent and High activity, Messages, Artifacts).
    func activity(of workstream: Workstream?) -> WorkstreamActivity {
        WorkstreamActivity((workstream?.agents ?? []).compactMap { agent in transcriptFacts[agent.session].map { (agent.session, $0) } })
    }

    /// Two agents in one group's folder editing the same file within half an hour: each one's workstream gets
    /// an FYI from AgentDE (one, if they share a workstream). Noted once per file and pair; notes last a day.
    func noteOverlaps(now: Date = Date()) {
        if notedOverlaps.isEmpty, let saved = UserDefaults.standard.dictionary(forKey: "notedOverlaps") as? [String: Double] {
            notedOverlaps = saved.mapValues { Date(timeIntervalSince1970: $0) }
        }
        notedOverlaps = notedOverlaps.filter { now.timeIntervalSince($0.value) < 86_400 }
        var noted = false
        for group in host.allGroups {
            let agents = tabs.filter { $0.groupID == group.id }.compactMap { tab -> (tab: TabInfo, session: String, facts: TranscriptFacts)? in
                guard let session = tab.agentSession, let facts = transcriptFacts[session] else { return nil }
                return (tab, session, facts)
            }
            guard agents.count >= 2 else { continue }
            let byID = Dictionary(agents.map { ($0.tab.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
            // One note per pair of agents, listing every file they share, rewritten when a file is added.
            for (pair, paths) in Self.overlapsByPair(Overlaps.find(agents.map { ($0.tab.id.uuidString, $0.facts) }, now: now)) {
                guard let a = byID[pair.first], let b = byID[pair.second] else { continue }
                let keys = paths.map { [$0, a.session, b.session].sorted().joined(separator: "|") }
                guard keys.contains(where: { notedOverlaps[$0] == nil }) else { continue }
                for key in keys { notedOverlaps[key] = now }
                noted = true
                let files = paths.map { ($0 as NSString).lastPathComponent }
                let id = "ov-" + String(Self.stableHash([a.session, b.session].sorted().joined(separator: "|")), radix: 36)
                let expires = now.addingTimeInterval(86_400)
                DebugLog.log("overlapping edits of \(files.joined(separator: ", ")) by \(a.tab.title) and \(b.tab.title)", "workstream")
                if let wa = workstreamID(of: a.tab), wa == workstreamID(of: b.tab) {
                    let text = Self.overlapText(files, a.tab.title, b.tab.title)
                    modifyWorkstream(wa) { $0.replaceNote(.init(id: id, text: text, at: now, by: "app", expires: expires), at: now) }
                } else {
                    for (me, other) in [(a, b), (b, a)] {
                        guard let workstream = workstreamID(of: me.tab) else { continue }
                        let text = Self.overlapText(files, nil, other.tab.title)
                        modifyWorkstream(workstream) {
                            $0.replaceNote(.init(id: id, text: text, agent: me.session, at: now, by: "app", expires: expires), at: now)
                        }
                    }
                }
            }
        }
        if noted {
            UserDefaults.standard.set(notedOverlaps.mapValues(\.timeIntervalSince1970), forKey: "notedOverlaps")
        }
    }

    /// Overlapping files grouped by the pair of agents (tab ids) editing them, files in a stable order.
    static func overlapsByPair(_ overlaps: [Overlaps.Overlap]) -> [(pair: (first: String, second: String), paths: [String])] {
        var byPair: [String: (first: String, second: String, paths: [String])] = [:]
        for overlap in overlaps {
            let (first, second) = overlap.first < overlap.second ? (overlap.first, overlap.second) : (overlap.second, overlap.first)
            byPair[first + "|" + second, default: (first, second, [])].paths.append(overlap.path)
        }
        return byPair.keys.sorted().map { key in
            let entry = byPair[key]!
            return ((entry.first, entry.second), Array(Set(entry.paths)).sorted())
        }
    }

    /// "x.py is being edited by both A and B", or for an agent's own note, "x.py is also being edited by B";
    /// several files are listed, the first four by name.
    static func overlapText(_ files: [String], _ me: String?, _ other: String) -> String {
        let shown = files.prefix(4).joined(separator: ", ") + (files.count > 4 ? " and \(files.count - 4) more" : "")
        if files.count == 1 { return me.map { "\(shown) is being edited by both \($0) and \(other)" } ?? "\(shown) is also being edited by \(other)" }
        return me.map { "\(files.count) files are being edited by both \($0) and \(other): \(shown)" }
            ?? "\(files.count) files are also being edited by \(other): \(shown)"
    }

    /// FNV-1a, so a note's id is the same across launches.
    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return hash
    }

    /// Drops FYI notes past their expiry from the files.
    func removeExpiredNotes(now: Date = Date()) {
        for (id, workstream) in workstreams where (workstream.fyi?.items ?? []).contains(where: { ($0.expires ?? .distantFuture) <= now }) {
            modifyWorkstream(id) { $0.removeExpiredNotes(now: now) }
        }
    }

    /// Claude's latest status line input for a session, when the `workstream-mcp statusline` wrapper saves it.
    /// Read at most every 10 seconds.
    func statusLine(forSession session: String, now: Date = Date()) -> StatusLineFeed.Status? {
        if let cached = statusLineCache[session], now.timeIntervalSince(cached.checked) < 10 { return cached.status }
        let status = StatusLineFeed.read(session: session)
        statusLineCache[session] = (now, status)
        return status
    }

    /// Durable jobs Claude keeps in a folder's `.claude/scheduled_tasks.json`.
    func durableJobs(folder: String?, now: Date) -> [ScheduledItem] {
        guard let folder else { return [] }
        return NativeSchedule.durableJobs(folder: folder, now: now)
    }

    // MARK: Changes from the panel

    /// Answers an ask: types the answer, with its question, into the asking agent's chat, then removes the ask.
    func answer(_ ask: Workstream.Ask, with option: String, in tab: TabInfo) {
        guard let id = workstreamID(of: tab) else { return }
        let target = tabs.first { ask.agent != nil && $0.agentSession == ask.agent } ?? tab
        host.type(ask.reply(option) + "\r", into: target.id)
        modifyWorkstream(id) { $0.resolve(ask: ask.id, by: "you", answer: option) }
    }

    /// Links a ticket (a key like ENG-123, owner/repo#12, or a link) to the tab's workstream; false if it isn't one.
    @discardableResult
    func linkTicket(_ text: String, title: String? = nil, in tab: TabInfo) -> Bool {
        guard let id = workstreamID(of: tab), let ticket = Workstream.ticketReference(in: text) else { return false }
        modifyWorkstream(id) { $0.linkTicket(ticket.identifier, title: title, url: ticket.url, tracker: ticket.tracker, by: "you") }
        lookUpTickets(in: id)
        return true
    }

    func unlinkTicket(_ identifier: String, in tab: TabInfo) {
        guard let id = workstreamID(of: tab) else { return }
        modifyWorkstream(id) { $0.unlinkTicket(identifier) }
    }

    /// Ticket providers from every extension (Linear, say).
    var ticketProviders: [TicketProvider] { host.extensions.flatMap(\.ticketProviders) }

    /// The provider for a ticket: its tracker's, else the first that claims a bare key.
    func provider(for ticket: Workstream.Ticket) -> TicketProvider? {
        let ready = ticketProviders.filter(\.isReady)
        if let tracker = ticket.tracker { return ready.first { $0.tracker == tracker } }
        return ready.first { $0.claims(identifier: ticket.identifier) }
    }

    /// Looks up a workstream's tickets in their trackers, and keeps the title and link of any that lack them in
    /// the file, so agents (and the app without a tracker signed in) see them too.
    func lookUpTickets(in workstreamID: String) {
        let tickets = workstreams[workstreamID]?.tickets?.items ?? []
        let byProvider = Dictionary(grouping: tickets.compactMap { ticket in provider(for: ticket).map { (ObjectIdentifier($0), $0, ticket) } },
                                    by: \.0)
        for (_, entries) in byProvider {
            entries[0].1.lookUp(entries.map(\.2.identifier)) { [weak self] found in
                guard let self else { return }
                for info in found where self.ticketInfo[info.identifier] != info { self.ticketInfo[info.identifier] = info }
                let missing = found.filter { info in
                    self.workstreams[workstreamID]?.tickets?.items.contains { $0.identifier == info.identifier && ($0.title != info.title || $0.url != info.url) } ?? false
                }
                guard !missing.isEmpty else { return }
                self.modifyWorkstream(workstreamID) { w in
                    for info in missing { w.linkTicket(info.identifier, title: info.title, url: info.url, by: "you") }
                }
            }
        }
    }

    /// Dismisses an ask without answering it, and tells the asking agent so in its chat, as an answer would.
    func dismissAsk(_ ask: Workstream.Ask, in tab: TabInfo) {
        guard let id = workstreamID(of: tab) else { return }
        let target = tabs.first { ask.agent != nil && $0.agentSession == ask.agent } ?? tab
        host.type(ask.dismissal + "\r", into: target.id)
        modifyWorkstream(id) { $0.resolve(ask: ask.id, by: "you", answer: nil) }
    }

    func removeMemory(_ itemID: String, in tab: TabInfo) {
        guard let id = workstreamID(of: tab) else { return }
        modifyWorkstream(id) { $0.removeMemory(itemID) }
    }

    func removeProgressRow(_ row: Workstream.ProgressRow, in tab: TabInfo) {
        guard let id = workstreamID(of: tab) else { return }
        modifyWorkstream(id) { $0.removeProgressRow(label: row.label, agent: row.agent) }
    }

    func dismissFYI(_ noteID: String, in tab: TabInfo) {
        guard let id = workstreamID(of: tab) else { return }
        modifyWorkstream(id) { $0.dismissFYI(noteID) }
    }

    func addRule(_ text: String, in tab: TabInfo) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = workstreamID(of: tab), !text.isEmpty else { return }
        modifyWorkstream(id) { $0.addRule(text, by: "you") }
    }

    func removeRule(_ ruleID: String, in tab: TabInfo) {
        guard let id = workstreamID(of: tab) else { return }
        modifyWorkstream(id) { $0.removeRule(ruleID) }
    }

    func togglePinned(_ path: String, in tab: TabInfo) {
        guard let id = workstreamID(of: tab) else { return }
        modifyWorkstream(id) { $0.togglePinned(path, by: "you") }
    }

    /// Applies a change now (so the panel updates at once) and writes it under the workstream's lock.
    func modifyWorkstream(_ id: String, _ change: @escaping (inout Workstream) -> Void) {
        var local = workstreams[id] ?? Workstream(id: id)
        change(&local)
        workstreams[id] = local
        let store = workstreamStore
        workstreamQueue.async {
            do { try store.update(id, change) } catch {
                DebugLog.log("couldn't update workstream \(id.prefix(8)): \(error)", "workstream")
            }
        }
    }
}
