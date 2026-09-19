# Model context contract

## User image attachments

Chat messages can contain up to four still images selected, dropped, or pasted in the composer. Imports validate and normalize image data to JPEG (orientation applied, longest edge at most 2,048 pixels, source at most 25 MB, normalized output at most 4 MB). The message owns the normalized bytes and metadata in an optional SwiftData external-storage field; old text-only records need no backfill. Draft images live in memory until sent. Image-only messages retain empty user text; Chat does not supply an automatic image question or use empty text to rename a chat. Deleting the message deletes its attachment owner; resetting active history preserves archived messages as before.

For direct and group replies, attachment references travel with the retained messages. ChatGPT stages images inside the existing private, ephemeral provider directory and sends labelled `localImage` input items; its model catalog is checked for explicit image incompatibility. Local OpenAI-compatible servers receive text and `image_url` content parts with JPEG data URLs. Text-only requests retain string content. Apple uses native macOS 27 `Attachment` prompt elements after a vision capability check; image-bearing conversations use the labelled transcript plus image attachments, while text-only conversations keep the existing seeded transcript path. No provider silently strips images or switches models. Local models have a persisted Supports images switch in Settings → Models, off by default (including existing records with no value). The shared local request path rejects any image-bearing history before contacting the server unless enabled; text-only requests are unaffected. This is a user declaration, not automatic capability detection; the selected server/model must still support vision.

Compaction retains at most eight images and reserves an approximate 1,024 tokens per retained image, in addition to text, and summaries retain attachment labels without inferring visual content. Once an image-bearing message is outside the retained context, its pixels are no longer sent; the user can still preview the saved image and must reattach it for new visual analysis. Images are not forwarded through text-only delegated-agent tasks or heartbeat prompts. Debug captures record labels, never base64 image payloads.

Validation: `swift test` includes image normalization, rotation, invalid inputs, Codable round trips, and provider payload checks. Launch the built app with `--image-attachment-self-test` for offline disk-reopen, follow-up-history, actual local request serialization, and deletion checks against a temporary store.

This document describes the context the chat harness sends to a model for normal replies and scheduled heartbeats. Keep it updated whenever persistence, prompt construction, memory handling, message loading, or orchestration changes.

Implementation snapshot: September 11, 2026.

Primary implementation:

- `Chat/ModelClient.swift`: Apple Foundation, ChatGPT subscription, and OpenAI-compatible model dispatch
- `Chat/ChatGPTProvider.swift`: Codex app-server authentication, model discovery, generation, and dynamic-tool bridging
- `Chat/ModelPrompts.swift`: system and conversation prompt construction
- `Chat/AgentMemory.swift`: memory protocol sent to models and parsed from replies
- `Chat/AgentStash.swift`: per-agent working key/value storage and focused model tools
- `Chat/AgentStashEditor.swift`: user-visible multiline stash editor
- `Chat/SkillCatalog.swift`: `~/.chat/skills` discovery and global enablement
- `Chat/SkillTools.swift`: skill, notification, calendar, `AskAgents`, and `SendToAgents` tool definitions and execution
- `Chat/AgentCollaboration.swift`: directed agent delegation, parallel fan-out/gather, execution budgets, cancellation leases, and delivery
- `Chat/CalendarAccess.swift`: EventKit calendar listing and event reads, scoped by per-agent calendar IDs
- `Chat/AppleServices/`: native service tools, live grants, prepared communication actions, receipts, imported attachments, and permission/review UI
- `Chat/ChatViewModel.swift`: turn orchestration
- `Chat/LocalModels.swift`: local model CRUD and backend selection
- `Chat/GroupChats.swift`: group participants and `@mention` parsing
- `Chat/AgentHeartbeats.swift`: heartbeat persistence and scheduling

## Bounded tool-error recovery

Foundation Models tools are wrapped at session creation by `Chat/AgentLoop/RecoveringFoundationTool.swift`, preserving their schemas. Actionable validation errors from known read-only operations return small `isError` tool outputs instead of aborting the session. The model reads the feedback and may issue corrected arguments; the app never automatically replays a request. The OpenAI-compatible loop uses the same recovery policy and budget (and retains its eight-round ceiling). The externally hosted ChatGPT/Codex loop is unchanged.

`ToolExecutionLoop` is an actor shared across all tools in one generation, including concurrent calls. It allows at most 12 executions and two correction opportunities (the third failure stops). Repeating a failed tool name plus unchanged JSON arguments stops before execution, normalizing JSON key order and whitespace. Limits do not reset after a successful call or switching tools; a new generation gets a new budget. Cancellation, permission/setup/revocation failures, uncertain outcomes, and potentially side-effecting operations remain terminal. The policy allows known input errors for Reminders/other native service reads, stash list/read operations, Calendar date validation, and skill-file reads, not arbitrary exceptions.

Debug-on Foundation history has a dedicated ordered Agent loop section containing each call start, canonical arguments, feedback sent to the model, successful completion, counters, and stop decisions. Its Apple transcript section retains actual instructions, prompts, tool arguments, complete model-visible outputs, and response text, with entry indexes. The underlying invocation recorder still marks failed attempts as failed; a successful correction is its own numbered invocation. On termination, `ModelGenerationError.partial` preserves diagnostics and usage. The app-level `--tool-recovery-self-test` injects the Todos timestamp-date regression against fixtures and verifies actual Foundation Model correction, scope preservation, and debug retention. `Tests/AgentLoop` covers trace contents, repeat detection, failure/total budgets, concurrency, cancellation, and bounded feedback.

