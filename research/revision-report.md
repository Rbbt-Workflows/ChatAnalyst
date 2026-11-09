# Revision report — minimal revision on the compact-provenance refactor

Final deliverable of plan step 9. This is the authoritative record of the
reviewer's minimal revision (6 items + supporting fixes) applied on top of
the compact-provenance refactor documented in `research/redesign-report.md`.
Companion records: `research/stage0-notes.md` (problem framing),
`research/performance-notes.md` (step-7 measurements, referenced not
restated here).

Provenance note: git is broken in this checkout, so this report is part of
the snapshot-based provenance record alongside the two reports above;
baseline snapshots and SHA256SUMS live under `var/baselines/`.

## 1. Scope and principle

The reviewer's minimal revision covered six items plus supporting fixes,
executed in two phases (phase 1: fixes and restructurings;
phase 2: retirements, attribution, raw mode, canonical paths) plus one
measurement-only bout. Everything is implemented and Critic-verified;
nothing in this report is proposed work.

**Governing principle:** indexes identify evidence and indicate its size;
detail operations retrieve the evidence itself. Concretely: compact index
responses (overview, timeline, tool_calls) carry counts, sizes and
addresses, never payloads; payload retrieval goes through the detail
operations (chat_range, chat_tool_call) that load only the addressed
object.

**Deferred by the review and NOT done** (explicitly out of scope):

- overview/timeline pagination beyond what `chat_messages` already provides;
- a `chat_token_events` task;
- a `chat_delegation` task;
- scout-ai core changes (single-pass token totals, digest caching) — those
  are scout-ai-repo follow-up decisions, recorded in
  `research/performance-notes.md` §§3.4–3.5, not this project's scope.

## 2. Claim-by-claim disposition (17 rows)

Statuses: **held-and-fixed** (claim was real, behavior fixed), **held-but-dead-code**
(defect existed in source but no live caller), **held-framing-corrected**
(claim held only after correction of its framing), **rejected** (claim did
not hold as stated). No claim was rejected outright; rows 9 and 16 are the
framing corrections.

Claims were verified by the search stage (`research/chatanalyst-provenance-search-brief.md`
and the review) and re-confirmed during implementation; each row cites the
fix location or receipt.

