# ChatAnalyst phase 3 report - the TSV task surface (closing report)

Checkout: /bulk/mvazque2/git/AgentSuite/ChatAnalyst (/home/... same tree).
Load path throughout: /home/mvazque2/git/scout-ai/lib. Date: 2026-11-10.
This is the phase-3 closing report the Critic gate reads. Bout records:
tmp/phase3-b2..b7 (per-bout detail, consumed/delivered sha256s, probes).

## a. Scope recap

Phase 3 converts the entire exported task surface from JSON envelopes to
Scout TSV tables built on a shared base layer, under one governing
principle: **indexes identify evidence; detail tasks retrieve it.** An
analyst starts at a compact overview, narrows through indexes that carry
only identifiers, counts and controlled enumerations, and retrieves message
bodies byte-exactly at the leaves. Only paths and zero-based integer
indices pass between tasks; no digests are memorized and no synthetic ids
exist.

Relation to earlier phases: phase 1 (redesign, `research/redesign-report.md`)
rebuilt the Ruby API over scout-ai's compact provenance graph and removed
the heuristics; phase 2 (minimal revision, `research/revision-report.md`)
retired the four Phase C legacy adapters and pinned their coverage ports.
Phase 3 keeps that API unchanged in semantics (additive methods only) and
re-serializes the task layer over it. The phase-2 performance KEEP
decisions (`research/performance-notes.md`) stand and were NOT re-litigated:
no phase-3 measurement contradicted them.

## b. The frozen contract and its evolution

Contract: `research/phase3-contract.md`, final sha
f10543004880ff0986ee49324935ea2c5fe1df6b2ec7d3f2de89b5e710b1f17c.
Freeze baseline (the state against which deviations compare):
0c6e2f4b28fef2e6479b351dbb03134c7ef0189a7c4f818b22d338bdb4643c1b.

Amendments after the freeze, each logged in its bout record:

- **C1 (bout 3, section 1h)** - missing-timestamp policy rewritten to the
  user-approved spec: ONLY timestamped inferences cluster; an undated
  inference joins no cluster, never bridges distant clusters, influences
  no gap computation; `unclustered` is a real possibly-nonzero count. The
  frozen text's "never splits a cluster" phrasing is gone.
- **C2 (bout 3, section 2B)** - chat_inferences made ROOT-scoped
  (tree-wide), with the optional `chat` narrowing filter; the compact
  default temporal entry point remains chat_activity_clusters.
- **C3 (bout 3, sections 2C/3/5)** - the cluster index KEEPS
  tool_call_count and delegation_count (free once clustering operates on
  inference records that carry them); no redundant chat_count is added.
- **AMENDMENT 1 (bout 4, section 2A)** - chat_references target_kind
  enumeration gains `agent` (delegation rows carry the RAW
  `agent#conversation` target, which is neither a job nor a chat).
- **AMENDMENT 2 (bout 4, sections 1f/2B)** - `:chat` addressing: a
  `task => :chat` output persists the bare chat text with NO `#:` line and
  no sidecar, so chat_range/chat_message addressing (file, first, last)
  lives in the PERSISTED JOB INPUTS (step.info), probe-pinned
  (share/probes/b4_probe_chat_output.rb). The 1f first/last annotations
  are marked SUPERSEDED (kept registered).

The fixture-inverted ownership rule, told honestly: the work order's draft
rule for the inference model said "a call belongs to the inference whose
meta FOLLOWS it." Fixture verification (three real chats; decisive probes
b3_pin_layout_consolidated, b3_pin_ownership_decisive,
b3_pin_assistant_rule_final) inverted it: scout-ai UNSHIFTS each inference
meta BEFORE the response segment it accounts for, so the pinned rule is
**a call belongs to the LAST meta BEFORE it (its EMITTER)**; an opening
call with no preceding meta is unassociated and NO synthetic inference is
ever created. Implemented as verified, deviation recorded in the bout-3
record.

Settled decisions (contract section 3): null convention (`\N` sentinel in
String columns, `""` = empty, cast numeric tables native empty=>nil);
booleans as `true`/`false` strings (no `:to_b` exists in the loaded
stack); timestamps UTC iso8601(3) normalize-or-NULL; CR escape included
(`%0D`); summary counts split by natural derivation (chat_overview
annotations chats/jobs/delegations; cluster annotations
clusters/inferences/unclustered); the recursive closure as a SEPARATE task
(job_dependencies_recursive) rather than option-driven output switching;
metadata through the TSV.annotation DSL registered once at library load.

## c. Task surface delivered