## Native Apple services

`Reminders`, `Notes`, `Messages`, `Mail`, `Contacts`, and `Phone` are separate per-agent enablement flags, not callable tools; each gates only its own service, in tool construction, live grant checks, and delegation authorization. They replace the old combined `AppleServices` flag: agents and the global tool setting that had it on are migrated once (`AgentToolID.migratingLegacyAppleServices`) to have all six on, and the legacy flag is dropped. A service revoked in Settings fails before any live operation. Reminders exposes operation-specific `ListReminderLists`, `FindReminders`, and `ReadReminder` tools; edit grants additionally expose `CreateReminder`, `UpdateReminder`, and `SetReminderCompleted`, with `DeleteReminder` requiring deletion permission. Consultations expose only the three read tools. The old callable `AppleReminders` is no longer advertised or accepted. Other configured services retain `AppleNotes`, `AppleContacts`, `ApplePhone`, `AppleMessages`, and `AppleMail` with action fields. Foundation Models wrappers and JSON tool dispatch execute through the same `AppleServiceRuntime`; provider schemas have a self-test. The toolbox's Foundation Models tool list is named `foundationModelTools`.

`Agent.appleServiceGrantsJSON` is an additive optional field. A missing or invalid value grants nothing. Service grants separately cover selected containers/conversations, edits, reminder deletion, history, scheduled use, delegated use, and exact standing communication destinations/sending identities. Tool definitions are selected at invocation creation; grants are checked live before work and before returning results. Configuration changes revoke in-flight fences and cancel pending communications. Calendar retains its existing tool name and selection semantics, with live policy validation around its reads.

Consultation remains read-only. The delegation context now propagates `isBackground` through every descendant and refreshed invocation. A heartbeat's child requires both background and delegation grants; dispatch cannot turn scheduled work into an interactive invocation.

Writes use durable action IDs. Existing-item changes require a revision from a read result. Communications first prepare an exact, agent-owned action; execution uses an applicable standing destination grant or a user click on its review card. Model arguments cannot supply approval. Ambiguous completion is recorded as uncertain and is not automatically retried. Prepared communications expire after an hour. Free-form user text does not independently bypass the review/standing-grant boundary in this implementation.

Most services return bounded records, revisions, observation time, scan coverage, and `nextOffset`; Reminders uses its own smaller response shape described below. Pagination is over live data, not a stable snapshot. Notes/Mail/Messages search can return an empty scanned page with a continuation. Service content is untrusted data; it may inform a response but cannot change grants or authorize an action. Unsupported content is explicitly labeled.

`FindReminders` separates optional `listName` (exact unique name or list ID) from optional `textContains` (title/notes filter). Omitting `listName` searches ALL allowed lists; omit `textContains` when listing a list's contents. `status` defaults to `incomplete`; `completed`/`all` require an explicit user request. Optional `dueFrom`/`dueThrough` specify inclusive local calendar days; a date-range search also includes every overdue incomplete reminder, while completed and upcoming reminders outside the requested range remain excluded. List discovery and search use five-item pages with `offset`/`nextOffset`. Search returns only ID/title/due summaries and one scope label; `ReadReminder` supplies bounded details and the original edit revision. All new Reminders responses are capped at 4,096 UTF-8 bytes (or a smaller caller budget). Output-driven page shrinkage advances by the number actually returned so it never skips omitted records. Truncated content is labeled. Mutations use `retryKey`, translated to the existing runtime `actionID`; permissions, revision checks, durable receipts, and debug capture remain shared. The chat debug icon opens the turn in a dedicated resizable window with a single scrolling document.

Enabling a service turns on the global managed-script setting, which disables unrestricted skill execution throughout the agent graph. The user may opt back into broader script access in Apple Services settings; native scopes do not sandbox those scripts. Apple Services do not override an agent's explicit Debug log setting. With Debug off, native service tool traces contain only status/count metadata. With Debug on, they retain the exact structured request and bounded result returned to the model; prepared-action receipts remain in the app-owned action store.

The integration uses no command-line clients. Apple owns account authentication and synchronization. Reminders and Contacts use their frameworks; Notes, Mail, and Messages sending use typed Apple Events. Messages history uses read-only SQLite and a bounded attributed-text decoder. Phone is a system call handoff. Files become sendable through an agent-scoped import reference and are checked again before use. See `docs/apple-services-implementation.md` for setup, limits, and verification.

## Agent state and snapshot boundaries

An agent has:

- A display name
- An optional avatar image and crop used only by the app UI
- Individual instructions, stored as `soul`
- Persistent memory
- A persistent working stash of text keys and values
- A selected model
- Optional text-to-speech settings: a configured tool, voice name, and voice model
- Per-agent enablement of model tools and skills
- A permanent, unique `@handle` and optional “When to ask me” routing description
- Directed, default-deny consult and dispatch grants to other agents
- Zero or more heartbeat schedules

