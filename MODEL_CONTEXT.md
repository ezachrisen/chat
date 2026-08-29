# Model context contract

This document describes the context the chat harness sends to a model for normal replies and scheduled heartbeats. Keep it updated whenever persistence, prompt construction, memory handling, message loading, or orchestration changes.

Implementation snapshot: August 27, 2026.

Primary implementation:

- `Chat/ModelClient.swift`: Apple Foundation and OpenAI-compatible model calls, including tool loops
- `Chat/ModelPrompts.swift`: system and conversation prompt construction
- `Chat/AgentMemory.swift`: memory protocol sent to models and parsed from replies
- `Chat/SkillCatalog.swift`: `~/.chat/skills` discovery and global enablement
- `Chat/SkillTools.swift`: `ReadSkillFileTool`, `ExecuteSkillScript`, `SendNotification`, and `ReadCalendarEvents`
- `Chat/CalendarAccess.swift`: EventKit calendar listing and event reads, scoped by per-agent calendar IDs
- `Chat/ChatViewModel.swift`: turn orchestration
- `Chat/LocalModels.swift`: local model CRUD and backend selection
- `Chat/GroupChats.swift`: group participants and `@mention` parsing
- `Chat/AgentHeartbeats.swift`: heartbeat persistence and scheduling

## Agent state and snapshot boundaries

An agent has:

- A display name
- Individual instructions, stored as `soul`
- Persistent memory
- A selected model
- Optional text-to-speech settings: a configured tool, voice name, and voice model
- Per-agent enablement of model tools and skills
- Zero or more heartbeat schedules

Text-to-speech settings are live agent configuration and are not included in model prompts. While voice mode is active, each visible assistant response is sent to the responding agent's selected command-line tool using its configured voice name and voice model, then the generated WAV file is played.

Direct chats snapshot the agent ID, name, individual instructions, and model selection when the chat is created. Ordinary replies continue using the snapshotted name and model selection, but read the agent's current individual instructions immediately before generation. The instruction snapshot is retained as a fallback if the agent is later deleted.

Group chats snapshot the same fields when an agent first joins through an `@mention` or heartbeat. Ordinary group replies continue using the participant's snapshotted name and model selection, but read the agent's current individual instructions immediately before generation. The participant's instruction snapshot is retained as a fallback if the agent is later deleted.

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
```

The tools section is omitted when the agent has no tools enabled. Each enabled tool is listed by its exact call name. The model is told that describing a tool or putting its intended output in a reply does not invoke it, and that it may call multiple tools in sequence.

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

### OpenAI-compatible model

The harness sends native chat-completion roles for the **tail** only. The digest is appended to the system message when present:

```json
{
  "model": "<chat's snapshotted model ID>",
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

Before a direct reply or group participant reply, the harness budgets the destination model's context window (Apple `contextSize` at runtime, or the local model's configured token limit, default 8192). It keeps as much recent verbatim history as fits after system instructions, memory, tools, and a reply reserve. Messages that no longer fit are folded into the digest with the on-device Apple Foundation Model: existing digest + overflow span → replacement digest covering the whole span through the new watermark. Long overflow is chunked to fit the summarizer's own window, then merged.

If Apple Intelligence is unavailable or summarization throws, those overflow messages are omitted from the **prompt only** for that turn.

A Compact button on the chat (and Developer → Compact conversation) runs the same path with a smaller tail budget.

Compaction is serialized per chat. The digest is chat-local and is not written to agent memory.

## Group chats

### Adding and directing participants

The harness extracts case-insensitive tokens matching `@[letters, numbers, or underscore]`. An agent's mention is its display name with non-alphanumeric characters removed; `Product Critic` becomes `@ProductCritic`.

Newly mentioned agents are snapshotted and added before the user message is persisted. The snapshot supplies the participant's name and model selection and serves as a fallback for individual instructions if the agent is later deleted. The `@mention` remains in the stored message and model transcript.

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

For OpenAI-compatible models, the request contains exactly one `system` message and one `user` message. The complete transcript exists inside that single user message rather than native per-turn roles.

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

Every execution has a five-minute timeout. At five minutes the scheduler removes the heartbeat from Running, requests cancellation, creates a completed timeout audit record, and schedules the next attempt one full interval after the timeout. The timeout record preserves the model input if it had already been constructed, has no model output, and reports that no chat message was posted. A backend that ignores cancellation may continue working after the UI timeout, but its eventual response is discarded before memory or message processing.

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

For both backends this is one prompt. Apple uses a new `LanguageModelSession`; OpenAI-compatible models receive one `system` and one `user` message.

