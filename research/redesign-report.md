# ChatAnalyst redesign — Stage 10 report (Phases A–C, plan steps 1–8)

Phases A/B/C implemented the user-approved 9-step redesign plan
(`tmp/redesign/phase-a-notes.md`, `phase-b-notes.md`, `phase-c-notes.md` hold
the per-phase bout records; this is the closing summary). Step 9 (Critic
gate) is dispatched by the Manager on top of this report.

## What the redesign delivered

ChatAnalyst was refactored from a materialized-graph reconstruction (the
retired `provenance_data` helper walking `provenance_closure` /
`provenance_edges` / `provenance_chat_files` / `provenance_jobs`) onto
scout-ai's compact one-node provenance API, with a public Ruby API as the
single place where provenance semantics live and thin workflow tasks over it.

## Public Ruby API (`lib/ChatAnalyst/api.rb`)

Nine plain module methods, all returning serializable Hash/Array of canonical
absolute paths, zero-based integer indices and counts:

| method | signature | stage |
|---|---|---|
| `overview` | `(root, root_type: nil)` | 2 (Phase A) |
| `timeline` | `(root, bursts: [], burst_gap: 120)` | 4 (Phase B) |
| `message_index` | `(chat_path)` | 3 (Phase A) |
| `message` | `(chat_path, index)` | 3 (Phase A) |
| `range` | `(chat_path, first, last)` | 3 (Phase A) |
| `tool_calls` | `(chat_path, first: nil, last: nil)` | 5 (Phase B) |
| `tokens` | `(root)` | 6 (Phase C) |
| `relationships` | `(chat_path)` | 6 (Phase C) |
| `live` | `(root)` | 6 (Phase C) |

Invariants held throughout: zero-based indices, inclusive ranges, `characters`
= parsed content characters (never file bytes; cumulative offsets deliberately
omitted — one coordinate system), no `"path#index"` strings in the new
surface, no `Chat`/`Step`/`Path` instances or synthetic ids in results, no
calls to the prohibited collectors, and **no `follow` input anywhere**
(Stage 0 decision: zero consumers found; the core has one node per call and
callers recurse).

## Exported task family (final)

Six thin tasks (`lib/ChatAnalyst/tasks/api_tasks.rb`; argument validation +
serialization only): `chat_overview`, `chat_timeline`, `chat_messages`,
`chat_range`, `chat_tokens`, plus `chat_tool_calls` served through its legacy
adapter. Four legacy adapters with the only live external consumer (the
ChatAnalyst agent's own `{file}` / `{file, page, per_page}` / `{file, ids}`
shapes; sweep table `research/stage0-notes.md` §1): `message_index`,
`message_content`, `chat_tool_calls`, `chat_report`. Kept thin adapters for
pinned semantics with zero external consumers: `extract_chat_range`
(its 6-test suite pins ParameterException + `:chat` output) and
`chat_accounting` (import-closure own/closure scopes). Untouched operational
tasks: `live_chats` (re-pointed to the compact `live` listing +
`DIRECT_LOG_CHAT_GLOBS` fallback), `inbox_state`, `post_inbox_advice`.

Retired (zero external consumers; copies + SHA256SUMS in
`var/baselines/phase-c-removed/`): `chat_agents`, `meta_evidence`,
`chat_reasoning`, `provenance_relationships` (semantics live on as
`ChatAnalyst.relationships`), and — from Phase B — the heuristic
`chat_timeline`/`timeline_index` pair with the whole
`lib/ChatAnalyst/tasks/timeline.rb`.

## How overview traverses the compact index

`Chat.provenance_graph` is called once per node (queue-based BFS). Chat nodes
contribute path/message count/role counts/job references/delegation
references keyed by originating message index (Array when two references share
one index — `add_indexed_reference`), plus `live` sidecar paths listed but
never traversed. Job nodes contribute canonical path + direct dependencies in
declared order; a job contributes a transcript only via
`Chat.job_result_chat_file` (its input chat is invocation context, never
read). Visited identity is keyed `[kind, canonical_path]`, so chat and job
identity stay distinct even when a chat-producing job and its output chat
share a path; unloadable nodes land in `unloaded_references`, so cycles and
missing references terminate instead of raising.

## Removed heuristics (Phase B), with rationale

The old timeline modeled interaction shape with unsound heuristics; each was
removed with its defect evidence (full list with old line anchors in
`tmp/redesign/phase-b-notes.md`):

- Tool-group profiles / dominant-group classification — invented
  semantic phases with no persistence backing; bursts are now temporal only.
- Resource extraction from tool arguments — argument-shape guessing that
  inlined unbounded content; gone entirely (no arguments inlined anywhere).
- Jaccard reasoning similarity + shift threshold + breakpoint machinery —
  recomputed three full traversals (`timeline_closure_identity`) to guess
  topic shifts; replaced by the single-traversal freshness identity.
- Recovery classification and redundant output-size accounting — derived
  labels computed then discarded before return.
- Per-chat-restarting event indices — cross-chat bursts carried meaningless
  numbers (`timeline_build_segments` old 426/462/619); every reference is now
  chat path + that chat's own indices. Pinned by
  `test_timeline_cross_chat_indices_do_not_restart`.
- Unguarded `Time.parse` — an unparseable timestamp aborted the whole report;
  now nil-safe (`timeline_parse_time`), pinned by the malformed-timestamp test.
- `/`-dropping `timeline_public_identifier` — destroyed qualified delegation
  selectors like `Worker/ScoutCoder`; qualified selectors now preserved.
- `tool_call_identity` MD5 over `[tool, call_id, arguments]` — collapsed two
  independent identical calls when call ids were missing; dedup now requires
  identity evidence (pinned: two identical calls without call ids stay two
  records).

