# ChatAnalyst developer documentation

Implementation, contract and environment material for the ChatAnalyst
workflow. Analyst-facing usage lives in
[ChatAnalyst/README.md](../../README.md) and [doc/user/README.md](../user/README.md);
this file owns the developer view.

## Vocabulary: `meta`, not `agent_meta`

Receipt records are read through the **`meta`** field of
`function_call_output` envelopes. The legacy `agent_meta` key is no longer
read by the core: the compact graph resolves receipts internally, and
ChatAnalyst consumes `Chat.provenance_graph` / `Chat.provenance_token_events`,
which return the resolved evidence (standalone `meta: job=` refs anchored at
their own message index; receipt `job=` refs anchored at the outer
`function_call_output` index). Embedded receipts are *evidence*, never
messages of the parent chat, and are never listed by `ChatAnalyst.message_index`.
(`agent_meta` survives only as a legacy input column in the token-evidence
tables: `origin (chat_meta | agent_meta)` rows describe where each record
was read from.)

## Addressing contract (internal rules)

- Message indices are **zero-based** positions in the parsed message sequence
  of one chat file; `chat_range` spans are inclusive at both ends.
- `characters` counts the characters of the **parsed message content** string;
  it is never a file byte offset. Cumulative offsets are deliberately not
  exposed: exactly one coordinate system — parse position — exists, so it
  cannot drift from `Chat.load`.
- Paths in public results are canonical absolute paths, directly usable as
  later inputs — ONE canonical spelling across every public operation
  (`Chat.provenance_path` realpath with expand_path fallback), pinned against
  `/home/...` vs `/bulk/...` alias mount spellings. In TSV keys and cells the
  canonical path is **escaped** per the encoding conventions below; unescape
  before feeding a path back into a task `file` input.
- `:chat` outputs (`chat_message`, `chat_range`) are the bare persisted chat
  text with **no `#:` annotation line and no metadata sidecar** (pinned by
  the regression tests `test/test_chat_range_raw.rb` and
  `test/test_agent_meta_tasks.rb`): their addressing (chat path,
  first/last indices) lives in the **persisted job inputs** (`step.info`
  `inputs`/`provided_inputs`), never in the output text. Consumers cannot
  read annotations from a `:chat` output.
- No `Chat`/`Step`/`Path` instances and no synthetic ids appear in any public
  result.
- There is **no `follow` input anywhere**: traversal always follows job
  references and direct dependencies, and never follows delegation targets or
  live sidecar chats.
- ChatAnalyst never calls the retired materialized-graph collectors
  (`provenance_closure` / `provenance_edges` / `provenance_chat_files` /
  `provenance_jobs`).

## Public Ruby API (`lib/ChatAnalyst/api.rb`, `lib/ChatAnalyst/inferences.rb`)

```ruby
ChatAnalyst.overview(root, root_type: nil)
ChatAnalyst.message_index(chat_path)          # one chat; no bodies
ChatAnalyst.message(chat_path, index)         # full retrieval of one message
ChatAnalyst.range(chat_path, first, last)     # inclusive range, one chat
ChatAnalyst.tool_calls(chat_path, first: nil, last: nil)
ChatAnalyst.tool_call(chat_path, call_index)
ChatAnalyst.tokens(root)
ChatAnalyst.attribution(root)                 # root/delegated/unattributed split
ChatAnalyst.relationships(chat_path)
ChatAnalyst.live(root)
ChatAnalyst.inferences(root, max_gap_seconds: 120)
ChatAnalyst.activity_clusters(root, max_gap_seconds: 120)
ChatAnalyst.activity_cluster(root, cluster_id, max_gap_seconds: 120)
```

`root` is a chat file path or a job root (a persisted Step directory,
detected by its `.info` sidecar); `root_type: :chat | :job` overrides the
detection. Four further module methods are public but auxiliary,
not part of the analytical surface above: `overview_job_frontier(root)`
(the frontier of directly referenced jobs), `relationship_references(path)`
(import:/continue:/last: reference events of one chat),
`inference_owner_map(chat)` (call-start → owning inference meta index) and
`delegation_target_parts(target)` (`agent#conversation` split helper).

### API behavior notes

- **overview** — `{root: {type, path}, chats: [...], jobs: [...],
  live_missing?, unloaded_references?}`. Queue-based breadth-first
  traversal, one `provenance_graph` call per node; chat/job identity stay
  distinct even when a chat-producing job and its output chat share a path.
  A job node contributes ONLY its generated output chat; its input chat is
  invocation context and is never read. Live sidecar paths are listed, never
  traversed. References are recursively normalized to plain canonical
  Strings. `unloaded_references` entries are `{kind, path, error, via}`.
