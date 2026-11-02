# agentde-workstreams

An AgentDE extension that shows each agent's **workstream** beside its chat. A workstream is the shared record of a piece of work (overview, rules, memory, questions waiting on you, progress, files, tickets), kept current by the agents through the `workstream` MCP server from [workstream-mcp](../workstream-mcp).

| Adds | What |
|---|---|
| Workstream panel | The side panel of every agent tab: a picker (switch, new, rename), then Waiting on you, FYI, Overview, Tickets, Rules, Agents, Messages, Memory, Progress, Plan, Scheduled, Files, Artifacts and Stats |
| Tab environment | `WORKSTREAM_TAB_ID` and `WORKSTREAM_ID` in each tab, so the MCP server knows which workstream an agent belongs to (plus `WORKSTREAM_DIR` when it isn't the default) |
| New → Workstream… | In a group's right-click menu: names a piece of work, makes a git worktree on a new branch of that name from the remote's default branch (`origin/HEAD`; else what's checked out), in `<repo>-worktrees/<name>` beside the repo, and opens a Claude tab there on a new workstream |
| ◇ Pin | In the viewer's header: pins the file shown to the tab's workstream |
| Attention ring | A soft amber ring on tabs whose agent asked something without stopping |
| Usage widget | How long agents worked and roughly what it cost, per workstream, for today, 7 days or all time (needs `agentde-widgets`) |
| Overlap notes | One FYI per pair of agents in one group's folder that edit the same files within 30 minutes, listing the files |

Worktrees and branches are never removed for you: merge the branch, then `git worktree remove <folder>`. Tickets are tracker-neutral (`ENG-123`, `acme/app#12`, or a link); their live state shows when an extension provides a ticket provider for the tracker, such as `agentde-linear`.

Panel sections, the file format and the server's tools: [workstream-mcp/docs/WORKSTREAMS.md](../workstream-mcp/docs/WORKSTREAMS.md).

## Include it

It's in AgentDE's default `extensions.json`, so building AgentDE clones it (and `agentde-widgets` and `workstream-mcp`) beside `agentde/`, with the server as a helper bundled into the app:

```json
{ "package": "../agentde-workstreams", "product": "AgentDEWorkstreams", "create": "WorkstreamsExtension()",
  "helpers": [{ "package": "../workstream-mcp", "product": "workstream-mcp" }] }
```

Then register the server once for Claude Code and Codex, from `agentde/`:

```bash
make register-workstream          # shows the changes
make register-workstream YES=1    # makes them
```

## Settings

None of its own. Layout → Side Panel (⌥⌘I) hides the panel for a tab. Workstream files are in `~/.config/workstreams/`.

## License

MIT; see [LICENSE](LICENSE).