Text-to-speech settings are live agent configuration and are not included in model prompts. While voice mode is active, each visible assistant response is sent to the responding agent's selected command-line tool using its configured voice name and voice model, then the generated WAV file is played.

An agent's default direct chat follows the agent's current name, individual instructions, and model selection. Its stored snapshot is synchronized whenever the agent changes and again before a send, so a newly configured agent cannot remain pinned to its creation-time `Untitled Agent` and Apple model defaults. Extra direct chats snapshot the agent ID, name, and model selection when the chat is created, while still reading the agent's current individual instructions immediately before generation. Those snapshots keep stored history self-describing if the agent is later deleted.

Group chats snapshot the same fields when an agent first joins through an `@mention` or heartbeat. Ordinary group replies continue using the participant's snapshotted name and model selection, but read the agent's current individual instructions immediately before generation. Deleting an agent removes it from live group participant rosters while preserving authored messages and generation history.

Individual instructions and memory are live agent state. Normal direct replies, normal group replies, and heartbeats read the agent's current instructions and memory immediately before generation. Edits and model-appended memory entries therefore apply across existing chats on the next turn.

Heartbeats also execute with the agent's current name, instructions, and memory rather than a chat snapshot. A heartbeat uses its own model override when one is set; otherwise it uses the agent's current model selection.

## Effective agent system instructions

If individual instructions are empty, the harness substitutes:

```text
You are a concise assistant inside a simple chat app.
Answer conversationally, and don't feel the need to ask a follow-up question unless it's natural.
```

For direct replies and heartbeats, the base agent system prompt is:

```text
Your agent name is <agent name>.

Current date and time: <weekday, month day, year at local time with zone abbreviation> (<ISO 8601 with offset>, <time zone identifier>)

Individual agent instructions:
<individual instructions or default>

<memory section and memory rules>

Available tools:
- <ToolName>: <tool description>

Available skills:
- <skill name>: <skill description>

Collaboration directory:
- @<stable handle> [consult, dispatch]: <when-to-ask description>
```

The tools section is omitted when the agent has no tools enabled. Each enabled tool is listed by its exact call name. The model is told that describing a tool or putting its intended output in a reply does not invoke it, and that it may call multiple tools in sequence.

The collaboration directory is omitted when the agent has no effective outbound grants. It lists only targets that the caller may currently consult or dispatch to. A typed `@handle` resolves the target for the UI and gives the model an exact stable reference, but text alone never starts work: the model must call `AskAgents` or `SendToAgents`.

`ReadCalendarEvents(start, end, calendar_ids)` reads EventKit events in an ISO 8601 date range. `calendar_ids` is an optional comma-separated list of calendar identifiers, not names; omitting it queries every calendar the user allowed for that agent (All, or a stored ID allowlist). The tool returns labeled text: a calendar ID+name directory, then one `event:` record per event. Timed `start`/`end` values are converted in-process to the Mac’s current time zone and formatted as localized date-times with a zone abbreviation (for example PDT); the header names that zone (`America/Los_Angeles (PDT, UTC-7)`). All-day events stay calendar dates in the event’s own zone so they do not shift a day. The payload omits EventKit identifiers, lat/long, alarms, creation/modification timestamps, default `confirmed`/`busy` flags, and per-event original time zones. Attachments are omitted. Notes longer than 250 characters are truncated. The allowlist is live agent configuration and is not included in the system prompt.

The skills section is omitted when no skills are enabled both globally in Settings and for that agent. Enabled skills are listed by YAML `name` and `description` from `SKILL.md`. The model can read files with `ReadSkillFileTool(skill_name, file_name)` and run scripts with `ExecuteSkillScript(skill_name, script_name, arguments)`. Paths are confined to that skill's folder under `~/.chat/skills`.

The current date and time are taken from the device clock in the Mac’s current time zone at the start of each generation (direct replies, group replies, and heartbeats).

Ordinary group replies use an equivalent structure inside the group-specific system prompt.

## Persistent memory

### Context sent to the model

Current memory is included in the system instructions on every generation:

```text
Persistent memory:
--- BEGIN MEMORY ---
<current memory, or "(No stored memory.)">
--- END MEMORY ---

Memory rules:
- Treat the existing memory as read-only. Never rewrite, delete, or replace an existing entry.
- You may append a new memory when something will be useful in future conversations.
- To append memory, include each new entry inside [[MEMORY]] and [[/MEMORY]] markers.
- Memory markers are control data and will not be shown as part of your reply.
- Do not add transient details, repeated facts, or instructions to yourself as memory.
```

The user can edit the complete memory text directly in the agent editor. Those edits save immediately.

### Working stash

The stash is persistent per agent but deliberately separate from long-term Memory. It is not injected into every prompt. When the `Stash` tool is enabled, the model gets three small focused tools: `ListAgentStash` returns keys and `updatedAt` timestamps, `ReadAgentStash` returns one bounded value and its timestamp, and `WriteAgentStash` idempotently creates or replaces one key. Consulted agents can list/read their own stash but cannot write it; normal chats, heartbeats, and dispatched work can write. Live tool enablement is checked again for each operation.