- **inferences / activity_clusters / activity_cluster** — the
  inference and activity-cluster model described below; one computation per
  (root, max_gap_seconds), shared by the three tasks through a Scout task
  dependency (`chat_activity_cluster` `dep`s `chat_activity_clusters`).
- **tokens / attribution** — delegated to `Chat.provenance_token_events` /
  `provenance_token_totals`; scopes are EVIDENCE COVERAGE descriptions,
  never a partition of cost (see the overlap warning under chat_tokens).
- **live** — LIVE (in-flight) state for the tree rooted at `root`, delegated
  to `Chat.live_report` over the root's save file; fail-soft throughout.

## Cache and freshness

Freshness identity comes from ONE traversal: digests over the root kind +
canonical path, every visited chat file's content, every visited job's result
and `.info` bytes, and the discovered live-path set. The in-process caches
(TIMELINE_CACHE in `api.rb`, INFERENCE_CACHE in `inferences.rb`) are keyed
by root kind + canonical path + parameter, bounded, and store deep copies of
compact metadata only — never `Chat`/`Step` objects. The traversal runs on
every call, so a new invocation always sees newly appended messages.

## Import closure accounting

Imported and continued chats are not part of core provenance; their content
is already inlined in the persisted chat file during `Chat.parse`. To account
for them anyway, `ChatAnalyst.relationships` recovers `import:`, `continue:`,
and `last:` references from the uncompiled chat text and resolves them with
`Chat.find_file`, and `chat_accounting` accounts each chat of the import
closure separately from its own file (`scope: own` / `scope: closure`).

## Meta / response-segment semantics

A meta message starts a response segment. The segment can contain several
tool calls, tool outputs, and an assistant message. It ends at another meta,
a new user/system turn, or the end of the chat. A meta with an empty segment
is an orphan record for a removed response message.

Direct `pt`, `ct`, `cct`, `rt`, and `tt` metadata records one inference.
Records carry an `inference_id`, used for exact deduplication. `meta job=...`
marks one response segment projected from an ask job and has no direct token
cost; the job's logs and dependencies contain the actual inference metadata.
Running `*_c` and `*_s` values are checkpoints and are not summed.

## Society chats and legacy socialized projections

When a Manager or supervisor agent dispatches work to a specialist agent
through the `ask` tool with a named `conversation`, the specialist
interaction is persisted as a full chat of the society tree:

```text
<caller_job>.files/<name>.society/<AgentName>/<conversation>/agent.chat
```

These files are the agent's full chats, including the tool calls and the
direct inference metadata of every model call, so they are counted directly
by the token tasks and appear like any other chat of the session. Older
scout-ai wrote legacy socialized projections at
`<caller_job>.files/log/chats/<AgentName>/<conversation_name>.chat`; they
carry zero direct inference tokens and a `meta: job=<path>` marker — follow
the reference to the specialist's ask-job for the real usage.

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

## Encoding conventions

Every TSV output follows these conventions; the essentials:

- **Escaping** (applied to every path-valued key and cell, single pass):

  | raw | escape |
  |---|---|
  | `%` | `%25` |
  | `#` | `%23` |
  | TAB | `%09` |
  | NEWLINE | `%0A` |
  | CR | `%0D` |

  The table is closed: no other character is escaped (`|`, `~`, spaces stay
  literal; this is NOT URL encoding). Unescape recognizes exactly the five
  spellings above; every other `%` sequence is left verbatim. Unescape a
  path before feeding it back into a task input.

- **Null vs empty**: in String columns the two-character sentinel `\N` means
  NULL; the empty string `""` always means empty string, never null. Cast
  numeric tables (`:to_i`/`:to_f`) use the native empty-cell => nil. Every
  row is written with ALL cells present; no trailing-cell asymmetry.
- **Booleans**: the strings `true`/`false`; NULL boolean is `\N`. There is
  no `:to_b` cast in the loaded stack.
- **Timestamps**: UTC `iso8601(3)` (milliseconds), normalized when
  parseable; a missing OR unparseable timestamp is `\N`. Never invented.
- **Numbers**: mixed tables (strings + counts) carry decimal strings
  (`42`, `3.5`); tables whose every field is numeric cast `:to_i`/`:to_f`
  table-wide (global cast only; per-field cast is banned by the contract).
