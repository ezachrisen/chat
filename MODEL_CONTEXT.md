# Model context contract

This document describes the context the chat harness sends to a model for normal replies and scheduled heartbeats. Keep it updated whenever persistence, prompt construction, memory handling, message loading, or orchestration changes.

Implementation snapshot: August 16, 2026.

Primary implementation:

- `Chat/ContentView.swift`: persistence, turn orchestration, and prompt construction
- `Chat/LocalModels.swift`: OpenAI-compatible request construction
- `Chat/GroupChats.swift`: group participants and `@mention` parsing
- `Chat/PersonaHeartbeats.swift`: memory protocol, heartbeat persistence, and scheduling

## Persona state and snapshot boundaries

A persona has:

- A display name
- Individual instructions, stored as `soul`
- Persistent memory
- A selected model
- Optional text-to-speech settings: a configured tool, voice name, and voice model
- Zero or more heartbeat schedules

Text-to-speech settings are live persona configuration and are not included in model prompts. While voice mode is active, each visible assistant response is sent to the responding persona's selected command-line tool using its configured voice name and voice model, then the generated WAV file is played.

Direct chats snapshot the persona ID, name, individual instructions, and model selection when the chat is created. Ordinary replies continue using the snapshotted name and model selection, but read the persona's current individual instructions immediately before generation. The instruction snapshot is retained as a fallback if the persona is later deleted.

Group chats snapshot the same fields when a persona first joins through an `@mention` or heartbeat. Ordinary group replies continue using the participant's snapshotted name and model selection, but read the persona's current individual instructions immediately before generation. The participant's instruction snapshot is retained as a fallback if the persona is later deleted.

Individual instructions and memory are live persona state. Normal direct replies, normal group replies, and heartbeats read the persona's current instructions and memory immediately before generation. Edits and model-appended memory entries therefore apply across existing chats on the next turn.

Heartbeats also execute with the persona's current name, instructions, and memory rather than a chat snapshot. A heartbeat uses its own model override when one is set; otherwise it uses the persona's current model selection.

## Effective persona system instructions

If individual instructions are empty, the harness substitutes:

```text
You are a concise assistant inside a simple chat app.
Answer conversationally, and don't feel the need to ask a follow-up question unless it's natural.
```

For direct replies and heartbeats, the base persona system prompt is:

```text
Your persona name is <persona name>.

Individual persona instructions:
<individual instructions or default>

<memory section and memory rules>
```

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

The user can edit the complete memory text directly in the persona editor. Those edits save immediately.

### Model memory writes

The model can request one or more additions in any normal reply or heartbeat result:

```text
Visible reply text.

[[MEMORY]]
The user prefers concise status updates.
[[/MEMORY]]
```

The harness removes every complete memory block from the visible reply and appends each non-empty block to the persona's current memory, separated by blank lines. The model has no protocol for replacement or deletion; model output can only reach the append operation.

If the output contains only memory blocks, memory is updated without posting a chat message.

## Direct chats

All direct-chat model context now comes from persisted messages rather than the UI's lazy-loaded message array.

### Apple Foundation Model

A new `LanguageModelSession` is created for each reply. Its instructions are the effective persona system instructions with current memory.

The app fetches every persisted chat message in chronological order and flattens it into this prompt:

```text
Here is the complete private conversation so far:

User: <user message>

<persona name>: <assistant message>

Reply to the latest user message as <persona name>.
```

The newly submitted user message is persisted before this transcript is built. The app-generated greeting and any heartbeat posts are therefore included.

No Apple session is reused between turns. All conversational memory comes from the persisted transcript and persona memory included in the current request.

### OpenAI-compatible model

The harness fetches every persisted direct-chat message in chronological order and sends native chat-completion roles:

```json
{
  "model": "<chat's snapshotted model ID>",
  "messages": [
    {
      "role": "system",
      "content": "<persona name, individual instructions, current memory, and memory rules>"
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

Every persisted user and assistant message is included. Author IDs and names are not sent in the native message entries because a direct chat has one persona.

## Group chats

### Adding and directing participants

The harness extracts case-insensitive tokens matching `@[letters, numbers, or underscore]`. A persona's mention is its display name with non-alphanumeric characters removed; `Product Critic` becomes `@ProductCritic`.

Newly mentioned personas are snapshotted and added before the user message is persisted. The snapshot supplies the participant's name and model selection and serves as a fallback for individual instructions if the persona is later deleted. The `@mention` remains in the stored message and model transcript.

Every stored participant is offered a response on each user turn:

1. Directly mentioned participants run first.
2. Remaining participants follow in join order.
3. Calls run serially.
4. A participant can return `[[PASS]]` to avoid posting.

### Transcript construction

Immediately before each participant responds, the harness fetches every persisted group message and flattens it in chronological order:

```text
User: <user message>

Persona One: <persona reply>

Persona Two: <persona reply>
```

Later participants in the same turn see replies already persisted by earlier participants. Earlier participants cannot see replies that occur later in the turn.

### Group system prompt

Each participant receives:

```text
You are <persona name>, a participant in an open group discussion.

Individual persona instructions:
<current individual instructions or default>

<current memory and append-only memory rules>

Group chat system instructions:
<user-entered group instructions or default>

Discussion behavior:
- You see the complete conversation between the user and every persona in the group.
- Messages labeled with another persona's name were written by that persona, not by you.
- You may respond to the user or to another persona when it adds something natural to the discussion.
- A direct @mention gives that comment extra emphasis, but it does not prevent other personas from replying.
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
Continue the discussion as <persona name>, or return [[PASS]] if you would only repeat what has already been said.
```

A directly mentioned persona receives:

```text
The latest user message directly mentions you. Treat it with extra emphasis and usually respond.
```

Other personas receive:

```text
The latest user message does not directly mention you. You may still respond if it feels natural and useful.
```

### Backend mapping

For Apple Foundation Models, a new session is created with the group system prompt and the conversation prompt is passed to `respond(to:)`.

For OpenAI-compatible models, the request contains exactly one `system` message and one `user` message. The complete transcript exists inside that single user message rather than native per-turn roles.

## Heartbeats

### Scheduling

A persona can have multiple persisted heartbeats. Each heartbeat stores:

- An enabled flag
- An instruction
- An interval from 1 to 10,080 minutes
- A private-chat or group-chat destination
- An optional model override
- Last-run and next-run dates
- The last-completed date
- The last execution error, if any

The in-app scheduler checks for due heartbeats every 15 seconds while Chat is running. Enabling a heartbeat schedules its first run one interval in the future. A due heartbeat is claimed and assigned its next run before model execution, preventing duplicate execution.

Heartbeat execution is globally single-flight: the scheduler starts at most one heartbeat at a time, regardless of persona or destination. When multiple heartbeats are due together, it chooses the earliest scheduled date; ties favor the heartbeat that ran least recently, then creation order. This prevents equal schedules from starving one another.

Once one heartbeat has started, every other heartbeat that becomes due is deferred to the current time plus its own interval. The running heartbeat may itself be a scheduled run, a busy-destination retry, or a manual invocation. A deferral does not call a model, update last-run or last-completed time, or create an audit record.

Missed intervals are not replayed. If the app was closed past the due time, the heartbeat runs once after the next scheduler check and then resumes its normal interval.

The Heartbeats window exposes three actions for an upcoming heartbeat:

- `Run Now` claims the heartbeat immediately, sets its next run to one interval after the current time, and starts model execution when no other heartbeat is running. If another heartbeat is already running, the requested heartbeat is instead deferred to one interval after the current time.
- `Skip` does not call a model or create a completed audit record. It advances the scheduled date by one interval, using the later of the current next-run date or the current time as its starting point.
- `Disable` turns off the heartbeat and clears its next-run date.

A claimed heartbeat is removed from Upcoming and shown in the in-memory Running section. Its elapsed running time updates once per second. Right-clicking a running heartbeat and choosing `Abort` requests task cancellation. The harness checks cancellation again after the backend returns and before processing memory or posting, so an aborted run cannot add memory or a chat message. Its normal next-run date remains scheduled.

Every execution has a five-minute timeout. At five minutes the scheduler removes the heartbeat from Running, requests cancellation, creates a completed timeout audit record, and schedules the next attempt one full interval after the timeout. The timeout record preserves the model input if it had already been constructed, has no model output, and reports that no chat message was posted. A backend that ignores cancellation may continue working after the UI timeout, but its eventual response is discarded before memory or message processing.

### Destination selection

For `Private chat`, the heartbeat targets the persona's most recently updated direct chat. If none exists, the harness creates one without changing the user's current sidebar selection.

For `Group chat`, the heartbeat targets the selected persisted group chat. The persona is added to that group's participants if needed.

If the destination chat is already generating a response, the heartbeat records an error and does not post, then schedules a retry for 60 seconds after the failed attempt completed. The busy attempt is a completed audit record. The retry is an ordinary pending heartbeat, so another running heartbeat can defer it by the retrying heartbeat's configured interval.

### Heartbeat model selection and system context

At the start of an execution, the harness resolves the heartbeat's model override if one is set. Otherwise it resolves the persona's current selected model. The resolved model is used for that entire execution. A missing configured local model produces a completed error record without posting.

Heartbeats use the persona's current name, individual instructions, and memory.

A private heartbeat adds these system instructions after the base persona prompt:

```text
You are running a scheduled heartbeat for your private chat.
Follow the heartbeat instruction using the conversation as context.
If there is nothing worth posting, reply with exactly [[PASS]].
You may still append memory even when you pass.
```

A group heartbeat also receives current group instructions and the group discussion rules before the heartbeat behavior instructions.

### Heartbeat conversation prompt

Every persisted message in the destination chat is flattened into one prompt:

```text
Here is the complete <group or private> conversation so far:
Message ages are relative to the start of this heartbeat run.