Keys are single-line, trimmed, matched case/diacritic/width-insensitively, and limited to 80 characters. Each agent can store 100 entries; full values are limited to 32,000 UTF-8 bytes. Model reads return at most 8,000 characters and explicitly mark truncation, while the editor shows the full multiline value. `updatedAt` is information for the agent rather than an automatic cache-expiration policy. Stash values are untrusted data, not instructions.

The Stash tab allows the user to add, rename, edit, and delete entries even when the agent tool is disabled. Deleting an agent deletes its stash rows. With Debug on, stash tool arguments and model-visible results are recorded in full; with Debug off, stash contents are omitted from tool history. The app-level `--agent-stash-self-test` uses an in-memory store to check persistence, multiline round trips, focused Foundation/OpenAI schema parity, case-insensitive upserts, live revocation, retry policy, and debug capture/redaction.

### Model memory writes

The model can request one or more additions in any normal reply or heartbeat result:

```text
Visible reply text.

[[MEMORY]]
The user prefers concise status updates.
[[/MEMORY]]
```

The harness removes every complete memory block from the visible reply and appends each non-empty block to the agent's current memory, separated by blank lines. The model has no protocol for replacement or deletion; model output can only reach the append operation.

If the output contains only memory blocks, memory is updated without posting a chat message.

## Default chats and extra chats

Each agent has one **default direct chat**. It is created with the agent, always appears in the sidebar as the agent's avatar and name, and cannot be deleted. Extra direct chats with the same agent are created from the agent's context menu (`New chat`) and are listed indented under that row, showing only the chat title.

The oldest agent is the **default agent** and cannot be deleted. Other agents can be deleted from the Advanced editor tab. Deletion removes their heartbeat schedules, detaches them from live group participation, and hides their direct chats while preserving stored messages and generation history.

Heartbeats whose destination is the agent's private chat post to that default chat unless a specific extra chat is selected. Resetting a chat records `clearedThroughMessageID` on `StoredChat`: messages through that id stay in the database but are omitted from the visible transcript and from model context. Reset also clears the chat's compaction digest and watermark so the prior session is not summarized into the next one.

## Direct chats

All direct-chat model context now comes from persisted messages rather than the UI's lazy-loaded message array. After a reset, that fetch includes only messages after `clearedThroughMessageID`.

### Apple Foundation Model

A new `LanguageModelSession` is created for each reply. Its instructions are the effective agent system instructions with current memory.

The app fetches persisted chat messages in chronological order and flattens the **tail** (messages after the chat's compaction watermark) into this prompt. If a stored digest exists, it is prepended:

```text
Here is the private conversation so far:

Earlier in this conversation (summarized):
<digest>

Recent messages:
User: <user message>

<agent name>: <assistant message>

Reply to the latest user message as <agent name>.
```

The newly submitted user message is persisted before this transcript is built. Extra direct chats insert an app-generated greeting; an agent's default chat does not. Greeting and heartbeat posts that belong to the active session are included. The visible chat transcript is never rewritten; reset hides earlier rows instead of deleting them.

No Apple session is reused between turns. All conversational memory comes from the digest plus tail and agent memory included in the current request.

### ChatGPT subscription

The ChatGPT subscription backend uses the supported Codex app-server protocol over a local JSONL subprocess. It accepts only an account reported by Codex as `chatgpt` whose configuration requires OpenAI authentication; an API-key session or custom model provider is rejected so this provider cannot silently switch to metered or third-party billing. Threads explicitly request the built-in `openai` provider and verify the provider returned by Codex before a turn starts. Chat does not read, copy, or persist Codex authentication tokens. Codex owns sign-in, credential refresh, and account storage.

Each generation starts an ephemeral Codex thread in a newly created empty temporary directory. The app-server process is launched with its built-in shell, execution, browser, computer-use, image, plugin, skill-search, workspace, and multi-agent feature families disabled. Before the thread starts, Chat reads the effective Codex configuration, disables every inherited MCP server and plugin by name, disables project-document and host-environment instruction discovery, and applies a no-approval/read-only/no-network policy with no workspace roots or execution environments. After thread creation, Chat verifies that every configured MCP entry is runtime-disabled and exposes no tools, resources, resource templates, or initialized server metadata. (`mcpServerStatus/list` includes configured entries even when they are disabled.) During the turn, any command, file-change, MCP, web, image, sleep, review, or other unexpected built-in tool item aborts the generation. The temporary directory is removed after the turn. SwiftData remains the sole authority for conversation history.

The direct-chat digest and tail are flattened into the same conversation prompt used by Apple Foundation Model and passed as one text input. The effective agent system instructions are supplied as developer instructions. Selecting `ChatGPT (recommended model)` omits a model override so Codex chooses the account default; selecting a discovered model sends its Codex model ID.

Enabled agent tools are translated into app-server dynamic function tools. A dynamic call is routed back through `AgentToolBox`, including the existing skill, notification, calendar, and collaboration policy checks, and the result is returned to the same Codex turn. Command-execution and file-change approval requests are declined and terminate the generation.

### OpenAI-compatible model

The harness sends native chat-completion roles for the **tail** only. The digest is appended to the system message when present:

```json
{
      "model": "<default chat's current model ID, or extra chat's snapshotted model ID>",
  "messages": [
    {
      "role": "system",
      "content": "<agent name, individual instructions, current memory, and memory rules>"
    },
    {
      "role": "assistant",
      "content": "<app greeting or prior assistant message>"
    },
    {
      "role": "user",
      "content": "<user message>"
    }
  ]
}
```

Author IDs and names are not sent in the native message entries because a direct chat has one agent.

## Conversation compaction

The visible `StoredChatMessage` log is never rewritten in place. Reset and extra-chat deletion are the exceptions to “never deleted from the UI”: reset hides rows via `clearedThroughMessageID` without deleting them; deleting an extra or group chat removes that chat and its messages. Default chats cannot be deleted. Each chat stores an optional rolling digest (`compactedSummary`) and a watermark (`compactedThroughMessageID`). Compaction only sees the active session (messages after `clearedThroughMessageID`).

Before a direct reply or group participant reply, the harness budgets the destination model's context window (Apple `contextSize` at runtime, 128,000 tokens for ChatGPT subscription models, or the local model's configured token limit, default 8192). It keeps as much recent verbatim history as fits after system instructions, memory, tools, and a reply reserve. Messages that no longer fit are folded into the digest with the on-device Apple Foundation Model: existing digest + overflow span → replacement digest covering the whole span through the new watermark. Long overflow is chunked to fit the summarizer's own window, then merged.