The prior-completion age uses a compact, truncated representation: seconds, minutes, hours, days, weeks, 30-day months, or 365-day years, measured from the heartbeat's start time. A heartbeat with no prior completed attempt receives `never`. “Completed” includes a post, pass, empty response, generation or destination error, user abort, and timeout; skipping a scheduled occurrence does not count as completion.

### Heartbeat result handling

The result is processed in this order:

1. Extract and append every complete memory block.
2. Remove memory blocks from visible text.
3. If the remaining text is empty or an exact pass marker, post nothing.
4. Otherwise append the text as an assistant message attributed to the agent.

A generation, destination, or abort error is stored on the heartbeat for display in the agent editor. Unlike ordinary group-generation errors, heartbeat errors are not posted into the chat.

Every completed heartbeat attempt also creates a persistent audit record. The record snapshots the agent name, heartbeat instruction, destination label, start and completion times, the complete system and user input, the model's raw output before memory-block removal, the action taken, and any error. These records remain available in the Heartbeats window even if the heartbeat or agent is later edited or deleted.

The stored model input is displayed as `SYSTEM` and `USER` sections. Those sections contain the exact prompt text supplied to both backends; they are an audit representation rather than an additional wrapper sent to the model. Aborted and timed-out runs are saved as completed audit records with their corresponding action and error; their input is present if prompt construction had completed before cancellation, and their output is normally empty.

## Pass handling

A response is treated as a pass only when its complete visible content, after trimming and case folding, is exactly one of:

- `[[PASS]]`
- `[PASS]`
- `PASS`

Memory blocks are removed before this check, so an agent can append memory and pass without posting.

## Values not sent as conversational context

- Chat titles, except that heartbeat destination labels are shown only in the UI
- Absolute message timestamps or message IDs
- The destination chat transcript, digest, or unanswered-message count; heartbeat prompts do not include prior chat messages
- Agent IDs
- Heartbeat scheduling metadata other than the compact age of the prior completed attempt
- The complete list of silent group participants
- Model display names
- Server URLs or bearer tokens
- UI state such as selection and availability messages

The configured OpenAI-compatible model ID is sent in the request's `model` field. URLs and bearer tokens are transport configuration.

## Issues and design risks

### High priority

1. **Memory text is not compacted.** Agent memory is still sent in full on every request. A large memory block can consume the context budget even after transcript compaction. Token counts use a character heuristic, not the Apple tokenizer.

2. **Flattened transcripts have weak role and trust boundaries.** Apple direct turns and all group turns use plain `Name: text` transcripts inside one prompt. Users and agents can imitate speaker labels or prompt-like instructions, and prior turns lose native role structure. Heartbeats no longer receive a transcript.

3. **The memory protocol is marker-based.** A malformed or incomplete marker becomes visible text. A model can append low-quality, duplicated, or misleading memory, and there is no confirmation, provenance, size limit, or deduplication.

### Medium priority

4. **Heartbeats run only while Chat is open.** There is no OS background task, launch agent, or catch-up queue. Sleep, termination, and prolonged suspension delay execution.

5. **Single-flight deferral can create schedule drift.** A heartbeat that becomes due while another heartbeat is running is postponed by its complete configured interval. Repeated contention can defer a heartbeat more than once, especially when a long-interval heartbeat happens to become due during frequent runs.

6. **Execution control is in-memory and backend cancellation is cooperative.** If the app terminates after a heartbeat is claimed, the model request stops without a completed or aborted audit record, while the already-advanced next-run date remains persisted. At the five-minute UI timeout the global heartbeat slot is released; a non-cooperative backend may continue consuming resources and overlap a later heartbeat until it returns, although its late output is discarded.

7. **Heartbeat history has no retention limit.** Each completed attempt stores the full model input and raw output. Long conversations and frequent schedules can make the SwiftData store grow quickly.

8. **Ordinary turns and heartbeat turns use different name and model snapshot rules.** Existing chats use snapshotted names and model choices for normal replies, while heartbeats use current agent configuration plus an optional per-heartbeat model override. Both paths use current individual instructions and memory, but a heartbeat post can still differ from the agent's next ordinary reply in the same chat because of its name or model.

9. **Group turns remain asymmetric.** Later agents see earlier replies from the same turn; earlier agents cannot react to later replies until another user turn or heartbeat.

10. **Normal group-generation errors are still agent speech.** The error bubble is attributed to the agent and enters the transcript seen by later participants.

11. **Mention handles can collide.** Removing spaces and punctuation can map multiple agent names to one handle, adding or emphasizing every match.

### Lower priority

12. **Pass detection is exact and fragile.** Extra punctuation or explanation around the marker produces a visible post.

13. **Silent group participants are absent from context.** An agent learns who else is present only after those participants post.

14. **Memory edits can race with generation.** The user can edit memory while a request is running. The request uses the memory captured at prompt construction, while any model additions are appended to whatever text exists when the result returns.