| # | Claim | Status | Disposition and evidence |
|---|---|---|---|
| 1 | Selected-burst duplication in timeline (`result[:bouts]` left alongside inlined selection) | held-and-fixed | Selection mode now deletes `:bouts` and adds `bouts_total` (`lib/ChatAnalyst/api.rb:291`); both pinned in `test/test_chat_analyst_timeline.rb:88-89`. |
| 2 | `message_index` per-message chat reload + unused `position` var | held (moot after retirement) | The adapter task was retired in phase 2; its capability carried to `chat_messages` (role filter, page/per_page pagination, large flag — `lib/ChatAnalyst/tasks/api_tasks.rb:31-36`). The reload defect is moot after retirement; the `ChatAnalyst.message_index` Ruby API remains, used by `chat_messages`. |
| 3 | `chat_tool_calls` helper re-running `Chat.agent_meta_evidence` per call | held-but-dead-code | No task called the helper after the earlier refactor; dead helpers deleted with grep evidence (`tmp/rev-phase1/dead-helper-grep-evidence.txt`, 23 names checked, 2026-11-08T11:54:42+01:00). |
| 4 | `chat_accounting` calling tokens/overview/relationships repeatedly per chat (incl. per closure event count) | held-and-fixed | Single-pass per chat with spy-evidence tests (`test/test_chat_accounting_single_pass.rb`); Critic independently confirmed 1 call per chat per API (probe `tmp/critic-revision/singlepass.rb`). |
| 5 | `chat_report` large composite | held | Attribution promoted to public `ChatAnalyst.attribution` (`lib/ChatAnalyst/api.rb`) + `chat_tokens` `attribution` view (task input at `api_tasks.rb:160`, view at `:162`); `chat_report` retired (snapshot `var/baselines/rev-phase2-removed/chat_report.rb`). |
| 6 | `chat_tokens` repeating scopes/conflicts/warnings on every event page | held-and-fixed | Event pages carry events + paging metadata + root only; the unpaginated shape keeps flat totals; cross-consumer agreement pinned green in `test/test_cross_consumer_tokens.rb`. |
| 7 | No detail operation for one tool call | held-and-fixed | `ChatAnalyst.tool_call` + `chat_tool_call {file, call_index}` added. No `chat_message` task was added: a single message is `chat_range` with `first == last`, by design. |
| 8 | `argument_characters` missing from compact call index | held-and-fixed | Raw persisted string length, else canonical JSON length; field present in both the compact index and the `chat_tool_calls` typed records (`api_tasks.rb:120`). |
| 9 | Overview returning graph maps unnormalized | held-as-inconsistency (framing corrected) | Core currently yields plain strings via `provenance_path`, so this was hardening, not an active leak. Recursive normalization added (`normalize_reference_map` / `normalize_delegation_map` / `canonical_plain_path`, `api.rb:736-757`) and pinned in `test/test_canonical_paths.rb` (module header asserts no Chat/Step/Path instance in any public result). |
| 10 | `File.expand_path` vs realpath canonicalization divergence (real on this machine) | held-and-fixed | `Chat.provenance_path` routing centralized in `canonical_chat_path` (`api.rb:780-782`) and applied across range/relationships/tool_calls/tool_call. Alias pin via deterministic symlink fixture (`test/test_canonical_paths.rb:41+`). Note: /home vs /bulk are different device trees on this machine, not a generic alias — documented in the test header. |
| 11 | `unloaded_references` lacking kind/origin | held-and-fixed | Entries are now `{kind, path, error, via: {from_kind, from_path, context}}` on overview and timeline (`api.rb:92-93, 128, 143, 146`). KNOWN LIMITATION (Critic, probe `tmp/critic-revision/unloaded_ghost.rb`): a ghost job reference (nonexistent path) produces no `unloaded_references` entry — only nodes that exist but fail to load are reported. |
| 12 | Token accounting ~6 traversals | held-and-measured | Exactly 6 core traversals per `tokens` call (events + 4 scope totals + conflicts), instrumented in `tmp/rev-measure/logs/tokens_*.log`; ~13 ms/chat linear growth; core-share 98.6% (large, 21 chats) to 99.2% (c50, 51 chats). Recommendation **KEEP** (§3.5 of `research/performance-notes.md`). |
| 13 | Timeline freshness hashing every reachable `.info` on every call incl. cache hits | held-and-measured | 0.4–33 ms across all measured scales; dominates the hit path above ~20 chats (80.9% at 21 chats, 87.9% at 51). Recommendation **KEEP** (correctness-first, §4.5); a stat-only pre-check is named as an available local lever and deliberately not pulled. |
| 14 | No pagination on `chat_messages`, no cap on `chat_range` | held-and-fixed | `chat_messages` gained `page`/`per_page`/`role` (`api_tasks.rb:32-34`); `MAX_RANGE_MESSAGES = 200` at the task layer only (`workflow.rb:24`, enforced `api_tasks.rb:61`); Ruby API uncapped; `first == last` valid. |
| 15 | `message_content` cross-chat batch (not drop-in for one range call) | held (retired) | Retired with the adapter migration; the batch convenience is deliberately dropped — the migrated agent issues one `chat_range` per chat. |
| 16 | `extract_chat_range` duplicates `chat_range` | held (framing corrected) | Its `:chat`-typed raw output was NOT covered by `chat_range`'s JSON shape. Resolved via `raw` mode: byte-exact `Chat.print` of the persisted slice inside the JSON envelope. 6 pins ported to `test/test_chat_range_raw.rb`; adapter retired (snapshot `var/baselines/rev-phase2-removed/extract_chat_range.rb`). |
| 17 | `chat_tool_calls` needs redesign | held | Composition already existed from the prior refactor; output restructured to typed records `{chat, call_index, output_index?, tool, call_id?, status, delegated, delegation_target?, jobs, argument_characters, output_characters, copy_of?}` — no `path#index` strings (`api_tasks.rb:107-121`); relocated to `lib/ChatAnalyst/tasks/api_tasks.rb`; filters/pagination/dedupe preserved; ported suites green. |

## 3. Decisions D1–D5 (settled at plan stage, executed as decided)

- **D1 — raw mode on `chat_range`** (chosen over keeping the adapter):
  `raw: true` adds the byte-exact persisted slice as a `raw` string field
  alongside `messages`; the task-type machinery was not contorted into an
  input-dependent `:chat` output. Single-message retrieval remains
  `first == last`; no separate `chat_message` task.
- **D2 — attribution as public method + `chat_tokens` view** (task count
  flat at 11): `ChatAnalyst.attribution(root, tokens_report: nil)`;
  `chat_tokens` passes its already-fetched tokens report in, so
  summary+view costs exactly one summary fetch + one view fetch.
- **D3 — default-mode timeline keeps compact bouts**: bouts are the failure
  locator; pagination only if measurements justify it — the step-7
  measurements did not (freshness costs 0.4–33 ms, KEEP).
- **D4 — `chat_accounting` KEPT on its own merits** (import-closure
  accounting not provided by tokens) with its efficiency fixed (claim 4:
  single-pass per chat).
- **D5 — `live_chats` / `inbox_state` / `post_inbox_advice` unchanged.**

## 4. Deliberate losses (from retirement)

Accepted capability losses, each with its replacement path:

- `message_content` cross-chat batch fetch — replaced by one `chat_range`
  call per chat.
- `chat_report` session-level dedup count + first-10 failure list — the
  same raw counts exist on `chat_tool_calls`; failure detail via
  `chat_tool_call` + `chat_range` `first == last`.
- `extract_chat_range` `:chat`-typed job output — replaced by the `raw`
  JSON string field inside `chat_range`'s envelope.