If Apple Intelligence is unavailable or summarization throws, those overflow messages are omitted from the **prompt only** for that turn.

A Compact button on the chat (and Developer → Compact conversation) runs the same path with a smaller tail budget.

Compaction is serialized per chat. The digest is chat-local and is not written to agent memory.

## Group chats

### Adding and directing participants

The harness extracts case-insensitive tokens matching stable agent handles. Handles are generated once, made unique (`@agent`, `@agent2`, and so on when necessary), persisted, and do not change when the display name changes. Existing group participants also persist the handle they joined with.

Newly mentioned agents are snapshotted and added before the user message is persisted. The snapshot supplies the participant's name and model selection. Deleting the agent later removes that participant from the live roster, while the `@mention`, authored messages, and generation history remain stored.

Every stored participant is offered a response on each user turn:

1. Directly mentioned participants run first.
2. Remaining participants follow in join order.
3. Calls run serially.
4. A participant can return `[[PASS]]` to avoid posting.

### Transcript construction

Immediately before each participant responds, the harness fetches every persisted group message and flattens it in chronological order:

```text
User: <user message>

Agent One: <agent reply>

Agent Two: <agent reply>
```

Later participants in the same turn see replies already persisted by earlier participants. Earlier participants cannot see replies that occur later in the turn.

### Group system prompt

Each participant receives:

```text
You are <agent name>, a participant in an open group discussion.

Current date and time: <weekday, month day, year at local time with zone abbreviation> (<ISO 8601 with offset>, <time zone identifier>)

Individual agent instructions:
<current individual instructions or default>

<current memory and append-only memory rules>

Group chat system instructions:
<user-entered group instructions or default>

Discussion behavior:
- You see the complete conversation between the user and every agent in the group.
- Messages labeled with another agent's name were written by that agent, not by you.
- You may respond to the user or to another agent when it adds something natural to the discussion.
- A direct @mention gives that comment extra emphasis, but it does not prevent other agents from replying.
- Do not prefix your reply with your name; the interface adds it for you.
- If you have nothing useful to add, reply with exactly [[PASS]].
```

The default group instructions are:

```text
Let the discussion develop naturally. Be concise and avoid repeating points already made.
```

### Group conversation prompt

The complete flattened transcript is inserted into one prompt:

```text
Here is the complete group conversation so far:

<flattened transcript>

<direct-mention emphasis>
Continue the discussion as <agent name>, or return [[PASS]] if you would only repeat what has already been said.
```

A directly mentioned agent receives:

```text
The latest user message directly mentions you. Treat it with extra emphasis and usually respond.
```

Other agents receive:

```text
The latest user message does not directly mention you. You may still respond if it feels natural and useful.
```

### Backend mapping

For Apple Foundation Models, a new session is created with the group system prompt and the conversation prompt is passed to `respond(to:)`.

For ChatGPT subscription models, the complete group prompt is passed as one text input to a new ephemeral Codex app-server thread with the group system prompt as developer instructions.

For OpenAI-compatible models, the request contains exactly one `system` message and one `user` message. The complete transcript exists inside that single user message rather than native per-turn roles.

## Agent collaboration

Collaboration is available in ordinary user turns and heartbeats through the same two model tools:

- `AskAgents(assignments)` consults up to four allowed targets in parallel, waits for best-effort results, and returns one ordered JSON result envelope to the caller. Consulted agents do not post independently. They receive their own current Soul and selected model, no persistent memory, and a read-only tool subset (`ReadSkillFileTool` and `ReadCalendarEvents` when enabled).
- `SendToAgents(assignments)` accepts up to four independent assignments, returns receipts immediately, and runs the target agents in parallel. A dispatched agent receives its own current Soul, memory, selected model, enabled tools, and outbound collaboration grants. Its visible result—or a failure notice—is posted idempotently to its default direct chat. Dispatches continue after the calling turn finishes, but only while Chat remains running.

