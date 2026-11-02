import AgentDEKit
import AgentDEWidgets
import SwiftUI
import WorkstreamKit

/// Workstreams as a native extension: the panel beside each agent's chat, the `workstream` MCP server's
/// environment for each tab, and the Usage widget's numbers. See docs/WORKSTREAMS.md.
public final class WorkstreamsExtension: AgentDEExtension, WidgetProvider {
    public let id = "workstreams"
    public let name = "Workstreams"
    public private(set) var host: AgentDEHost?
    public private(set) lazy var model = WorkstreamsModel(ext: self)

    public init() {}

    public func start(host: AgentDEHost) {
        self.host = host
        // Links other extensions open in the viewer count as artifacts in the panel too.
        ArtifactLinks.rules = host.extensions.flatMap(\.linkRules).map {
            ArtifactLinks.Rule(pattern: $0.pattern, marker: $0.marker, canonical: $0.canonical, openURL: $0.openURL, title: $0.title)
        }
        model.startWorkstreams()
    }

    public func stop() { model.saveTranscriptSnapshots() }

    /// Usage: how long agents worked, and roughly what it cost, per workstream.
    public var widgets: [WidgetDefinition] {
        [WidgetDefinition(id: "usage", name: "Usage") { [model] in AnyView(UsageWidget().environment(model)) }]
    }

    public func launchEnvironment(for tab: TabInfo) -> [String: String] {
        guard host != nil else { return [:] }
        if model.workstreamID(of: tab) == nil { model.setWorkstreamID(UUID().uuidString, of: tab.id) }
        var env = [WorkstreamEnvironment.tabID: tab.id.uuidString]
        // The workstream this terminal's agent sessions attach to, for the `workstream` MCP server.
        if let id = model.workstreamID(of: tab) { env[WorkstreamEnvironment.workstreamID] = id }
        let dir = model.workstreamStore.directory.path
        if dir != WorkstreamStore.defaultDirectory.path { env["WORKSTREAM_DIR"] = dir }
        return env
    }

    public func agentSessionsChanged() { model.attachAgentSessions() }
    public func liveSessionsChanged(_ live: Set<String>) { model.updateLiveSessions(live) }
    public func agentWentIdle(_ tab: TabInfo) { model.takeDueDefaults() }

    public func tabClosing(_ tab: TabInfo, keepAgent: Bool) {
        if !keepAgent { model.detachAgent(of: tab) }
    }

    /// A fork joins the workstream of the agent it came from; any other background session gets a new one
    /// (Claude records no parent for those).
    public func backgroundSessionOpened(_ tab: TabInfo, session: String?, forkParent: String?) {
        if let session, let id = model.workstreamSessionIndex[session] {
            model.setWorkstreamID(id, of: tab.id)
        } else if let forkParent, let id = model.workstreamSessionIndex[forkParent] {
            model.setWorkstreamID(id, of: tab.id)
        }
    }

    public func wantsAttention(_ tab: TabInfo) -> Bool { host != nil && !model.openAsks(for: tab).isEmpty }

    public func panel(for tab: TabInfo) -> AnyView? {
        guard host != nil, tab.isAgent else { return nil }
        return AnyView(WorkstreamPanel(tab: tab).environment(model))
    }

    public func viewerAccessory(for tab: TabInfo, item: String) -> AnyView? {
        guard host != nil, !item.hasPrefix("http"), model.workstreamID(of: tab) != nil else { return nil }
        return AnyView(PinButton(tab: tab, item: item).environment(model))
    }

    public func title(forLink link: String, in tab: TabInfo) -> String? {
        guard host != nil else { return nil }
        return model.activity(of: model.workstream(for: tab)).artifacts(100).first { $0.artifact.url == link }?.artifact.title
    }

    public func newMenuItems(for group: GroupInfo) -> [ExtensionAction] {
        [ExtensionAction("Workstream…", symbol: "arrow.triangle.branch") { [weak self] in self?.model.newWorkstreamWithWorktree(in: group.id) }]
    }
}

/// ◇ Pin in the viewer's header: pins the file shown to the tab's workstream.
private struct PinButton: View {
    let tab: TabInfo
    let item: String
    @Environment(WorkstreamsModel.self) private var model
    @Environment(\.theme) private var theme

    var body: some View {
        let pinned = model.workstream(for: tab)?.files?.items.contains { $0.path == item } ?? false
        Button { model.togglePinned(item, in: tab) } label: {
            Text(pinned ? "◆ Pinned" : "◇ Pin").font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(pinned ? Color(hex: 0x3DF2A6) : theme.secondary)
                .padding(.horizontal, 6).frame(height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
