# Native Apple services implementation

September 11, 2026

The first implementation of the Apple-services design is inside `Chat/AppleServices/`. It uses no installed command-line clients, shell scripts, private frameworks, injected helpers, or service credentials of its own. Calendar retains its existing interface and selections.

## Setup

1. Open Settings → Apple Services and connect the services to Chat. macOS grants Reminders, Contacts, and Automation separately. Notes, Mail, and Messages may launch without taking focus when an operation needs them.
2. Open an agent → Tools → Apple Services. Enable the master tool and the individual services. Select specific lists, folders, contact accounts, mailboxes, or conversations, or explicitly allow all. New services and scopes start off.
3. Enable edits, deletion, scheduled use, or delegated use only where wanted. Messages history has an additional grant and requires Full Disk Access for Chat in System Settings; restart Chat after changing that system permission.
4. Configure Mail sending addresses. Optional exact recipient/phone/conversation grants allow unattended sending or call handoff. Otherwise the prepared action appears for review beside the conversation and in the agent's settings.
5. To send a file, import it in that agent's service settings. The agent obtains its opaque reference through the `attachments` action. References are agent-specific, checked for changes, and expire after 24 hours. Only one imported file per operation is supported, up to 25 MB.

Native requests do not trigger first-time permission dialogs during a heartbeat. A connection/setup error directs the user to settings instead.

## Available operations

| Service | Implemented |
| --- | --- |
| Reminders | List allowed lists; search/read; create/update; complete/reopen/delete. Due dates, notes, URL, priority, absolute alarm, and simple daily/weekly/monthly/yearly recurrence. |
| Contacts | List allowed accounts; search/read/resolve candidates; create/update names and organization; add labeled email/phone endpoints without replacing existing entries. Fetches constituent records rather than merging data from excluded accounts. |
| Notes | List folders; paged title search; plaintext reads; create; append/replace simple notes; show in Notes. Locked content and rich-content replacements are refused. |
| Mail | List accounts/mailboxes; paged subject/sender search; read; draft/reply/update; prepare/send; read/flag state; move to an explicitly selected mailbox; show. Imported-file draft attachments are supported with content verification. |
| Messages | List accounts/conversations; read/search local history; prepare/send to an existing conversation or exact endpoint; imported file sending. Recognized attributed text is decoded without object unarchiving. |
| Phone | Prepare an exact international number and hand it to the system's telephone URL handler. The result means handed off, not connected. |

Reminder search uses EventKit's incomplete-reminders predicate by default, so completed items are not fetched or returned. The `completed` and `all` states are reserved for requests that explicitly ask to include completed reminders; state-specific filtering is repeated after the fetch as a defensive check.

### Focused Reminders tools

Reminders no longer advertises a generic action-based `AppleReminders` tool. Both providers see the same operation-specific inputs:

| Tool | Inputs and behavior |
| --- | --- |
| `ListReminderLists` | Optional `offset`; returns five list IDs/names/accounts per page. Use for discovery or duplicate-name disambiguation. |
| `FindReminders` | Optional `listName`, `textContains`, `dueFrom`, `dueThrough`, `status`, `offset`. Five summaries per page; incomplete by default. |
| `ReadReminder` | Required `id`; returns bounded details, completion state, source list, and an edit revision. |
| `CreateReminder` | Required `listName`, `title`, `retryKey`; optional notes, due, priority, URL, recurrence, alarm. |
| `UpdateReminder` | Required `id`, `revision`, `retryKey`; optional title, notes, due, priority, URL, recurrence, alarm. Omitted fields are unchanged; empty notes/due/URL/recurrence/alarm clear that field. |
| `SetReminderCompleted` | Required `id`, `revision`, `completed` Boolean, `retryKey`. |
| `DeleteReminder` | Required `id`, `revision`, `retryKey`. |

Only the three read tools appear for read-only agents and consultations. Editing exposes the next three; deletion additionally requires its separate grant. The backend still checks live grants and revisions for every call. `retryKey` maps to the existing durable action receipt; use the same key only for an identical retry. A call to the old `AppleReminders` name returns migration guidance instead of silently performing an unscoped search.