Each assignment names a stable `@handle` and contains one focused task. A handle is seeded from the agent's first committed nonempty name and then remains unchanged across later renames. The coordinator resolves handles against the live agent directory and rechecks authorization immediately before acceptance, execution, every tool call, nested delegation, memory append, and chat delivery. Delegated tasks, tool output, and child-agent output are explicitly marked as untrusted data.

### Permission and execution boundaries

Collaboration grants are directed, mode-specific, default-deny, and non-transitive. A grant from A to B does not grant B access to A or to any agent A can reach. Effective authority is the intersection of the caller-to-target grant, the caller's collaboration tool enablement, and the target's currently enabled tools and skills. Dispatch may use all of the target's enabled tools; consult uses only its read-only subset. Changing an involved agent, grant, model endpoint, selected provider model, Codex executable, context limit, or bearer token cancels affected in-flight branches. The complete backend configuration is also compared again before model start, tool use, and final commit so queued work cannot retain a stale endpoint or credential.

The execution tree is bounded to 12 delegated nodes, depth 2, four assignments per call, three active children per root, four active children and 24 total outstanding invocations across the app, six remote-model calls per root, 24,000 characters per assignment, and 96,000 delegated task characters per root. One execution slot is reserved for nested work to prevent fan-out deadlock. Caller-facing gathered output, child summaries, and tool output are independently bounded for the caller or target model's context window. If the complete task plus the target's Soul, memory, and tool instructions cannot fit safely, the assignment is rejected rather than silently truncated.

Every invocation has a four-minute execution window and a revocable lease. User cancellation cascades through already-created descendants; preparation checks the parent lease before and after every suspension so a not-yet-created child cannot escape. A timed-out or cancelled model request may take longer to stop if its backend ignores cancellation, but it keeps occupying its concurrency slot and all later tool calls, fan-out, memory writes, and chat delivery are fenced off.

### Audit and persistence

`AgentInvocationRecord` stores the execution tree IDs, caller and target snapshots, mode, state, bounded task/result/error previews, model/backend, depth, timing, token counts, and a compact tool trace containing tool names and success/failure. When a heartbeat starts with its agent's Debug log enabled, the heartbeat turn ID is also used as the collaboration tree root and each invocation stores a full debug payload: exact assignment and prepared/sent prompts, raw/visible reply, the exact bounded envelope or receipt returned to the caller, reasoning and intermediate output, provider transcript metadata, errors, and complete tool arguments/results. This debug flag is snapshotted for the whole tree and propagated to nested and asynchronous dispatches; ordinary runs keep the redacted compact audit. A completed dispatch's full user-visible post is held temporarily in a durable outbox until it has been inserted idempotently into the target chat, then cleared. The Collaboration editor shows the latest 20 related rows and lets the user stop an active branch. Compact terminal history is kept for at most 30 days and 500 records; heartbeat debug rows remain with their run. Deleting an agent also redacts correlated root delegation tool rows and removes provider debug payloads that may duplicate the exchange. Its scrubbed root-wide privacy tombstones are retention-exempt so an in-flight parent or later descendant cannot recreate deleted content.

An exact heartbeat pass changes only chat delivery: it posts no bubble. Its generation turn, tools, and compact collaboration audit are retained like every other destination-resolved heartbeat. When Debug log was enabled for the run, the full root and delegated-agent debug payloads are retained too, including assignments, prompts, replies, provider artifacts, and complete tool arguments/results.

Queued and running records found after relaunch are marked failed and surfaced in the target chat through the same durable outbox. The task payload itself is intentionally in-memory, so accepted dispatches are not resumed after Chat quits.

## Heartbeats

### Scheduling

An agent can have multiple persisted heartbeats. Each heartbeat stores:

- An enabled flag
- An instruction
- An interval from 1 to 10,080 minutes
- A private-chat or group-chat destination
- An optional model override
- Last-run and next-run dates
- The last-completed date
- The last execution error, if any

The in-app scheduler checks for due heartbeats every 15 seconds while Chat is running. Enabling a heartbeat schedules its first run one interval in the future. A due heartbeat is claimed and assigned its next run before model execution, preventing duplicate execution.

Heartbeat execution is globally single-flight: the scheduler starts at most one heartbeat at a time, regardless of agent or destination. When multiple heartbeats are due together, it chooses the earliest scheduled date; ties favor the heartbeat that ran least recently, then creation order. This prevents equal schedules from starving one another.

Once one heartbeat has started, every other heartbeat that becomes due is deferred to the current time plus its own interval. The running heartbeat may itself be a scheduled run or a manual invocation. A deferral does not call a model, update last-run or last-completed time, or create an audit record.

Missed intervals are not replayed. If the app was closed past the due time, the heartbeat runs once after the next scheduler check and then resumes its normal interval.

The Heartbeats window exposes three actions for an upcoming heartbeat:

- `Run Now` claims the heartbeat immediately, sets its next run to one interval after the current time, and starts model execution when no other heartbeat is running. If another heartbeat is already running, the requested heartbeat is instead deferred to one interval after the current time.
- `Skip` does not call a model or create a completed audit record. It advances the scheduled date by one interval, using the later of the current next-run date or the current time as its starting point.
- `Disable` turns off the heartbeat and clears its next-run date.