- **Multi-value cells** are `|`-joined and `|`-free by construction
  (enforced by the writers; the dumper rejoins with `|`). Multi-value
  columns exist in `chat_activity_clusters` (chats), `chat_accounting`
  (imports, unresolved_imports, delegated_subtrees) and `chat_live_report`
  (source).
- **Composite row keys** join escaped parts with `#`: because every path
  part is escaped, splitting a key on `#` recovers the parts unambiguously.
  Grammars: `message_id#reference_type#occurrence`,
  `owner_job#dependency#position`, `dependency#depth`,
  `chat#role`, `call_message_id#escaped_job_path`,
  `token_event_id#occurrence`, `message_id#format#index` (evidence
  addresses). A Message id is `escaped_chat_path#index` — parse it on the
  FIRST `#` when recovering the chat path and index.
- **TokenEvent identity grammar**: `identity-kind#escaped-value` where the
  value part of a `receipt` identity may itself contain `#` (an escaped
  evidence address) — only the KIND is guaranteed separator-free, so split
  on the FIRST `#` only. Identity kinds: `inference_id`,
  `provider_response_id`, `lineage`, `receipt`.
- **Annotations**: page/per_page/total/total_pages/next_page/prev_page,
  root_path, max_gap_seconds, scope, filters, chats/jobs/delegations,
  clusters/inferences/unclustered, conflicts/incomplete_evidence ride the
  `TSV.annotation` `#:` line (registered once at library load by
  `lib/ChatAnalyst/tsv_base.rb`; values survive `TSV.open` and task
  persistence). Path-valued annotations carry the ESCAPED path (a raw `#`
  would corrupt the `#:`-joined line). An absent directive means nil
  (correct for next_page/prev_page).
- **Pagination semantics**: `page` (1-based) and `per_page` (default 50)
  apply only when `page` is given; a page bounds the main list only, never
  totals; an out-of-range page yields empty rows, not an error; `total`
  always counts the unpaginated universe.
- **Allowed cell content**: identifiers, paths, controlled enumerations,
  timestamps, counts, sizes, token numbers, booleans, foreign keys, short
  structured values (tool_name, target_agent, target_conversation).
  Excluded everywhere: message bodies, reasoning text, tool argument/output
  content, exception messages, note contents. `chat_message`/`chat_range`
  (`:chat`) and `inbox_note` (`:text`) are the ONLY body-carrying surfaces.

## Identifier grammar

- **Chat** = escaped absolute canonical chat path (`Chat.provenance_path`
  spelling; no new canonical form invented).
- **Job** = escaped absolute canonical job path. A DISTINCT entity type
  from Chat even when a chat-producing job and its output chat share one
  path.
- **Message** = `escaped_chat_path + '#' + zero-based decimal index` into
  that chat's parsed message sequence.
- **Inference** = the Message id of its meta message (one inference per
  meta).
- **ToolCall** = the Message id of the call-start message
  (function_call/mcp_call).
- **Activity cluster** = the Message id of the cluster's FIRST inference;
  scoped by (root, max_gap_seconds), re-derivable, never persisted as an
  identity.
- **Token event** = the core identity Array rendered
  `identity-kind#escaped-value` (see the grammar note above).
- **Note / Posted** = escaped absolute file path.
- `:chat` outputs carry their addressing in the persisted job inputs
  (`step.info`), not in the output text and not in annotations — consumers
  cannot read annotations from a `:chat` output.

## The inference / activity-cluster model

