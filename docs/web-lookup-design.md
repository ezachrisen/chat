# Web lookup for Chat agents

Design proposal · September 9, 2026 · No implementation changes

Scope: an agent answers a question from the public internet. No authenticated sessions, no clicking, no forms, no acting as the user.

The full interactive design is in [browser-access-design.md](browser-access-design.md), which already carries a read-only `SearchWeb` + `FetchPage` path on ephemeral WebKit. This document takes that path alone as the v1 deliverable, and changes two things in it: it puts a **static fetch stage in front of the renderer**, so the common case never starts a WebKit instance, and it **hardens the fetch gate against DNS-resolved private addresses**, which a hostname-and-IP-literal check does not cover. Everything about leases, handover, and acting as the user is out of scope here.

## Recommendation

Two tools — `SearchWeb` and `FetchPage` — over a **three-stage escalation ladder**, with no browser engine in the common path.

| Stage | Mechanism | Typical cost | Handles |
| --- | --- | --- | --- |
| 1. Search snippets | Search provider JSON API | ~300 ms, 1 request | A large share of factual lookups, including the example below |
| 2. Static fetch | `URLSession` + readability extraction | ~500 ms | Most article, schedule, and reference pages |
| 3. Rendered fetch | Offscreen `WKWebView` | 2–5 s | Client-rendered pages that return an empty shell at stage 2 |

Escalate only when the previous stage comes back thin. Most answers never reach stage 3, and the renderer exists so that the ones that need it do not simply fail.

Nothing is installed. `URLSession` and WebKit both ship on iOS and macOS, `com.apple.security.network.client` is already granted, and no TCC prompt is involved. This is a few hundred lines plus a search API key — genuinely small, and worth building before the interactive design.

**What falls away at this scope:** profiles, cookies, tab leases, extensions, native messaging, `chrome.debugger`, trusted input, clicking, forms, prepared actions, approval flows, downloads, and the entire attribution problem. The agent is anonymous and read-only, so there is nothing to act as and nothing to spend.

**What does not fall away:** the injection boundary. A read-only fetch still places attacker-authored text into an agent that holds `SendNotification`, `AppleServices` mail and messaging, `ExecuteSkillScript`, and delegation. That control is not negotiable at any scope, and it is most of the security section below.

## Worked example

*"What time does the Chicago Fire game start tonight?"*

The agent's system prompt already carries the current date, time, and zone from `currentDateTimeSection` at [ModelPrompts.swift:19](Chat/ModelPrompts.swift:19), so "tonight" resolves without a tool call.

```
SearchWeb("Chicago Fire FC schedule kickoff time September 9 2026")
  → chicagofirefc.com/schedule    "…at 7:30 PM CT vs …"
    mlssoccer.com/schedule/…      "…7:30 PM CT…"
    espn.com/soccer/…             "…8:30 PM ET…"
```

Three sources agree once the zones are reconciled, and the top hit is the club's own site. The agent answers from snippets with citations; no page is fetched.

If the snippets were thin or inconsistent, `FetchPage("https://www.chicagofirefc.com/schedule")` would run stage 2, and stage 3 only if that returned a shell — likely here, since club schedule pages are often client-rendered.

Three failure modes this example exposes, all of which are the design's job and not the model's:

- **Time zones.** ESPN says 8:30 PM ET, the club says 7:30 PM CT, and both are the same moment. Every projection stamps the source's stated zone verbatim and never silently normalizes. The answer names a zone, exactly as the calendar tool already does.
- **Ambiguity.** "Chicago Fire" is also a television series. The tool returns titles and URLs prominently enough that the agent can see it picked a soccer club, rather than burying provenance in prose.
- **Staleness.** Postponements and time changes are the common case for this question class. Results carry a fetch timestamp, and the answer is allowed to be qualified.

## Tool surface

```swift
SearchWeb(query: String, count: Int = 5)
  → [{ title, url, snippet, published?, fetchedAt }]

FetchPage(url: String, offset: Int = 0)
  → { url, finalURL, title, text, links, fetchedAt, renderedWith: "static" | "webview" }
```

Two primitives rather than one opaque `answer(question:)` tool. With the round budget no longer fixed, the agent's own loop can search, read, and re-search, which is more debuggable and composes better than a nested loop that hides its work. Revision 2's goal-level `BrowseWeb` existed to firewall context under an 8-round cap; without that cap it is just indirection.

Projections cap at a configured character budget and paginate by `offset`, reusing the truncation already in `AgentToolAuthorization.validatedOutput`.

## Search provider

`SearchWeb` needs a provider and a key — Brave Search, Google Programmable Search, or a Bing-style JSON endpoint behind one `SearchProvider` protocol, configured in preferences. There is no good unauthenticated search API, and scraping a results page is fragile, commonly blocked, and against most engines' terms.

With no key configured, `SearchWeb` reports itself unconfigured. It must not silently fall back to scraping, because that degrades into confidently wrong answers rather than a visible failure. `FetchPage` still works on user-supplied URLs without a provider.

## Network safety

With no authenticated sessions, the domain allowlist stops being the primary control — open-web research is the point, so `allowsAllDomains` is the normal setting here, in deliberate contrast to the interactive design where it is prohibited. That makes the **SSRF guard the primary network control**, and it deserves more care than it usually gets:

- Refuse non-HTTPS schemes, and `file:`, `data:`, and `blob:` outright.
- Resolve DNS and **check the resolved address, not the hostname** — reject loopback, link-local (including `169.254.169.254`), RFC 1918, CGNAT, IPv6 unique-local, and `.local`. A hostname allowlist that never inspects the resolved IP is not a control.
- Re-check on **every redirect hop**, and pin the resolved address between the check and the connection so a DNS rebind cannot land elsewhere.
- Cap response size, total time, and redirect depth. Enforce `searchBudget` and `fetchBudget` per invocation so a loop cannot run up an API bill.
- Honor `robots.txt`, identify as Chat in the User-Agent, and serialize per-domain requests with backoff.

`NSAllowsLocalNetworking` is already set in Info.plist for other reasons; this tool must not inherit it. Local network access is exactly what the guard above exists to prevent.

## Untrusted content

Page text and search snippets are data. They cannot issue instructions, grant permissions, or authorize a tool call, and text claiming to come from the user or from Chat is page text. Results are delivered in a delimited envelope naming the source URL.

Read-only and anonymous shrinks the blast radius but does not remove it, because the agent holding the text is not read-only. Reuse the existing fence rather than adding a second one: once a web tool returns content, the invocation is tainted, and while tainted `ExecuteSkillScript` is blocked — the `AppleServiceSecurity.managedMode` path at [SkillCatalog.swift:181](Chat/SkillCatalog.swift:181) and [SkillTools.swift:103](Chat/SkillTools.swift:103) already does exactly this — while `AppleServices` sends and deletions require explicit approval. Taint propagates through `AskAgents` and `SendToAgents`, and the trace records which URLs entered context.

Two smaller rules:

- **No credential surface.** There is no cookie, storage, or header-read command, and no JavaScript evaluation tool. Stage 3 renders in an ephemeral, non-persistent data store discarded after the call, so nothing accumulates and no two lookups correlate.
- **Egress provenance.** A fetch target should come from the user's request or from a search result, not from model-composed query parameters carrying content read elsewhere. A weaker concern without sessions, and cheap enough to keep.

## Answer quality

The parts that decide whether this feels good, as opposed to merely working:

- **Citations always.** Every claim from the web carries its source URL and fetch time, surfaced in the reply, not only in the trace.
- **Disagreement is reported, not resolved silently.** When sources conflict, say so and prefer the primary one — a club's own site over an aggregator.
- **Freshness.** Cache by final URL with a short TTL, keyed so that a repeated question in the same conversation does not re-fetch, and stamp every result with its fetch time.
- **Thin results are a failure, not an answer.** A stage-2 fetch returning a nav bar and a cookie banner escalates to stage 3; if stage 3 is also thin, the tool says the page could not be read rather than returning boilerplate for the model to interpret.

## Permissions

```swift
nonisolated struct WebAccessGrant: Codable, Equatable, Sendable {
    var enabled = false
    var allowsSearch = true
    var allowsFetch = true
    var allowsAllDomains = true          // the normal setting at this scope
    var allowedDomains: Set<String> = [] // optional narrowing
    var blockedDomains: Set<String> = [] // wins over every allow
    var allowsBackground = false
    var allowsDelegation = false
    var searchBudget = 3
    var fetchBudget = 5
}
```

Resolved through a live grant closure like `AppleServiceContext` at [AppleServiceRuntime.swift:119](Chat/AppleServices/AppleServiceRuntime.swift:119), and fenced for revocation and deadline like `AppleServiceFence`. Search-only is a useful middle tier: snippets answer a lot of questions and never load a third party's page.

`allowsBackground` stays off by default. Web lookup in a heartbeat is defensible in a way that authenticated browsing is not — nothing can be spent or sent — but it still pulls attacker-authored text into an unattended agent, so it should be a deliberate choice.

## Delivery sequence and acceptance gates

1. **`FetchPage`, stages 1–2.** Runtime, `URLSession` fetch, readability extraction, projection, budgets, SSRF guard, `WebAccessGrant`, trace records, agent and preferences UI.
   *Gates:* `localhost`, `169.254.169.254`, and an RFC 1918 address are refused by resolved IP, including via redirect and via a hostname that resolves to one; size, time, and redirect caps hold; projections paginate.
2. **Taint enforcement.** Extend the `managedMode` fence to web-tainted invocations; propagate through delegation; mark web-derived replies.
   *Gates:* a page instructing the agent to run a skill script or send mail produces neither; taint survives a consult round trip.
3. **`SearchWeb`.** Provider protocol, one implementation, unconfigured state, snippet projection with titles and URLs.
   *Gates:* missing key reports clearly and never scrapes; snippets carry taint; budgets enforced.
4. **Stage 3 renderer.** Offscreen `WKWebView`, ephemeral store, thin-result escalation, settle timeout.
   *Gates:* a client-rendered page that returns a shell at stage 2 yields real text at stage 3; a hung page times out with an actionable state; the data store is discarded after each call.
5. **Answer quality.** Citations in replies, conflict reporting, cache with TTL and fetch stamps.
   *Gates:* the worked example above answers correctly with a named time zone and a citation, and reports the ET/CT sources as agreeing rather than conflicting.

## Open questions

- **Whether to ship a default search provider key.** Zero-config is a much better first run; a shared key is a cost and a rate-limit shared across users. A key field in preferences with clear setup text is the honest default.
- **Whether stage 3 should be opt-in per agent.** It is the only stage that executes third-party JavaScript, even sandboxed and ephemeral, and some users will prefer a lookup tool that never does.
- **How much fetched text belongs in the persisted trace**, given `GenerationStore` retains it. A cap plus the URL trail is the likely answer.
- **Whether `SearchWeb` alone should be the default grant** for most agents, with `FetchPage` added deliberately. Snippets answer the example question without loading anyone's page.