A claimed heartbeat is removed from Upcoming and shown in the in-memory Running section. Its elapsed running time updates once per second. Right-clicking a running heartbeat and choosing `Abort` requests task cancellation. The harness checks cancellation again after the backend returns and before processing memory or posting, so an aborted run cannot add memory or a chat message. Its normal next-run date remains scheduled.

Every execution has a five-minute timeout. At five minutes the scheduler removes the heartbeat from Running, requests cancellation, creates a completed timeout audit record, and schedules the next attempt one full interval after the timeout. With Debug log enabled, the timeout payload preserves any model input already constructed and tool calls completed by the timeout; otherwise the compact record omits prompt content. A backend that ignores cancellation may continue working after the UI timeout, but its eventual response is discarded before memory or message processing. When that late response arrives, including an exact pass, its final tool snapshot and Debug artifacts enrich the existing timed-out turn without changing the timeout outcome.

### Destination selection

For `Private chat` with no specific chat selected, the heartbeat targets the agent's default direct chat. If none exists, the harness creates it without changing the user's current sidebar selection. A heartbeat can instead target a specific extra direct chat; if that chat is missing, the run fails without posting.

For `Group chat`, the heartbeat targets the selected persisted group chat. The agent is added to that group's participants if needed.

A heartbeat runs in the background of its destination chat. It does not take the chat's responding lock, show a thinking indicator, or prevent the user from sending. The destination may generate a user-turn reply at the same time; whichever finishes first posts first. Heartbeats do not receive the chat transcript, digest, or unanswered-message count. Each run is standalone: agent instructions, memory, tools, skills, the current date and time, and the heartbeat instruction.

### Heartbeat model selection and system context

At the start of an execution, the harness resolves the heartbeat's model override if one is set. Otherwise it resolves the agent's current selected model. The resolved model is used for that entire execution. A missing configured local model produces a completed error record without posting.

Heartbeats use the agent's current name, individual instructions, and memory.

A private heartbeat adds these system instructions after the base agent prompt:

```text
You are running a scheduled heartbeat for your private chat.
This run is standalone. You do not have the chat transcript or prior messages.
Follow the heartbeat instruction, including any tool calls it requires.
Tool calls are not chat messages.
If nothing should be posted to the chat, reply with exactly [[PASS]] after you finish any required tools.
You may still append memory even when you pass.
```

A group heartbeat also receives current group instructions. It does not receive the group transcript or the ordinary group discussion rules that depend on seeing other speakers.

### Heartbeat conversation prompt

The destination chat is not compacted or included. The user prompt is only the heartbeat instruction plus the age of the prior completed attempt:

```text
This is a standalone scheduled heartbeat. You do not have the chat transcript.

Time since this heartbeat last completed: 1h ago.

Scheduled heartbeat instruction:
<heartbeat instruction>

Follow that instruction completely, including any tools it names.
Then decide whether to post as <agent name>. Return [[PASS]] if no chat message should be posted.
```

For all backends this is one prompt. Apple uses a new `LanguageModelSession`; ChatGPT uses a new ephemeral Codex app-server thread; OpenAI-compatible models receive one `system` and one `user` message.

The prior-completion age uses a compact, truncated representation: seconds, minutes, hours, days, weeks, 30-day months, or 365-day years, measured from the heartbeat's start time. A heartbeat with no prior completed attempt receives `never`. “Completed” includes a post, pass, empty response, generation or destination error, user abort, and timeout; skipping a scheduled occurrence does not count as completion.

### Heartbeat result handling

The result is processed in this order:

1. Extract and append every complete memory block.
2. Remove memory blocks from visible text.
3. If the remaining text is empty or an exact pass marker, post nothing.
4. Otherwise append the text as an assistant message attributed to the agent.

A generation, destination, or abort error is stored on the heartbeat for display in the agent editor. Unlike ordinary group-generation errors, heartbeat errors are not posted into the chat.

Every completed heartbeat attempt creates a persistent compact `HeartbeatRun` history record. Recorded runs snapshot the agent name, heartbeat instruction, destination label, start and completion times, action, token usage, and any error. Once a destination chat is known, every run, including an exact pass, also creates a linked `GenerationTurn` and ordered tool rows. Failures before destination resolution remain compact-run-only because `GenerationTurn.chatID` is required. These records remain available in the Heartbeats window even if the heartbeat or agent is later edited or deleted.

With Debug log enabled, the linked generation turn stores the exact `SYSTEM` and `USER` prompts, the raw model output, intermediate/provider artifacts, complete root tool arguments/results, and every correlated delegated-agent exchange. This includes exact-pass runs. Asynchronous dispatch rows continue updating after the root heartbeat finishes, and inspectors observe newly inserted descendants live. Debug-off runs retain compact tool fields. Aborted and timed-out runs are saved as completed audit records with their corresponding action and error. If a cancellation-resistant provider exits after the five-minute timeout, its final tool snapshot and Debug artifacts enrich that same timed-out turn without changing the terminal outcome or scheduling state, including when the late result is an exact pass.

## Pass handling

A response is treated as a pass only when its complete visible content, after trimming and case folding, is exactly one of:

- `[[PASS]]`
- `[PASS]`
- `PASS`

Memory blocks are removed before this check, so an agent can append memory and pass without posting.