`FindReminders.listName` accepts an exact unique list name or list ID (IDs take precedence). Omitting it searches every allowed list. Unknown or ambiguous names never fall back to a broader search. `textContains` is a separate title/notes filter: for “anything on my Shopping List,” call `FindReminders({"listName":"Shopping List"})` and omit `textContains`. `dueFrom` and `dueThrough` bound due dates inclusively in local calendar days; reminders without dates are excluded when a bound is supplied. `status` permits only `incomplete`, `completed`, or `all`.

Search returns `status`, a single `scope`, `reminders` containing only `id`, `title`, and `due` (null for undated reminders), and `nextOffset` (null at the end). It omits the generic envelope, observation timestamp, container fields, notes, and revision map. `ReadReminder` supplies details and the original revision needed before editing; notes initially cap at 1,200 characters with `notesTruncated` when needed. Titles cap at 160 characters. Responses have a hard 4,096-byte UTF-8 cap, reduced further by a smaller caller budget. Oversized pages shrink with a continuation after the last returned record; individual content can be shortened further with `contentTruncated`. IDs and revisions are never shortened. Pagination is live, not a snapshot. This bounds each response, not the total size of a long conversation or every combination of other enabled services.

For a new Messages endpoint, an explicitly selected account is used, or the sole enabled iMessage account. Multiple possible accounts require a selection. This cannot guarantee delivery, SMS forwarding readiness, or a particular outgoing number. Text and a file are separate native sends; a partial/ambiguous outcome is retained as uncertain and not repeated.

## Boundaries and conservative choices

- Reminders uses focused operation tools to keep Foundation Models inputs small and unambiguous. The other five services retain their action-based interfaces. Both model interfaces use matching structured fields and the same permission-checked executor.
- Reads and container access are per agent. Edit permission groups ordinary changes; reminder deletion has a separate switch. Contact scope is currently account/container-based, not individual contacts or groups. Notes scope is exact folder IDs, not automatically inherited descendants.
- Background delegation preserves both requirements. Consultation cannot mutate or show apps. Revocation fences active work and cancels prepared communication actions.
- Ordinary writes require unique retry keys; changes to existing items also require a read revision. These APIs do not provide universal atomic compare-and-swap. Receipts prevent automatic duplicate retries but cannot undo Apple Events already accepted by another application.
- Communication authorization comes from a review-card click or a saved exact destination grant. Natural-language requests alone are not treated as machine-verifiable payload approval. Editing a Mail draft or changing conversation membership after preparation invalidates the send through its revision.
- Pagination uses explicit offsets over bounded live scans. Results report coverage, partial content and continuations; an empty page is not necessarily an exhausted search. There is no full personal-data index or push-monitor daemon. Existing heartbeat scheduling can issue permitted queries while Chat runs.
- Rich Notes editing, Notes move/delete, list management, arbitrary recurrence rules, contact merging/removal, arbitrary Mail attachment export, private messaging features, voicemail and autonomous telephone conversations remain unavailable. Notes/Mail operations still require live verification on each supported macOS release; presence in a scripting dictionary is not a guarantee of behavior.
- Imported files are copied into Chat's own storage. Models cannot supply arbitrary file paths. Existing Mail attachments that cannot be matched to the imported reference must be handled in Mail.
- The managed-script switch disables unrestricted skill execution globally, including descendants. Opting back into scripts means native per-agent scopes are not an OS security boundary. Already started external scripts are not retroactively sandboxed.
- With Debug off, native tool trace rows omit request and result content. Per-agent Debug logging remains available after services are enabled; when selected, native tool rows retain the exact structured request and bounded result returned to the model, and saved provider/delegation diagnostics may contain the same Apple service content. Selected remote models still receive the tool content needed for the task.

`apple-actions.json` stores prepared content and mutation receipts under Chat's application-support directory. An unreadable/corrupt store blocks mutations instead of resetting duplicate protection. In-flight receipts become uncertain after a restart. Finished receipts older than 30 days are pruned; uncertain receipts are retained. Imported attachment files are removed when their expired entries are encountered.

## Implementation map