## Root-token three-way reconciliation (re-established by execution)

Re-run in Phase C over the fixture families the rev3 report used (receipts
built through `LLM.meta_receipt_from_messages`, so fixture receipts match
production by construction; probe receipt
`share/probes/phasec_token_figures.rb`, fresh child process):

- `fixture_receipt_only` (two delegated receipts, no child chat anywhere):
  `deduplicated_total tt=182` = receipt-only delegated 180 + the root's own
  meta inference 2; `receipt_only tt=180`, `chat_evidence tt=2` (root only),
  `receipt_evidence tt=180`.
- `fixture_receipt_plus_log` (the same two delegated events in receipts AND a
  saved worker log, plus one log-only event w3 and the root's own meta):
  `deduplicated tt=290` (100+30 receipts + 160 saved-log events incl. the
  log-only w3, double-count collapsed), `receipt_only 0`;
  `chat_evidence 290`, `receipt_evidence 180` — the two scopes OVERLAP (they
  are coverage descriptions, never a partition).
- `fixture_agent_job` (receipt `job=` reference into a real job tree, job has
  one dependency): `deduplicated tt=182` via the compact graph's job
  traversal, `receipt_evidence 0` (the job reference resolves, so the events
  count as chat evidence from the job's log, not as receipt-only).

Re-established by `test/test_chat_analyst_stage6.rb` and
`test/test_cross_consumer_tokens.rb` (see receipts below), not quoted from
the earlier report.

## Test results (receipts)

All commands from the checkout root with
`ruby -I/home/mvazque2/git/scout-ai/lib -Itest test/<file>.rb` (gem trap: the
installed scout-ai 2.0.0 gem predates `provenance_graph`; the canary test
asserts `Chat.respond_to?(:provenance_graph)`).

Phase C full tree (`tmp/redesign/phase-c-full-suite.log`, sequential —
suites share one fixed absolute `@__test_dir`):

| suite | tests | assertions |
|---|---|---|
| test_chat_analyst_stage6.rb | 7 | 33 |
| test_chat_analyst_api.rb | 25 | 157 |
| test_chat_analyst_timeline.rb | 15 | 77 |
| test_chat_analyst_tool_calls.rb | 12 | 39 |
| test_chat_analyst_tasks.rb | 12 | 30 |
| test_agent_meta_tasks.rb | 10 | 38 |
| test_cross_consumer_tokens.rb | 3 | 25 |
| test_extract_chat_range.rb | 6 | 13 |
| test_inbox_tasks.rb | 26 | 108 |
| test_job_reference_fallback.rb | 5 | 12 |
| test_job_root_own_chats.rb | 2 | 9 |
| test_message_sizes_and_call_filters.rb | 7 | 36 |
| test_pagination_and_copies.rb | 4 | 33 |
| test_provenance_relationships.rb | 6 | 28 |
| test_unresolved_jobs_nil.rb | 3 | 11 |
| **total** | **143** | **649** |

0 failures, 0 errors. Phase A/B totals and logs: `phase-a-full-suite.log`
(114/600), `phase-b-full-suite.log` (130/618). Task-family smoke through the
real Scout job machinery: `test/test_chat_analyst_tasks.rb` runs each exported
task; fresh-process probes `share/probes/phasec_task_smoke*.rb`.

## Unverified compatibility and standing limitations

- **Cross-repo consumers outside ChatAnalyst + scout-ai are unverified**: the
  sweep could see only the AgentSuite tree and the scout-ai checkout (the
  search stage's sandbox saw only those two). The four legacy adapters cover
  the only consumers found; if another repo used a retired task name, it will
  now get `TaskNotFound`.
- **Git in the checkout is broken** (dead `.git` module link): no SHAs, no
  commits possible (none made). All change provenance is snapshot-based:
  `var/baselines/pre-refactor/`, `var/baselines/phase-b-removed/`,
  `var/baselines/phase-c-removed/` — each now carries a SHA256SUMS
  (phase-b-removed's was added post-gate, following the Critic F2 finding).
- **Phase A transient anomaly**: one mid-Phase-A full-suite run showed
  non-reproducing failures in `test_extract_chat_range.rb` /
  `test_inbox_tasks.rb`; three subsequent clean reruns and every later
  full-tree run (Phase B ×2, Phase C ×2) stayed green. Suspected cause: the
  shared fixed `@__test_dir` under concurrent runs; suites are now always run
  sequentially. Not root-caused; flagged for Critic attention.
- Overview/timeline parse each chat twice per call (own parse + graph parse);
  measured trivial on fixture trees (whole Phase C tree ≈ 30 s). Tokens calls
  one traversal per scope by core design.
- `timeline` cache is in-process only; a fresh process always recomputes.

## Phase C deviations (recorded in `tmp/redesign/phase-c-notes.md`)

1. `Chat.provenance_token_totals` runs its own traversal per call and raises
   on unresolved `job=` references by default — `tokens` now passes each call
   a `warnings: []` buffer (N1 ghost-job defect found and fixed this phase).
2. `chat_timeline` module result reports `summary[:chats]` (count), not a
   top-level array.
3. Legacy pagination envelope keys (`messages`/`items`) differ per adapter to
   preserve consumer shapes.
4. Test-unit here lacks `assert_raise(Class, Regexp)`; tests use
   `assert_raise` + `assert_match`.
5. `TaskNotFound` is a top-level constant in this checkout.

## Critic-gate readiness

Ready for step 9: green full tree (143/649), receipts above, sweep table,
per-phase notes, baselines with checksums, deviation list, and this report.
Deliberately left for the gate to check: the Phase A transient anomaly
(non-reproducing), the unverified out-of-repo consumer surface, and
performance at production session scale (fixtures are small by design).