Exactly 25 exported tasks (workflow.rb export_exec; scripted docs-vs-surface
check GREEN, tmp/phase3-b7/docs-vs-surface.txt):

- A (overview/relationships): chat_overview, job_overview, chat_references,
  job_dependencies, job_dependencies_recursive, chat_role_counts.
- B (messages/inferences): chat_messages, chat_message (:chat), chat_range
  (:chat), chat_inferences.
- C (clusters): chat_activity_clusters, chat_activity_cluster.
- D (tool calls): chat_tool_call, chat_tool_calls, chat_tool_call_jobs.
- E (tokens): chat_tokens, chat_token_events, chat_token_evidence,
  chat_attribution, chat_accounting.
- F (operational): live_chats, chat_live_report, inbox_state, inbox_note
  (:text), post_inbox_advice.

Output kinds: `:tsv` for 22 tasks; `:chat` for chat_message and chat_range;
`:text` for inbox_note. Zero JSON tasks remain (grep receipt below).

chat_timeline was RETIRED (the only vanishing name; TaskNotFound pin in
test_phase3_temporal_tasks.rb). Its temporal-grouping role moved to
chat_activity_clusters + chat_activity_cluster (two-mode selection) and
chat_inferences (drill-down), all over the new
ChatAnalyst.inferences/activity_clusters model.

Behavior-change pins (all test-pinned, documented in README):

| change | pin |
|---|---|
| chat_tool_call metadata-only (arguments/output bodies absent; sizes + output_message_id replace them) | test_chat_tool_call_pin_bodies_absent; bodies via chat_range on the call/output message ids |
| chat_range raw-input retirement (the byte-exact persisted slice is THE output) | test_chat_range_chat_output_byte_exactness_and_cap; retired-raw-input pin in test_chat_range_raw.rb |
| inbox_state index-only (note bodies never embedded) | test_inbox_state_is_an_index_without_bodies |
| chat_tokens attribution-input retirement (attribution moved to chat_attribution) | test_chat_tokens_retired_inputs_are_absent |
| live_chats job-root status-block drop; escaped ABSOLUTE keys (old JSON used ~/-shortened) | test_live_chats_orders_newest_first_and_flags_active; canonical-path assertions |
| post_inbox_advice static delivery-prose drop | post result fields exactly [name, save_file, inbox_dir, size] |

## d. Deviations and simplifications (consolidated from bout records 2-7)

| item | source | record |
|---|---|---|
| Ownership rule INVERTED from the order's draft (meta PRECEDES its calls) | b3 | tmp/phase3-b3/bout3-record.md (fixture evidence, probes b3_pin_*) |
| assistant = the meta's immediate successor when 'assistant' (reas lives on the META, not on assistant messages) | b3 | same |
| reasoning_characters = whitespace-normalized meta reas length | b3 | same |
| job_dependencies_recursive seeding settled: root-owned jobs only (seeding every overview job flattens the closure to all-depth-1) | b4 | tmp/phase3-b4/bout4-record.md |
| chat_messages total = raw message count of the chat (filter narrows rows only) | b4 | same |
| :chat addressing resolved to persisted job inputs (amendment 2) | b4 | same |
| chat_tool_calls JSON summary block NOT carried (only total registered; by_tool etc. derivable from rows) | b5 | tmp/phase3-b5/bout5-record.md |
| chat_token_evidence chat_meta rows: call_id/tool_name \N BY CONSTRUCTION (the core hard-codes nil) | b5 | same |
| chat_attribution linked/unresolved job lists NOT cells (stay on overview/job surfaces) | b5 | same (contract-recorded) |
| export_exec extended in b5 for the four new token-family names (wiring, logged with rationale) | b5 | same |
| live_chats status-block drop; escaped absolute keys | b6 | tmp/phase3-b6/BOUT-RECORD.md |
| post_inbox_advice prose drop | b6 | same |
| chat_live_report missing-root: module-layer ArgumentError pinned as the real contract (order asked for task-layer ParameterException) | b6 | same |
| operational declarations kept INLINE in workflow.rb (no helper fragmentation) | b6 | same |
| chat_timeline.rb SHA256SUMS entry had a transposed hash from b4; corrected in b6, 12/12 verify | b6 | same |
| job_overview result_chat carries \N unless the job's Step type is 'chat' AND the result file exists | b4 | same |
| DEFECT found and fixed in b7 (rehearsal chain 3): job_dependencies_recursive CHAT-root seeding called Array(hash).values, raising NoMethodError for EVERY chat root; existing tests only used job roots. Fixed to references.values; regression-pinned by test_job_dependencies_recursive_chat_root_seeding | b7 | tmp/phase3-b7/BOUT-RECORD.md |