- `AppleServiceContracts.swift`: service catalog, grants, requests/results, revisions, endpoint validation.
- `AppleServiceRuntime.swift`: connections, live policy checks, cancellation, execution origins, durable actions.
- `NativeAppleServices.swift`: EventKit and Contacts executors, isolated from the UI thread.
- `AppleEventsTransport.swift`: fixed four-character terminology, descriptor-based values, bounded synchronous events.
- `ScriptableAppleServices.swift`: Notes, Mail and Messages adapters.
- `MessagesHistoryService.swift`: read-only SQLite with scope-bound, parameterized queries and WAL-aware access.
- `AppleAttachmentStore.swift`: imported file ownership, expiration, and integrity checks.
- `AppleServiceTools.swift`: Foundation Models wrappers and JSON schemas/dispatch support.
- `ReminderTools.swift`: operation-specific Reminders schemas, provider dispatch, and permission-based visibility.
- `ReminderResponses.swift`: small Reminders response shapes, UTF-8 byte budgets, and continuation-safe page shrinking.
- `AppleServicesViews.swift`: device connections, agent grants/imports, in-chat review and action receipts.

The action store and adapters are injectable for isolated tests. `Package.swift` is a development test harness over the same sources compiled into Chat; it is not a runtime package dependency. SwiftData receives only an additive optional grant field. The app's signed configurations now enable hardened runtime and include the Apple Events entitlement and purpose strings.

## Source reuse

Only the small attributed-text parser was adapted from [openclaw/imsg](https://github.com/openclaw/imsg), commit `1db058697a1f6705d907516e668acf2e25ab57d8`. Its MIT notice is included in `Chat/AppleServices/Vendor/imsg-LICENSE.txt` and copied into the application resources. Chat's changes bound input, reject unknown encodings, return explicit decode failure, and account for Swift concurrency. The CLI send transport and helper code were not adopted.

## Verification

Run `swift test --scratch-path /tmp/chat-apple-tests` using the project's Xcode Swift toolchain. Tests cover default denial, background/delegated restrictions, consultation writes, revisions, retry deduplication, uncertain outcomes, exact prepared recipients, cross-agent action ownership, revocation, corrupt/restarted receipts, stable mailbox references, native attributed-text fixtures and malformed inputs, read-only SQLite/WAL pagination and query isolation, HTML preservation gates, date-only reminders, and imported-file tampering.

Build Chat with Xcode normally. The built executable supports `--apple-services-self-test`, which uses an in-memory model store to check grant persistence, preserved Calendar selections, service tool visibility, Foundation Models/JSON schema parity (including required fields/types/enums for Reminders), fixture execution, input validation, and debug-on/off capture. `--apple-services-ui-snapshot` additionally renders the settings view offscreen to `/tmp/chat-apple-services-settings.png`. Neither self-test calls the services or requests their permissions.

`--reminders-model-self-test` also runs the on-device Foundation Model with synthetic Shopping List/Work lists. It checks list scoping, cross-list text search, and date-range arguments, plus the original list question with all seven operation tools advertised. It fails explicitly if the model is unavailable. The fixture runtime is read-only and never reads or modifies personal reminders. This is a smoke test of actual model tool selection, not a guarantee for every prompt.

`--tool-recovery-self-test` tests the production Foundation Model loop with the first `FindReminders` request pinned to the reported Todos failure (`2026-09-11T10:30:28` through `2026-09-14T10:30:28`). The real model must read the date-format error, correct both bounds to `YYYY-MM-DD`, keep Todos selected, and answer from synthetic results. Debug output has a dedicated ordered Agent loop section and must retain the failed arguments, exact feedback sent to the model, counters, corrected call, successful result, and final model response. The normal Tools section retains separately numbered failed and successful invocations. This does not access personal reminders.

The recovery pattern follows [Pi's agent loop](https://github.com/badlogic/pi-mono/blob/main/packages/agent/src/agent-loop.ts): feed tool errors back into model context before asking it to proceed. Chat applies a conservative read-only validation policy and explicit limits: 12 total executions, two correction opportunities, and no re-execution of an unchanged failed request. Permissions, cancellation, setup problems, uncertain outcomes, and potentially side-effecting failures still stop the generation. Foundation and OpenAI-compatible paths share these limits; the latter also retains its eight-round ceiling. Feedback is small, and context-window failures remain terminal rather than restarting or replaying successful actions.

The isolated suite additionally covers compact Reminders response fields, missing due dates, list discovery, UTF-8 budgets, continuation offsets after page shrinkage, original revisions after detail truncation, and compact mutation receipts. No live messages/calls are needed and no personal Reminders, Contacts, Notes, or Mail records need to be created or modified. Live interoperability and signing/TCC behavior on a distributed build remain explicit release checks.