- `start`/`end` input spellings unified to `first`/`last`.

## 5. Deviations (all recorded during the bouts)

- **Exception class on `chat_range` source validation** is `ArgumentError`
  from the Ruby API (the retired adapter raised `ParameterException`).
  Cap enforcement and job-root rejection remain `ParameterException`.
  Recorded in `tmp/rev-phase2/branch-consumption.md` and pinned in
  `test/test_chat_range_raw.rb`.
- **Selection mode adds `bouts_total`** — justified: it preserves the
  full-bout count the deleted `:bouts` array carried.
- **`DELEGATION_TOOLS` workflow constant deleted**; the list lives once in
  `lib/ChatAnalyst/api.rb` as `DELEGATION_TOOL_NAMES` (api.rb:60, used at
  :1268 and :1279).
- **`sum_events` kept** with corrected phrasing — 3 call sites + 1
  definition (`api.rb:647, 649, 651, 829`), all inside attribution. This
  is Critic's correction of the earlier "4 callers" wording.
- **Measurement caveats** (`research/performance-notes.md` §5): the
  phase-breakdown probe mirrors the call shape and its absolute totals are
  an upper bound (~1.8×); shared host gives ±10% run-to-run variation;
  conclusions are scale-limited to ≤51 chats (synthetic fixtures, the only
  real trees available were ≤6 chats).
- **Alias test fixture uses deterministic symlinks** — the /home-vs-/bulk
  spelling is a machine-specific two-device-tree finding, not a generic
  alias; the invariant under test (one canonical spelling across surfaces)
  is unchanged (`test/test_canonical_paths.rb` header).

## 6. Final task surface

11 tasks, all `:json`:

- `chat_overview`, `chat_timeline`, `chat_messages`, `chat_range`
  (raw mode, cap 200), `chat_tokens` (attribution view),
  `chat_tool_calls`, `chat_tool_call` — declared in
  `lib/ChatAnalyst/tasks/api_tasks.rb` (7).
- `chat_accounting`, `live_chats`, `inbox_state`, `post_inbox_advice` —
  declared in `workflow.rb` (4).

Four retired adapters fail fast with Scout's TaskNotFound:
`message_index`, `message_content`, `extract_chat_range`, `chat_report`.
Snapshots live in `var/baselines/rev-phase2-removed/` (SHA256SUMS verified
by Critic; re-verified OK from the repo root while writing this report).
`start_chat` documents only implemented tasks and routes the agent to the
retrieval ladder (index → detail → raw).

## 7. Test evidence

All numbers quoted from executed runs; suites always sequential, load path
`/home/mvazque2/git/scout-ai/lib` (installed gem predates the provenance
APIs):

| checkpoint | tests | assertions | failures | errors | receipt |
|---|---|---|---|---|---|
| baseline before revision | 143 | 649 | 0 | 0 | `research/redesign-report.md` (total table, line 158) |
| phase 1 final | 152 | 717 | 0 | 0 | `tmp/rev-phase1/final-confirm.log` |
| final (22 suites) | 174 | 821 | 0 | 0 | `tmp/rev-phase2/final-confirm.log` |
| Critic independent rerun | 174 | 821 | 0 | 0 | `tmp/critic-revision/full-rerun.log` |

## 8. Critic gate — plan step 9 verdict PASS

Receipts under `tmp/critic-revision/`: full-tree rerun (`full-rerun.log`,
identical 174/821), flagship failed-call chain — timeline → `tool_call` →
range with actual persisted output, byte-exact raw mode, cap boundary
200/205 (`flagship.rb/.out/.err`, `flagship2.rb`), two-mode timeline probe
(`twomode.rb/.out`), fresh-process TaskNotFound dispatch (retired-adapters
pins run in the full rerun), `sha256sum -c` all OK (re-verified during this
report), docs-vs-code check, measurement arithmetic recomputed, honesty
sweep (no TODO/FIXME).

Scope limitations carried forward:

- git is dead, so "unchanged" for the live/inbox tasks rests on green
  suites + producer statement, not a byte diff;
- runtime checks ran in the Critic sandbox through task adapters, not from
  the agent-facing chat context.

## 9. Receipts index

- `tmp/rev-phase1/` — phase 1 probes, dead-helper grep evidence,
  `final-confirm.log` (152/717).
- `tmp/rev-phase2/` — phase 2 probes, `branch-consumption.md`,
  `COMPLETION.md`, `final-confirm.log` (174/821, 22 suites).
- `tmp/rev-measure/` — 7 probes, fixtures (`fixtures/`, `scale/`),
  18 logs (`logs/`), backing `research/performance-notes.md`.
- `tmp/critic-revision/` — Critic gate receipts (§8).
- `var/baselines/rev-phase1-final/`, `var/baselines/rev-phase2-removed/` —
  snapshot trees with SHA256SUMS.
- `research/performance-notes.md` — step-7 measurements (referenced).
