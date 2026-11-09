Inspect Scout-AI sessions, their lineage segments, producer jobs, agent logs,
tool calls, and direct token usage without replaying them.

ChatAnalyst reads persisted chats with `Chat.load` and traverses job
references through scout-ai's compact one-node provenance API
`Chat.provenance_graph`. The workflow keeps report state in ordinary Hashes
and Arrays; it does not define a Session or graph wrapper.

The exported interface is two-layered:

- a **public Ruby API** — eleven plain module methods on `ChatAnalyst`
  (`lib/ChatAnalyst/api.rb`: the nine redesigned methods plus `tool_call`
  from phase 1 and `attribution` from phase 2) returning serializable
  Hashes/Arrays of paths, zero-based integer indices and counts;
- **thin workflow tasks** (`lib/ChatAnalyst/tasks/api_tasks.rb`) that wrap
  the module methods with argument validation and serialization only.

Method names (`ChatAnalyst.overview`) and task names
(`ChatAnalyst.job(:chat_overview, …)`) are distinct surfaces: the method is
the Ruby API; the task is the Scout workflow surface (CLI or agent tool).
Tasks never re-implement provenance semantics; they call the module methods.

## Vocabulary note: `meta`, not `agent_meta`

Receipt records are read through the **`meta`** field of
`function_call_output` envelopes. The legacy `agent_meta` key is no longer
read by the core: the compact graph resolves receipts internally, and
ChatAnalyst consumes `Chat.provenance_graph` / `Chat.provenance_token_events`,
which return the resolved evidence (standalone `meta: job=` refs anchored at
their own message index; receipt `job=` refs anchored at the outer
`function_call_output` index). Embedded receipts are *evidence*, never
messages of the parent chat, and are never listed by `ChatAnalyst.message_index`
(the Ruby API method; the task adapter of the same name was retired in phase 2).

## Addressing contract

- Message indices are **zero-based** positions in the parsed message sequence
  of one chat file; ranges (`chat_range`, `ChatAnalyst.range`) are inclusive
  at both ends.
- `characters` counts the characters of the **parsed message content** string;
  it is never a file byte offset. Cumulative offsets are deliberately not
  exposed (documented Phase A decision: exactly one coordinate system —
  parse position — that cannot drift from `Chat.load`).
- Paths in public results are canonical absolute paths, directly usable as
  later inputs — ONE canonical spelling across every public operation
  (overview, relationships, range, tool_calls; `Chat.provenance_path`
  realpath with expand_path fallback), pinned against `/home/...` vs
  `/bulk/...` alias mount spellings. The legacy `"path#index"` address
  spelling is gone: no exported task concatenates it (the four adapters that
  carried it were retired in phase 2).
- No `Chat`/`Step`/`Path` instances and no synthetic ids (`c1`, `j1`) appear
  in any public result.
- There is **no `follow` input anywhere**: traversal always follows job
  references and direct dependencies, and never follows delegation targets or
  live sidecar chats. (Legacy `follow` was dropped in the Stage 0 decision
  recorded in `research/stage0-notes.md`; zero consumers used it.)
- ChatAnalyst never calls the retired materialized-graph collectors
  (`provenance_closure` / `provenance_edges` / `provenance_chat_files` /
  `provenance_jobs`); the old materialized reconstruction is gone.

## Public Ruby API (`lib/ChatAnalyst/api.rb`)

```ruby
ChatAnalyst.overview(root, root_type: nil)
ChatAnalyst.timeline(root, bursts: [], burst_gap: 120)
ChatAnalyst.message_index(chat_path)          # one chat; no bodies
ChatAnalyst.message(chat_path, index)         # full retrieval of one message
ChatAnalyst.range(chat_path, first, last)     # inclusive range, one chat
ChatAnalyst.tool_calls(chat_path, first: nil, last: nil)
ChatAnalyst.tokens(root)
ChatAnalyst.attribution(root)                 # root/delegated/unattributed split
ChatAnalyst.relationships(chat_path)
ChatAnalyst.live(root)
```

`root` is a chat file path or a job root (a persisted Step directory,
detected by its `.info` sidecar); `root_type: :chat | :job` overrides the
detection. Shapes:

- **overview** — `{root: {type, path}, chats: [{path, messages, roles,
  job_references (index→path|Array), delegation_references (index→
  "Agent#conversation"), live, warnings}], jobs: [{path, dependencies
  (declared order), live, warnings}], live_missing?, unloaded_references?}`.
  Queue-based breadth-first traversal, one `provenance_graph` call per node;
  chat/job identity stay distinct even when a chat-producing job and its
  output chat share a path. A job node contributes ONLY its generated output
  chat (`Chat.job_result_chat_file`); its input chat is invocation context
  and is never read. Live sidecar paths are listed, never traversed.
  `job_references`/`delegation_references`/`dependencies` are recursively
  normalized to plain canonical Strings (hardening; pinned — no Pathname/Path
  instances and no alias spellings). `unloaded_references` entries are
  `{kind, path, error, via}` where `via` records the originating reference
  `{from_kind, from_path, context}` (phase-2 enrichment; `via.context` is
  the receipt or message context that produced the reference).
- **timeline** — two modes. Default (no `bursts`): `{root, summary: {chats,
  jobs, bouts, implicit_bouts, calls, delegations, bursts}, bouts: [...],
  bursts: [...] (compact: id, chats, bout count, call counts),
  live_missing?, unloaded_references?}`. Selection mode (`bursts:` given):
  `{root, summary, selected_burst_ids, bursts: [selected bursts with their
  bouts INLINED], live_missing?, unloaded_references?}` — and **no `:bouts`
  key at all** (the selected bouts appear only inside their bursts; the
  pre-phase-1 duplication — all bouts + selected bouts inlined again — is
  gone, pinned by a regression test). Bouts are anchored by chat path +
  first/last zero-based indices + timestamp (when present) + reasoning
  character count + compact preview + tool-call positions. The persisted
  planned interaction is the `user`/`meta`/`assistant` triplet with the
  **`meta` message as the inference anchor**. Reasoning-only bouts are
  preserved; implicit tool-call bouts (call+output without intervening
  assistant reasoning) are labeled `implicit: true`. Bursts are TEMPORAL
  groupings only (elapsed gap above `burst_gap` seconds); they carry no
  semantic phase claims. Cross-chat references always stay chat path + that
  chat's own indices — no
  per-chat-restarting event numbering. Timestamps are parsed defensively:
  unparseable values become nil and never abort the report.
- **message_index / message / range** — Ruby API methods (the `message_index`
  TASK was retired in phase 2; the method stays): indexing and retrieval for
  one chat; useful errors name the chat path, the requested index and the
  valid range; large messages are identified by `characters` alone
  (`LARGE_MESSAGE_CHARACTERS` = 100000) and never inlined by the index.