A heartbeat pass posts no chat bubble, but it remains visible in compact execution history and uses the same destination-resolved generation, tool, provider/debug, and collaboration logging as any other heartbeat result. It still counts as a completed attempt for scheduling and for the next heartbeat prompt's elapsed-time calculation.

## Values not sent as conversational context

- Chat titles, except that heartbeat destination labels are shown only in the UI
- Absolute message timestamps or message IDs
- The destination chat transcript, digest, or unanswered-message count; heartbeat prompts do not include prior chat messages
- Agent IDs
- Heartbeat scheduling metadata other than the compact age of the prior completed attempt
- The complete list of silent group participants
- Model display names
- Server URLs, bearer tokens, or ChatGPT authentication tokens
- UI state such as selection and availability messages

The configured OpenAI-compatible model ID is sent in the request's `model` field. A specifically selected ChatGPT model ID is sent to Codex app-server; the recommended selection leaves model choice to Codex. URLs, bearer tokens, and Codex-managed ChatGPT credentials are transport configuration.

## Issues and design risks

### High priority

1. **Memory text is not compacted.** Agent memory is still sent in full on every request. A large memory block can consume the context budget even after transcript compaction. Token counts use a character heuristic, not the Apple tokenizer.

2. **Flattened transcripts have weak role and trust boundaries.** Apple direct turns and all group turns use plain `Name: text` transcripts inside one prompt. Users and agents can imitate speaker labels or prompt-like instructions, and prior turns lose native role structure. Heartbeats no longer receive a transcript.

3. **The memory protocol is marker-based.** A malformed or incomplete marker becomes visible text. A model can append low-quality, duplicated, or misleading memory, and there is no confirmation, provenance, size limit, or deduplication.

4. **Codex app-server does not expose a stable dynamic-tools-only allowlist.** Chat disables the current built-in feature families at process and thread scope, disables all inherited MCP/plugin entries discovered in effective configuration, verifies that configured MCP entries are disabled with empty callable inventories, uses an empty temporary directory plus read-only/no-network execution settings, and aborts on unexpected built-in tool events. These are fail-closed checks for the current protocol surface, but they are not equivalent to an upstream model-visible tool-registry allowlist: a future unclassified built-in could theoretically act before its event is rejected. A complete boundary ultimately requires a supported app-server allowlist or a separately OS-sandboxed subprocess.

### Medium priority

5. **Heartbeats run only while Chat is open.** There is no OS background task, launch agent, or catch-up queue. Sleep, termination, and prolonged suspension delay execution.

6. **Single-flight deferral can create schedule drift.** A heartbeat that becomes due while another heartbeat is running is postponed by its complete configured interval. Repeated contention can defer a heartbeat more than once, especially when a long-interval heartbeat happens to become due during frequent runs.

7. **Execution control is in-memory and backend cancellation is cooperative.** If the app terminates after a heartbeat is claimed, the model request stops without a completed or aborted audit record, while the already-advanced next-run date remains persisted. At the five-minute UI timeout the global heartbeat slot is released; a non-cooperative backend may continue consuming resources and overlap a later heartbeat until it returns. When it does return, Debug mode refreshes the already-terminal timeout trace, including for an exact pass, but never posts the late reply or changes scheduling.

8. **Recorded heartbeat history has no retention limit.** Compact runs and their destination-resolved generation/tool traces, including exact passes, accumulate indefinitely. Debug-enabled runs additionally retain full prompts, raw/provider output, root tool exchanges, and correlated delegated-agent traces. Root generation fields have per-field caps, but the aggregate delegated-agent debug JSON has no additional storage cap beyond the collaboration/tool runtime bounds. Scrubbed privacy tombstones created by agent deletion are also retained without a cap to prevent late work from restoring deleted content. Frequent schedules and repeated agent deletion can therefore make the SwiftData store grow.

9. **Extra-chat turns and heartbeat turns use different name and model snapshot rules.** Default chats and heartbeats use current agent configuration, with an optional per-heartbeat model override. Extra chats retain snapshotted names and model choices. All paths use current individual instructions and memory, but a heartbeat post can still differ from the agent's next ordinary reply in an extra chat because of its name or model.

10. **Group turns remain asymmetric.** Later agents see earlier replies from the same turn; earlier agents cannot react to later replies until another user turn or heartbeat.

11. **Normal group-generation errors are still agent speech.** The error bubble is attributed to the agent and enters the transcript seen by later participants.

12. **Independent dispatch is not a durable job queue.** Work survives the caller's turn but not app termination. Relaunch marks interrupted records failed and posts a failure notice, but the redacted audit record does not contain enough task data to resume it.

### Lower priority

13. **Pass detection is exact and fragile.** Extra punctuation or explanation around the marker produces a visible post.

14. **Silent group participants are absent from context.** An agent learns who else is present only after those participants post.

15. **Memory edits can race with generation.** The user can edit memory while a request is running. The request uses the memory captured at prompt construction, while any model additions are appended to whatever text exists when the result returns.

16. **Delegation limits are fixed policy, not user-configurable budgets.** Depth, node count, provider concurrency, deadlines, and retained audit history are currently hard-coded. There is no per-agent cost ceiling or daily remote-model budget.