## e. Port/coverage table (suites moved from JSON assertions to TSV)

| suite | move |
|---|---|
| test_phase3_temporal_tasks.rb (NEW b4) | all A/B/C task tables: keys, FKs, pagination, filters, no-payload scans; chat_timeline TaskNotFound pin |
| test_phase3_tool_token_tasks.rb (NEW b5) | D/E task tables incl. metadata-only pins, TokenEvent key grammar, single-fetch spies |
| test_phase3_base_layer.rb (NEW b2) | ids/tsv_base grammar round-trips, encoder pins, annotation survival, scratch-task persistence |
| test_chat_analyst_inferences.rb (NEW b3) | the model pins (span, EMITTER ownership, clustering, cache isolation) |
| test_chat_live_report.rb (NEW b6) | the four live entry kinds on real fixtures |
| test_chat_tool_call_and_bounds.rb | detail record -> metadata-only row; chain step 2 asserts sizes + output_message_id |
| test_message_sizes_and_call_filters.rb | envelope fields -> row cells; filters narrow rows only |
| test_pagination_and_copies.rb | pagination envelope keys -> annotations; dedupe marks copies, never drops rows |
| test_agent_meta_tasks.rb | tokens/attribution envelopes -> chat_tokens rows + chat_attribution bucket agreement |
| test_cross_consumer_tokens.rb | task-level envelope assertions -> chat_tokens/chat_token_events agreement with the Ruby API |
| test_attribution.rb | task envelope -> chat_attribution row agreement with the Ruby view |
| test_message_index_ported.rb, test_chat_range_raw.rb, test_chat_analyst_tasks.rb, test_provenance_relationships.rb | ported where they asserted JSON shapes |
| test_inbox_tasks.rb, test_chat_accounting_single_pass.rb | operational ports (b6); single-pass spy intact; \|-invariant pinned on real delegated_subtrees/imports |

Phase-1/2 coverage retained or ported: the phase-2 pins for the retired
adapters (message_index/message_content/extract_chat_range TaskNotFound in
test_chat_analyst_tasks.rb, extract_chat_range in
test_retired_adapters.rb, chat_report in test_pagination_and_copies.rb)
still pass unchanged; the phase-2 behavior ports (raw slice, range
validation, attribution rollup) were re-asserted against the TSV/:chat
outputs in the ported suites. TaskNotFound pins confirmed re-run green in
the final full-tree receipt: chat_timeline (temporal suite),
message_index/message_content/chat_report (tasks suite), extract_chat_range
(retired-adapters suite), chat_agents (pagination + unresolved suites).

## f. Measurements

Real-tree receipts (the 6.59 MB / 3128-message ScoutCoder agent chat,
1035 function_call messages, 1034 timestamped inference metas):

- chat_tool_calls page 1 / per_page 50: 2.24 s, 50 rows, total 1035,
  21 pages, 30,803 bytes (tmp/phase3-b5/realtree-run.txt).
- chat_tool_call detail: 1.559 s, 1 row, 991 bytes.
- chat_activity_clusters: 3.4 s, 34 rows, 13,214 bytes; annotations
  clusters=34 inferences=1034 unclustered=0.
- chat_inferences page 1 (per_page 20): 0.82 s, 20 rows, 17,005 bytes;
  total=1034, 52 pages.
- chat_tokens on the child chat: 6.5 s; chat_attribution: 7.3 s (the
  underlying tokens traversal dominates; consistent with the phase-2
  performance envelope).

The `|`-invariant on multi-value cells is enforced at encode time
(TSVBase.multi) and pinned on REAL values
(test_pipe_invariant_pinned_on_real_delegated_subtrees_and_imports).

Test-count trajectory (full tree, sequential, fresh process per suite):
174/821 (22 suites, pre-phase-3) -> 191/985 (24) -> 202/1067 (25) ->
226/1571 (25) -> 248/2243 (27) -> 255/2314 (28, bout 6) -> 256/2317
(28, bout 7 final; +1 test/+3 assertions from the chat-root seeding
regression test the rehearsal itself motivated, on
test_job_dependencies_recursive - see below). Receipt
tmp/phase3-b7/full-tree-run.log.

## g. Rehearsal results (plan step 12; receipts tmp/phase3-b7/rehearsal/)

All five chains ran on REAL fixtures; every step passed only paths and
integer indices between tasks.