- **tool_calls** — `{chat, first?, last?, calls: [{tool, call_id, call_index,
  output_index, timestamp?, status (:success/:failure/:error/:unknown),
  output_characters, delegated, delegation_target?, jobs: [paths]}]}`.
  Receipt-derived job references attach to the outer `function_call_output`
  message index (the compact graph's `chats` mapping); ask calls use the
  `delegation` mapping; an ask without a job reference is still a valid
  delegation entry (`delegated: true, jobs: []`). Delegation target and
  materialized job stay distinct: a job is never inferred from agent name,
  society directory or path convention. Dedup identity: two calls classify as
  copies only with sufficient identity evidence — identical tool + arguments
  with a MISSING call id never auto-collapses two independent calls.
  Arguments and outputs are not inlined.
- **tokens** — `{root, scopes: {deduplicated_total, chat_evidence,
  receipt_evidence, receipt_only}, conflicts: {events,
  incomplete_evidence_events, authoritative}, events: [...], warnings}`.
  Delegated wholesale to `Chat.provenance_token_events` and
  `Chat.provenance_token_totals`: field semantics (pt/ct/tt/cct/cwt/rt),
  canonical-evidence counting, identity/conflict rules and the checkpoint
  exclusion of `*_c`/`*_s` all live in the core; no accounting is rebuilt
  here. Scopes are EVIDENCE COVERAGE descriptions, never a partition of
  cost: `chat_evidence` and `receipt_evidence` overlap and must not be
  summed; only `deduplicated_total` and `receipt_only` compare additively.
  A conflicting event is counted once from canonical evidence; a total
  containing conflicts is best-effort (`conflicts.authoritative: false`).
- **relationships** — `{chat, references: [{type (:import/:continue/:last),
  message_index, target, resolved, unresolved_reason?}], targets,
  import_closure}`. Import/continue/last references are inspected SEPARATELY
  from core provenance (the core traversal deliberately ignores them);
  `import_closure` is the post-order, cycle-safe walk over resolved `import:`
  references only. Unresolved local references are reported
  (`resolved: false, unresolved_reason: :missing`), never raised.
- **live** — LIVE (in-flight) state for the tree rooted at `root`, delegated
  to `Chat.live_report` over the root's save file; fail-soft throughout.
  Entry kinds: `:inference`, `:workload_context`, `:agent_activity`,
  `:dangling_job`; entries carry plain-string paths/references (the core's
  transient `:step` objects are stripped).

### Cache and freshness (timeline)

Freshness identity comes from ONE traversal: digests over the root kind +
canonical path, every visited chat file's content, every visited job's result
and `.info` bytes, and the discovered live-path set. The in-process cache is
keyed `[root_kind, canonical_path, burst_gap]`, LRU-bounded, and stores a
deep copy of compact metadata only — never `Chat`/`Step` objects. Chat
append, job result/metadata change, or live/relationship discovery all
invalidate; the traversal runs on every call, so a new invocation always sees
newly appended messages.

## Import closure accounting

Imported and continued chats are not part of core provenance; their content
is already inlined in the persisted chat file during `Chat.parse`. To account
for them anyway, `ChatAnalyst.relationships` recovers `import:`, `continue:`,
and `last:` references from the uncompiled chat text and resolves them with
`Chat.find_file`, and `chat_accounting` accounts each chat of the import
closure separately from its own file (`scope: own` / `scope: closure`).

A meta message starts a response segment. The segment can contain several
tool calls, tool outputs, and an assistant message. It ends at another meta,
a new user/system turn, or the end of the chat. A meta with an empty segment
is an orphan record for a removed response message.

Direct `pt`, `ct`, `cct`, `rt`, and `tt` metadata records one inference.
Records carry an `inference_id`, used for exact deduplication. `meta job=...`
marks one response segment projected from an ask job and has no direct token
cost; the job's logs and dependencies contain the actual inference metadata.
Running `*_c` and `*_s` values are checkpoints and are not summed.

## Token count categories

- pt: prompt tokens
- ct: completion tokens
- tt: total tokens
- cct: cache tokens (subset of prompt tokens)
- cwt: cache write tokens
- rt: reasoning tokens

When discussing tokens always consider that cache tokens are much less
expensive in general (about 10% of the normal cost).

## Society chats and legacy socialized projections

When a Manager or supervisor agent dispatches work to a specialist agent
through the `ask` tool with a named `conversation`, the specialist
interaction is persisted as a full chat of the society tree:

```text
<caller_job>.files/<name>.society/<AgentName>/<conversation>/agent.chat
```

These files are the agent's full chats, including the tool calls and the
direct inference metadata of every model call, so they are counted directly
by `chat_tokens` and appear like any other chat of the session. Older
scout-ai wrote legacy socialized projections at
`<caller_job>.files/log/chats/<AgentName>/<conversation_name>.chat`; they
carry zero direct inference tokens and a `meta: job=<path>` marker — follow
the reference to the specialist's ask-job for the real usage.

Typical programmatic use:

    report = ChatAnalyst.tokens('/path/to/session.chat')
    view   = ChatAnalyst.attribution('/path/to/session.chat')

For command-line inspection of the same model, use:

    scout-ai llm prov /path/to/session.chat

## Delegated agent receipts (`meta`)

When an agent requests help from another agent using `ask` (or a
`hand_off_to_*` tool), the `function_call_output` envelope may include `meta`
receipts carrying the delegated inference's meta records: direct token
records and, when the child ran as a `chat_task`, a `job=` reference to the
producing Step. These receipts make delegation auditable even when no child
chat or job was saved. Receipt records are embedded evidence, never messages
of the parent chat. Provenance traversal follows their `job=` references, and
token accounting counts their direct events once, deduplicated by
`inference_id` against any saved child log that carries the same event.

## Gem trap

The installed scout-ai 2.0.0 gem predates the compact provenance API
(`provenance_graph`, `live_report`, `provenance_token_events` etc.). Every
test or programmatic run must resolve the checkout:

    ruby -I/home/mvazque2/git/scout-ai/lib -Itest test/<file>.rb

from the checkout root. The test helper asserts
`Chat.respond_to?(:provenance_graph)` as a canary so gem shadowing fails
loudly.

# Tasks

Eight analytic tasks (thin adapters over the module methods: argument
validation + serialization only) plus three operational tasks. The four
Phase C legacy adapters were retired in phase 2 (see "Retired adapters").

## chat_overview
Compact overview of the provenance tree.

Thin task over `ChatAnalyst.overview`. Inputs: `file` (root chat or job),
`root_type`. Chats with message/role counts and job/delegation references
keyed by originating message index; jobs with direct dependencies. Absolute
canonical paths (one spelling across every task), zero-based indices, no
bodies; `unloaded_references` entries carry `{kind, path, error, via}`.

## chat_timeline
Timeline of persisted interaction bouts.

Thin task over `ChatAnalyst.timeline`. Inputs: `file`, `bursts` (ids whose
bouts are inlined as detail), `burst_gap` (seconds, default 120). Bursts are
temporal groupings only (elapsed-gap), never semantic phases.

## chat_messages
Zero-based index of every message in one chat: role, character count,
`large` flag, timestamp when present. Never bodies. Inputs: `file` (chat
file), `role` (filter), `page`, `per_page` (pagination envelope; filters and
paging narrow the list only). Carries the retired `message_index`
capabilities (role filter, pagination, large-message flag).

## chat_range
Inclusive retrieval of one message range from one chat, loading only the
addressed chat. Inputs: `file`, `first`, `last` (zero-based, inclusive;
`first == last` is valid), `raw` (default false). Task-level cap
`MAX_RANGE_MESSAGES` (200): an oversized range raises `ParameterException`
naming the cap and suggesting sub-ranges; the Ruby API `ChatAnalyst.range`
stays uncapped. With `raw: true` the response carries the exact persisted
`.chat` text of the slice (`Chat.print` of the selected messages, byte-exact,
inside the JSON envelope's `raw` String) alongside the structured
`messages` — the retired `extract_chat_range` semantics; only a job root
(.info sidecar) is rejected as before.

## chat_tokens
Deduplicated direct-inference token accounting (scopes, conflicts, evidence
locations) delegated to the core provenance token APIs. Inputs: `file`,
`page`, `per_page`, `attribution` (default false). Legacy-compatible flat
totals (`deduplicated_total` etc.) appear alongside the structured `scopes`
Hash in the UNPAGINATED shape only: an event page (`page` set) carries the
events plus paging metadata and `root` — no repeated scopes, flat totals,
conflicts or warnings (phase-2 layering fix). With `attribution: true` the
response also carries the attribution view (below), computed from its own
single token-event fetch (the task's summary and view each fetch events
once; the Ruby API accepts a prefetched report to share one fetch).

## Attribution view (`ChatAnalyst.attribution` / `chat_tokens attribution:`)

The promoted public method `ChatAnalyst.attribution(root)` (minimal revision
phase 2, decision D2; formerly the delegation half of the retired
`chat_report` composite) splits the deduplicated event list ONCE:

- `total` — deduplicated total token fields plus an event count;
- `root_chat_tokens`/`root_chat_events` — events whose canonical evidence
  (`evidence.first`) lies in the root chat itself, or on a job root in the
  job's OWN chats (generated result chat + direct log chats), never its
  dependencies;
- `delegated_tokens`/`delegated_events` — events whose canonical evidence
  lies in any chat of a LINKED delegation job (own logs and result chats,
  recursively through nested delegation jobs; frontier walk over receipt
  job references plus the root job's own log-chat receipts, cycle-safe);
- `unattributed_tokens`/`unattributed_events` — everything else;
- `linked_jobs` — canonical job paths (the root job's own path excluded);
- `unresolved_jobs` — referenced delegation jobs whose cost is missing
  because the job could not be resolved (never nil; reference-less problems
  are counted in `malformed_edges`).

`root + delegated + unattributed` reconciles with `total`. Standalone
`ChatAnalyst.attribution` fetches events with exactly ONE `tokens` call
(pinned by an instrumentation test); a caller that already holds a tokens
report passes it via `tokens_report:` to share that single fetch.

## Retired adapters (phase 2)

The four Phase C legacy adapters — `message_index`, `message_content`,
`extract_chat_range`, `chat_report` — were retired in the phase-2 minimal
revision (plan step 5). Retired names raise `TaskNotFound`. Byte-for-byte
snapshots of the deleted declarations plus SHA256SUMS live in
`var/baselines/rev-phase2-removed/`. Their pinned coverage now lives on:
`chat_messages` (whole-session indexing per chat), `chat_range` `raw: true`
(raw slice text, first==last, range validation), `chat_tokens`
`attribution: true` (delegation rollup, unresolved_jobs). Deliberate losses:
`message_content`'s cross-chat batch fetch by flat id (the migrated agent
issues one `chat_range` per chat) and `chat_report`'s session-dedup count
plus first-10 failure list (`chat_tool_calls` carries the same raw counts and
every call record locates its own failure detail).

## chat_tool_calls
Structured tree-wide tool-call index (minimal revision phase 1, plan step 4;
declared in `lib/ChatAnalyst/tasks/api_tasks.rb`). Per-call records:
`{chat, call_index, output_index?, tool, call_id?, status (:success/:failure/:unknown),
delegated, delegation_target?, jobs, argument_characters, output_characters,
copy_of?}` — a chat path plus integers, never a `"path#index"` string and never
a legacy boolean `success`. Inputs: `file`, `page`, `per_page`, `dedupe`,
`tool`, `agent`, `conversation`, `chat`, `success` (filters narrow the call
list only; summary counts stay raw; `agent`/`conversation` are the two halves
of `delegation_target` `"Agent#Conversation"`). Universe and dedupe identity
are unchanged: overview chats plus each job's live log chats (uniq), copies
marked through `tool_call_identity`/`mark_call_copies` (MD5 stays internal).

## chat_tool_call
Full evidence for exactly ONE tool call (minimal revision phase 1, plan step
2): `arguments` (parsed Hash when parseable, else the raw String),
`argument_characters`, the actual persisted output content plus
`output_characters`, `output_info?` (envelope fields sans content),
`status`/`reason`/`error?`, `delegated`, `delegation_target?`, `jobs`,
`timestamp?`/`start_timestamp?`. Inputs: `file` (chat path), `call_index`
(the zero-based index of the function_call/mcp_call message that STARTS the
call, matching the compact index). Raises `ArgumentError` naming the chat,
the offending index and the valid call-start indices when no call starts at
`call_index`. Detail counterpart of `chat_tool_calls`; single-message
retrieval is `chat_range` with `first == last`.

## chat_accounting
Per-chat accounting with import-closure scopes (`own` / `closure`); calls the
core token APIs, one entry per chat. Inputs: `file`, `scope`. Phase-2
efficiency fix (D4 keep+fix): tokens/overview/relationships are computed ONCE
per chat (own scope reuses the same fetched events for the closure merge;
pinned by an instrumentation test — `ChatAnalyst.tokens` is called exactly
once per chat in both scopes).

## live_chats
Operational live-chat discovery: compact-graph `live` listing plus the
`DIRECT_LOG_CHAT_GLOBS` fallback for unsaved logs, newest-first with active
flags. Input: `file`.

## inbox_state / post_inbox_advice
Operational inbox inspection and advice posting for a live inference; the
reserved `abort` note name is rejected. Inputs: `file` (both), `message` +
`name` (post_inbox_advice).