- **One inference per meta message.** Scout-ai UNSHIFTS each inference meta
  BEFORE the response segment it accounts for, so the persisted shape is:
  META, [assistant text when present], [its tool calls], [outputs]. The
  inference span is: first = the message right after the PREVIOUS meta in
  that chat (the chat's first message for the first meta), last = the meta
  itself. Consecutive metas (reasoning-only rounds) yield first == last ==
  the meta.
- **EMITTER ownership (pinned by fixtures)**: a tool call belongs to the
  LAST inference meta BEFORE it in the same chat — its emitter. A call
  with no preceding meta (an opening unaccounted call, legacy chats) is
  unassociated (`inference_id` = `\N`); NO synthetic inference is ever
  created.
- **Trigger** = the nearest preceding non-meta message (the user request or
  the tool output being reacted to), scanning past consecutive metas; nil
  when nothing precedes. **Assistant** = the meta's immediate successor
  when its role is 'assistant'. **reasoning_present/characters** come from
  the META's `reas` field only (whitespace-normalized count); content is
  never returned.
- **Clusters** = maximal runs of CONSECUTIVE TIMESTAMPED inferences (in the
  tree-wide chronological sequence) whose adjacent gaps are at most
  `max_gap_seconds` (default 120). ONLY timestamped inferences cluster: an
  undated inference joins NO cluster, carries `\N` activity_cluster_id,
  never bridges distant clusters, and influences no gap computation —
  `unclustered` is a real, possibly-nonzero count of exactly these.
  Clusters are temporal groupings only; they make no semantic claims about

## Recursive dependencies

- `job_dependencies` — the DIRECT declared edges, one row per edge, with
  1-based `position` in declared order; ownership lives in this table.
- `job_dependencies_recursive` — the closure: BFS over direct dependencies
  seeded from the ROOT-OWNED jobs only (the root job itself, or for a chat
  root the jobs the root chat references), so depth 1 means a direct
  dependency of a root-owned job; smallest-depth wins, equal-depth
  duplicates collapse to the first `via_owner`, cycle-safe by the visited
  set, stops at `max_depth` (default 10). Seed nodes never become rows.

## Retired task names

Calling a retired name raises `TaskNotFound`. Byte-for-byte snapshots of the
deleted declarations plus SHA256SUMS live in `var/baselines/`:

- `message_index`, `message_content`, `extract_chat_range`, `chat_report` —
  legacy adapters; their coverage lives on in `chat_messages`, `chat_range`
  and `chat_attribution`.
- `chat_timeline` — temporal grouping and drill-down live in
  `chat_activity_clusters` + `chat_activity_cluster` (overview and member
  detail) and `chat_inferences`, all over
  `ChatAnalyst.inferences`/`activity_clusters`.

## scout-ai version guard (conditional)

ChatAnalyst requires the compact provenance API (`Chat.provenance_graph`,
`Chat.provenance_token_events`, `Chat.live_report`), which exists in
scout-ai **2.1.0 and later**. If ChatAnalyst (or its tests) fails to load
or the provenance canary fails, check in this order:

1. **Which scout-ai is active**: `ruby -e 'require "scout-ai"; puts
   Gem.loaded_specs["scout-ai"].full_name; puts Chat.respond_to?(:provenance_graph)'`.
   Installed 2.0.0 or older gems predate the API (the 2.0.0 gem lacks
   `provenance_graph`).
2. **Resolve a newer source when the gem is old**: run with
   `-I<scout-ai-checkout>/lib` so the checkout's `scout/` shadows the gem.

In THIS environment (2026-11-14) scout-ai 2.1.0 is the active gem and
`Chat.respond_to?(:provenance_graph)` is true, so no `-I` override is
needed. The test helper still asserts the canary
(`test/test_chat_analyst_api.rb`: `test_scout_ai_core_provides_the_compact_provenance_api`,
message "Chat.provenance_graph missing: the scout-ai 2.0.0 gem shadowed the
checkout") so a future
regression to an old gem fails loudly instead of producing nil graphs.

## Limitations, honestly

- **Git state**: this checkout is a working submodule (`.git` points at
  `../.git/modules/ChatAnalyst`), but that parent module directory is
  currently absent on this machine, so `git -C ChatAnalyst ...` fails with
  "not a git repository". Treat the tree as plain files; provenance in this
  checkout is snapshot-based (`var/baselines/` + SHA256SUMS + working run
  records under `tmp/`), which does not depend on git.
- **Scale receipts** (real tree, the 6.59 MB / 3128-message ScoutCoder
  chat, 1035 calls, 1034 timestamped inferences):
  `chat_tool_calls` page 1/50 = 2.24 s / 30,803 bytes; `chat_tool_call`
  detail = 1.559 s / 991 bytes; `chat_activity_clusters` = 3.4 s / 34 rows
  (13,214 bytes); `chat_inferences` page 1 (per_page 20) = 0.82 s; tokens
  family on the child chat: `chat_tokens` 6.5 s, `chat_attribution` 7.3 s.
- **chat_evidence / receipt_evidence overlap**: the two scope rows are
  EVIDENCE COVERAGE descriptions and MUST NOT be summed; only
  `deduplicated_total` and `receipt_only` compare additively.
- **`:chat` outputs carry no annotations** — addressing must be recovered
  from the persisted job inputs, never parsed out of the output text.
- **Post behavior**: a `post_inbox_advice` job replays from cache when the
  jobname digest is unchanged; tests and repeated postings should use
  distinct names or clean the job.