[8m ago] User: <user message>

[2m ago] <persona name>: <assistant message>

Time since this heartbeat last completed: 1h ago.
Number of unanswered messages in this chat: 1.

Scheduled heartbeat instruction:
<heartbeat instruction>

Decide whether to post as <persona name>. Return [[PASS]] if no message should be posted.
```

For both backends, the heartbeat transcript is supplied as one prompt. Apple uses a new `LanguageModelSession`; OpenAI-compatible models receive one `system` and one `user` message.

Message ages and the prior-completion age use a compact, truncated representation: seconds, minutes, hours, days, weeks, 30-day months, or 365-day years. All ages use the heartbeat's start time as one consistent reference point. A heartbeat with no prior completed attempt receives `never`. “Completed” includes a post, pass, empty response, generation or destination error, user abort, and timeout; skipping a scheduled occurrence does not count as completion.

The unanswered-message count is the number of consecutive non-user messages at the end of the persisted chat. It resets to zero when the user sends a message. In a group chat it counts messages from every persona, not only the persona running the heartbeat. If the user has never sent a message, all existing persona messages—including an initial direct-chat greeting—are counted. This lets a heartbeat instruction suppress another post when one or more persona messages are still awaiting a user reply.

### Heartbeat result handling

The result is processed in this order:

1. Extract and append every complete memory block.
2. Remove memory blocks from visible text.
3. If the remaining text is empty or an exact pass marker, post nothing.
4. Otherwise append the text as an assistant message attributed to the persona.

A generation, destination, or abort error is stored on the heartbeat for display in the persona editor. Unlike ordinary group-generation errors, heartbeat errors are not posted into the chat.

Every completed heartbeat attempt also creates a persistent audit record. The record snapshots the persona name, heartbeat instruction, destination label, start and completion times, the complete system and user input, the model's raw output before memory-block removal, the action taken, and any error. These records remain available in the Heartbeats window even if the heartbeat or persona is later edited or deleted.

The stored model input is displayed as `SYSTEM` and `USER` sections. Those sections contain the exact prompt text supplied to both backends; they are an audit representation rather than an additional wrapper sent to the model. Aborted and timed-out runs are saved as completed audit records with their corresponding action and error; their input is present if prompt construction had completed before cancellation, and their output is normally empty.

## Pass handling

A response is treated as a pass only when its complete visible content, after trimming and case folding, is exactly one of:

- `[[PASS]]`
- `[PASS]`
- `PASS`

Memory blocks are removed before this check, so a persona can append memory and pass without posting.

## Values not sent as conversational context

- Chat titles, except that heartbeat destination labels are shown only in the UI
- Absolute message timestamps or message IDs; heartbeat prompts receive compact relative message ages
- Persona IDs
- Heartbeat scheduling metadata other than the compact age of the prior completed attempt
- The complete list of silent group participants
- Model display names
- Server URLs or bearer tokens
- UI state such as selection and availability messages

The configured OpenAI-compatible model ID is sent in the request's `model` field. URLs and bearer tokens are transport configuration.

## Issues and design risks

### High priority

1. **There is no context-window budgeting.** Every persisted message and the complete memory text are sent on every relevant request. Long chats or large memories can exceed model context limits. There is no token counting, truncation, or summarization.

2. **Flattened transcripts have weak role and trust boundaries.** Apple direct turns, all group turns, and all heartbeats use plain `Name: text` transcripts inside one prompt. Users and personas can imitate speaker labels or prompt-like instructions, and prior turns lose native role structure.

3. **The memory protocol is marker-based.** A malformed or incomplete marker becomes visible text. A model can append low-quality, duplicated, or misleading memory, and there is no confirmation, provenance, size limit, or deduplication.

### Medium priority

4. **Heartbeats run only while Chat is open.** There is no OS background task, launch agent, or catch-up queue. Sleep, termination, and prolonged suspension delay execution.

5. **Single-flight deferral can create schedule drift.** A heartbeat that becomes due while another heartbeat is running is postponed by its complete configured interval. Repeated contention can defer a heartbeat more than once, especially when a long-interval heartbeat happens to become due during frequent runs.

6. **Execution control is in-memory and backend cancellation is cooperative.** If the app terminates after a heartbeat is claimed, the model request stops without a completed or aborted audit record, while the already-advanced next-run date remains persisted. At the five-minute UI timeout the global heartbeat slot is released; a non-cooperative backend may continue consuming resources and overlap a later heartbeat until it returns, although its late output is discarded.

7. **Heartbeat history has no retention limit.** Each completed attempt stores the full model input and raw output. Long conversations and frequent schedules can make the SwiftData store grow quickly.

8. **Ordinary turns and heartbeat turns use different name and model snapshot rules.** Existing chats use snapshotted names and model choices for normal replies, while heartbeats use current persona configuration plus an optional per-heartbeat model override. Both paths use current individual instructions and memory, but a heartbeat post can still differ from the persona's next ordinary reply in the same chat because of its name or model.

9. **Group turns remain asymmetric.** Later personas see earlier replies from the same turn; earlier personas cannot react to later replies until another user turn or heartbeat.

10. **Normal group-generation errors are still persona speech.** The error bubble is attributed to the persona and enters the transcript seen by later participants.

11. **Mention handles can collide.** Removing spaces and punctuation can map multiple persona names to one handle, adding or emphasizing every match.

### Lower priority

12. **Pass detection is exact and fragile.** Extra punctuation or explanation around the marker produces a visible post.

13. **Silent group participants are absent from context.** A persona learns who else is present only after those participants post.

14. **Memory edits can race with generation.** The user can edit memory while a request is running. The request uses the memory captured at prompt construction, while any model additions are appended to whatever text exists when the result returns.