**Chain 1 - failed tool call** (root: the 3128-message ScoutCoder
agent.chat). chat_overview (1 chat, 3128 msgs, 0.77 s) ->
chat_activity_clusters (34 rows == clusters annotation; NO member-list
column - compactness asserted; 3.37 s) -> chat_inferences pages 1-2 (50
rows/page, total 1034; 0.80 s each) -> chat_tool_calls success=false (31
rows of 1035, filters annotation success=false; 2.20 s) -> chat_tool_call
on call_index 18 (bash, status failure, reason exit_status; 1.53 s) ->
chat_range first==last=18 (617 bytes, starts "\nfunction_call:";
0.41 s) -> chat_range on the output message id (653 bytes, starts
"\nfunction_call_output:"; 0.43 s). Total 10.3 s. Conclusion: a complete
failure investigation on the largest real chat without ever reading the
chat file directly; the call, its arguments and its output are located
through the index and retrieved byte-exactly at the leaves.

**Chain 2 - delegation walk** (root: the Planned Manager.chat). chat_overview
(66 msgs, 5 delegations; 0.37 s) -> chat_references (5 delegation rows;
targets ScoutCoder#chatanalyst-redesign, Critic#default; 0.54 s) ->
job_overview tree root (4 jobs with result chats; 0.36 s) -> job_overview
on the materialized child chat (0 rows: a leaf; 0.75 s) -> chat_tool_calls
child page 1 (50 of 1035; 2.28 s) -> chat_tokens child (4 scope rows;
6.49 s) + chat_attribution child (3 buckets; 7.28 s); AGREEMENT assert:
chat_tokens chat_evidence row == chat_attribution root bucket on the first
six fields (both 123,865,662 pt / 904,957 ct / ...) - TRUE. Total 18.1 s.
Conclusion: a delegation is visible end to end (reference -> child chat ->
child calls -> child tokens), and the summary and attribution surfaces
agree on the same underlying events.

**Chain 3 - dependency closure** (root: the Planned work job). job_overview
(4 jobs: work/plan/search/request, each with its result chat; 0.40 s) ->
job_dependencies (3 declared edges in order; 0.38 s) ->
job_dependencies_recursive (3 rows: plan depth 1 via work, search depth 2
via plan, request depth 3 via search; 0.33 s). The real tree is a chain -
no cycle - so the cycle case rests on its fixture tests
(test_job_dependencies_recursive_chain_diamond_and_cycle, green in the
final run). Seeding is root-owned per contract 2A. Total 1.1 s.
Conclusion: direct and recursive dependency surfaces compose; the closure
adds depth and via_owner without re-deriving ownership. Chain 3 found the
one real defect of the rehearsal: the first run used the work JOB as root
and passed, but seeding the closure from the Manager CHAT root crashed with
NoMethodError (Array(hash).values on the job-references Hash) - the
pre-rehearsal test suite only ever used job roots. The spelling was fixed
in the same bout (references.values.flatten) and the chat-root seeding
path is now regression-pinned
(test_job_dependencies_recursive_chat_root_seeding; the re-run receipt
shows the closure computed from the chat root through the work job's
dependencies). The real chat roots available on this machine carry no job
references (a Manager save file and a society agent chat), so their
post-fix closures are legitimately EMPTY (receipt
tmp/phase3-b7/rehearsal/chain3-chatroot.txt: 0 rows, ~0.6 s each); the
non-empty chat-root closure evidence is the synthetic regression test.

**Chain 4 - compactness probe on the LARGE tree** (same root as chain 1).
chat_activity_clusters 34 rows / 13,214 bytes (3.44 s); chat_inferences
page 1 per_page 20: 20 rows / 17,005 bytes (0.82 s); chat_overview default
1 row / 421 bytes (0.76 s). COMPACTNESS ASSERT: the default temporal entry
point returns cluster counts only - neither overview (1 row) nor clusters
(34 rows) ever returns the 1034 inferences; rows == clusters annotation;
no member lists. TRUE. Total 5.0 s. Conclusion: the default entry points
stay compact at the largest real scale; the ~1034-inference detail is
opt-in through pagination.

**Chain 5 - operational** (root: the Planned Manager.chat; probe
chain5_ops.rb because post_inbox_advice writes the real inbox, read-only
under Workspace bwrap). live_chats (3 settled chats, newest-first,
likely_active on the newest, escaped absolute keys; 0.62 s) ->
inbox_state BEFORE (0 rows: settled tree; 0.02 s) -> post_inbox_advice
(1 posted row, name 20261110-003648-advice.md, size 83; 0.02 s) ->
inbox_state AFTER (documented fresh-result trap: the job replayed the
cached empty table because the side effect does not change the job digest;
the clean:true re-run in the chain5_state_after probe returned the pending
row - recorded as a rehearsal finding, not a defect) -> inbox_note (length
83, BODY MATCH with the posted text - TRUE; 0.02 s) -> chat_live_report
(0 rows: no running inference; 1.34 s). Separation observed: live_chats
(3 settled chat files) vs chat_live_report (0 running entries) answer
different questions. INDEX-ONLY assert: no body field in inbox_state
(TRUE). Cleanup verified (note removed, inbox dir pruned, rows back to 0).
Total ~2.0 s.

## h. Remaining limitations and follow-ups

- **Core improvement ideas** (stage-0 section 6, recorded NOT acted on;
  scout-ai stays unchanged): per-field cast persistence; a native null
  sentinel honored by list/double readers; sep2 symmetry (dump honoring
  the table's sep2 instead of always `|`); TSV.setup(annotations:) raising
  an opaque NameError instead of a clear exception.
- **post_inbox_advice cache replay**: a posting with the same explicit
  name inside one process replays the cached result before the
  no-overwrite guard (behavior unchanged from the JSON era; use distinct
  names or clean the job - surfaced again by rehearsal chain 5).
- **inbox_state after a posting** requires a fresh job (clean:true) in the
  same process - the side effect does not change the job digest
  (rehearsal chain 5; inherent to Scout's jobname/digest model, not a
  ChatAnalyst defect).
- **chat_live_report state vocabulary** is controlled
  (running/waiting/crashed/finished or \N); exception text never rides
  cells, so a crashed entry's cause must be read from the job itself.
- **job_dependencies_recursive fixtures** build .info dependency lists
  directly; no live Step dependency edges were exercised beyond what the
  overview traversal reads (chain 3's real tree is a chain; cycle safety
  is fixture-tested).
- **Gem trap** (standing): the installed scout-ai 2.0.0 gem predates the
  provenance APIs; every run needs the checkout load path (test_helper
  canary asserts it).
- **No git**: provenance for the phase work is snapshot-based
  (var/baselines/ + SHA256SUMS + bout records).

## i. Provenance

Consumed/delivered sha256 per bout live in the bout records
(tmp/phase3-b2/consumed.sha256 + delivered.sha256,
tmp/phase3-b3/..., tmp/phase3-b4/consumed.sha256 + delivered.sha256,
tmp/phase3-b5/..., tmp/phase3-b6/consumed-sha256.txt, and this bout's
tmp/phase3-b7/consumed-sha256.txt + delivered-sha256.txt). Key anchors:

- contract freeze 0c6e2f4b...; final f1054300... (amendments logged).
- api_tasks.rb trajectory: 918ce0a3 (b3) -> 1ec752a5 (b4) -> 771a4256
  (b5, unchanged through b6; current, code untouched in b7).
- workflow.rb: 7e18d581 -> c369b07d (b4) -> 30a60e0c (b5) -> d0105548
  (b6, current; code untouched in b7).
- Base layer ids.rb 11778a3d / tsv_base.rb 4855f3d3 / inferences.rb
  bb1a09e6 / api.rb 2c49e1d1 - unchanged since bout 3.
- Baselines: var/baselines/phase3-removed/ (12 files + README +
  SHA256SUMS; sha256sum -c verifies 12/12 OK, receipt in this bout).
- Docs delivered this bout (b7): README.md and start_chat rewritten to the
  25-task surface; docs-vs-surface scripted check GREEN
  (tmp/phase3-b7/docs-vs-surface.txt); phase3-report.md (this file).

## Final verification receipts (bout 7)

- Full tree sequential: tmp/phase3-b7/full-tree-run.log - 28 suites, 255
  tests, 2314 assertions, 0 failures, 0 errors (code untouched; identical
  counts to bout 6, as expected for a docs-only bout).
- Zero-JSON grep: `grep -rn "=> :json" lib/ workflow.rb share/` - no
  matches (receipt in run log).
- Baselines: `sha256sum -c` in var/baselines/phase3-removed/ - 12/12 OK.
- Docs-vs-surface: tmp/phase3-b7/docs-vs-surface.txt - GREEN (25/25 in
  both docs; no phantom names; two whitelisted non-task identifiers
  `live_report`/`chat_task` are core-API/cell-field mentions).
- Rehearsal chains 1-5 receipts: tmp/phase3-b7/rehearsal/chain{1..5}.txt
  (+ chain5 probe receipts), each recording inputs, wall time, output
  size, assertions and conclusions.
