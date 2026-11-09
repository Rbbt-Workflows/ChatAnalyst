# Stage 0 notes — consumer sweep, follow decision, git, provenance citations, currency

Bout 1 of 6 (plan step 1). Discovery only; no code edits. All paths verified from the
execution surface available to this agent (bash/bwrap sees `/bulk/mvazque2/...`; the
`/home/mvazque2/git/...` spelling is a harness-level alias — `realpath` of the target
checkout from bash resolves to `/bulk/mvazque2/git/AgentSuite/ChatAnalyst`, inode
2081:174330917).

## 1. Consumer sweep

Sweep surface: `/bulk/mvazque2/git/AgentSuite` (contains exactly ONE repo:
`ChatAnalyst`) and `/home/mvazque2/git/scout-ai` (lib, scout_commands, workflow.rb),
excluding `.git`, `var/jobs`, `tmp`, `.save`, `.crap`.

### Structural results

- `ChatAnalyst.job(` calls outside the ChatAnalyst checkout: **none** (sweep A, empty).
- `require`/`load` of ChatAnalyst library files outside the checkout: **none** (sweep B,
  empty).
- Bare task-name matches in scout-ai lib are unrelated same-name core methods, not
  consumers: `Chat#message_index` (`lib/scout/llm/chat/process/meta.rb:246`), 
  `Chat.agent_meta_evidence` / `Chat.meta_evidence`
  (`lib/scout/llm/chat/agent_meta.rb:77,181`), `agent_meta_evidence` references in
  `provenance/tokens.rb:157,160`. No ChatAnalyst task is invoked from scout-ai.
- Runtime job evidence: the only ChatAnalyst task jobs anywhere on this machine are
  8 jobs under `/home/mvazque2/git/scout-ai/var/jobs/ChatAnalyst/` (4 tasks × 1–3 jobs,
  all dated 2026-10-25, all from ONE session — request_context field `caller` points at
  `.../Planned/work/Default_b58e...chat.files/Manager.society/ChatAnalyst/default/agent.chat`).
  `~/.scout/var/jobs/ChatAnalyst` does not exist; the checkout's own `var/jobs` has no
  ChatAnalyst tree. The previously installed agent copy
  `/home/mvazque2/.scout/Agent/ChatAnalyst` (seen in Oct-25 exception backtraces,
  `workflow.rb:134`) no longer exists.

### The one real external consumer: the ChatAnalyst agent itself

Instantiated once, as a society child of a Planned `work` run (Manager delegated via
`ask` agent=ChatAnalyst, Manager.chat line 742). Its tool surface was
`tool: ChatAnalyst` (whole workflow; agent.chat lines 394–396) plus Workspace and
Cortex tools. Tool calls it actually made (agent.chat, name/arguments JSON):
`ruby`×28, `bash`×4, `chat_report`×3, `search`×2, `message_content`×2,
`message_index`×2, `cortex_search`×2, `chat_tool_calls`×1, and one each of
cortex_list/cortex_write/file_stats/list_directory/read/sandbox_paths.
**No call ever passed `follow`** — every task call carried only `file` (plus
`page`/`per_page` on message_index, `ids` on message_content).

### Per-task verdicts (all 16)

External = code outside the ChatAnalyst checkout invoking the task. "Agent (live)" =
the society session above, evidenced by agent.chat tool-call JSON plus persisted job
receipts under `/home/mvazque2/git/scout-ai/var/jobs/ChatAnalyst/<task>/`.

| # | Task | External consumers | Self-references |
|---|------|--------------------|-----------------|
| 1 | `message_index` | Agent (live): 2 calls, args `{file, page:1, per_page:80}` | tests: test_agent_meta_tasks.rb, test_message_sizes_and_call_filters.rb, test_extract_chat_range.rb; README; workflow.rb:552 |
| 2 | `message_content` | Agent (live): 2 calls, args `{file, ids:[...]}` | workflow.rb:616; NO test file invokes it directly (coverage gap) |
| 3 | `extract_chat_range` | none found | workflow.rb:595 + export :1526; test_extract_chat_range.rb |
| 4 | `chat_overview` | none found (not called in the live session) | tests: test_agent_meta_tasks.rb, test_provenance_relationships.rb; workflow.rb:638 |
| 5 | `chat_tool_calls` | Agent (live): 1 call, args `{file}` | tests: test_agent_meta_tasks.rb, test_message_sizes_and_call_filters.rb, test_pagination_and_copies.rb; workflow.rb:704 |
| 6 | `chat_tokens` | none found | tests: test_agent_meta_tasks.rb, test_pagination_and_copies.rb, test_cross_consumer_tokens.rb; workflow.rb:750 |
| 7 | `chat_agents` | none found live; rev2 probe only (one-off, see below) | tests: test_agent_meta_tasks.rb, test_pagination_and_copies.rb, test_unresolved_jobs_nil.rb; workflow.rb:792 |
| 8 | `meta_evidence` | none found live; rev2 probe only | tests: test_agent_meta_tasks.rb; workflow.rb:882 |
| 9 | `chat_reasoning` | none found | tests: test_agent_meta_tasks.rb; workflow.rb:941 |
| 10 | `chat_report` | Agent (live): 3 calls, args `{file}` (1 failed "Chat or job not found" on a job-dir path); rev2 probes | tests: test_job_root_own_chats.rb, test_agent_meta_tasks.rb, test_pagination_and_copies.rb, test_unresolved_jobs_nil.rb; workflow.rb:1011 |
| 11 | `provenance_relationships` | none found | tests: test_provenance_relationships.rb; workflow.rb:1119 |
| 12 | `chat_accounting` | none found live; rev2 runtask probe attempted (0-byte output json, backtrace in .stderr → probe failed) | tests: test_agent_meta_tasks.rb, test_provenance_relationships.rb; workflow.rb:1155 |
| 13 | `chat_timeline` | none found | test/ChatAnalyst/tasks/test_timeline.rb; timeline.rb:751; internal dep on `timeline_index` (timeline.rb:745) |
| — | `timeline_index` (17th, internal) | none (only internal producer) | timeline.rb:674, produced via `ChatAnalyst.job(:timeline_index, ...)` at timeline.rb:745; tested in test_timeline.rb |
| 14 | `live_chats` | none found | tests: test_inbox_tasks.rb; workflow.rb:1376 |
| 15 | `inbox_state` | none found | tests: test_inbox_tasks.rb; workflow.rb:1444 |
| 16 | `post_inbox_advice` | none found | tests: test_inbox_tasks.rb; workflow.rb:1483 |

### WorkflowCoder `tmp/rev2/step2/` probes: live consumers or one-offs?

**One-off probes, not live consumers.** Evidence:
- Header comments are diagnostic narratives ("F3-local repro: run ChatAnalyst analysis
  on the real local Planned session material", probe_planned_f3.rb:1–2;
  "the ONLY route into the WorkflowCoder run_task exec environment from this chat",
  probe_runtask.sh:5).
- `ChatAnalyst.job` calls: probe_planned_f3.rb:44 (`:chat_report`), :50 (`:chat_agents`),
  :58 (`:meta_evidence`); probe_plain_split.rb:27 (`:chat_agents`), :34 (`:chat_report`);
  probe_plain.rb:16 (`:chat_agents`). All pass only `{file}` — never `follow`.
- The run_task receipts `runtask_{chat_report,chat_agents,chat_accounting}_parent.json`
  are all **0 bytes**, and the paired `.stderr` files show an install + backtrace
  ("Installing: ChatAnalyst" then BACKTRACE in scout-gear bin) — the probes' run_task
  leg failed; they document an exec-context defect investigation, not a working
  consumer.
- They live in ChatAnalyst's own `tmp/` scratch (excluded from the sweep by
  definition) and predate the live society session.

## 2. `follow:` input — recommendation: DROP

Facts:
- Declared on exactly 10 tasks (workflow.rb input lines 550, 614, 636, 694, 746, 788,
  880, 939, 1009, 1152 → tasks message_index, message_content, chat_overview,
  chat_tool_calls, chat_tokens, chat_agents, meta_evidence, chat_reasoning,
  chat_report, chat_accounting). NOT on extract_chat_range,
  provenance_relationships, chat_timeline, live_chats, inbox_state,
  post_inbox_advice.
- Feeds `helper :parse_follow` (workflow.rb:49–52) and `helper :provenance_data`
  (workflow.rb:202–208, memo keyed `[file, follow_relations]`).
- Zero external callers pass it: the only live consumer session passed `file` only;
  no other invocation exists anywhere in AgentSuite or scout-ai.
- The only exercised use is the checkout's own test
  `test/test_provenance_relationships.rb:124` (default-is-all), `:133` (invalid
  raises), `:142` (memo distinguishes follow subsets).
- The new core surface the redesign targets deliberately has no such knob:
  `Chat.provenance_graph` documents "There is no `follow` option and no recursion:
  one node per call" (provenance.rb:278–279). `follow` exists only on
  `Chat.traverse_provenance` (provenance.rb:143, `follow: :all`).

Recommendation: **drop `follow` from the redesigned task contract** (keep default
`:all` traversal). Rationale: no consumer ever used it; it encodes traversal-breadth
control that the new one-node-per-call graph API intentionally removed; keeping it
would perpetuate a per-task input contract nothing exercises. Cost control remains
available at the traversal layer (`traverse_provenance(follow:)`) if a real need
reappears — reintroduce then, with evidence. Consequence to plan: update
test_provenance_relationships.rb tests 124/133/142 and the memo identity collapses to
`file` alone.

## 3. Git usability: BROKEN

- `git -C /bulk/mvazque2/git/AgentSuite/ChatAnalyst status --short` →
  `fatal: not a git repository: /bulk/mvazque2/git/AgentSuite/ChatAnalyst/../.git/modules/ChatAnalyst`
- `git log -1` → same fatal.
- Cause: `.git` is a 36-byte gitdir file (`gitdir: ../.git/modules/ChatAnalyst`,
  ChatAnalyst/.git, Sep 1) but `/bulk/mvazque2/git/AgentSuite/` contains ONLY the
  ChatAnalyst directory — the parent `.git/modules` tree does not exist on this
  mount. (The checkout was evidently extracted from a submodule layout without its
  parent repo.)
- Consequence: no git diff/status/commit baseline is available. Baselines for later
  stages must be snapshots (file copies + checksums) taken before editing.

## 4. Provenance spot-check with line numbers

File: `/home/mvazque2/git/scout-ai/lib/scout/llm/chat/provenance.rb` (501 lines).

- **Signature**: `def self.provenance_graph(root, root_type: nil, on_error: :collect)`
  — provenance.rb:280.
- **Root typing**: `root_kind = (root_type || (Step === root ? :job : :chat)).to_sym`
  — :291 (a bare STRING root defaults to `:chat` unless `root_type:` is given; a Step
  object defaults to `:job`). Only `:chat`/`:job` accepted (raise at :292).
- **Return keys**: `{type: root_kind, chats: chats, dependencies: dependencies,
  delegation: delegation, live: live, warnings: warnings}` — provenance.rb:402–403
  (verified literal in source).
- **Output-chat-only rule for job roots**: `job_result_chat_file` returns a path only
  when `job.type.to_s == 'chat' && File.file?(job.path)` — :78–82; and the transcript
  comment "A job's input chat is invocation context, never generated output, and is
  never read." — :308–310, with the transcript selection at :310.
- **chats anchoring**: standalone `meta: job=` messages anchored at their own message
  index, values are RESOLVED canonical absolute job paths — :303–311 (loop;
  `add_indexed_reference(chats, ...)` calls at :325 and :358) with contract comment
  :265–273 ("a job reference lifted from an agent_meta receipt inside
  a function_call_output envelope (anchored at the OUTER output message index)").
- **`add_indexed_reference` Array-merge**: nil→scalar; scalar≠value→`[current, value]`;
  existing Array appends unless already included — :408–416 (merge line :414).
- **No follow/no recursion in graph API**: :278–279.
- **tokens.rb** (`provenance/tokens.rb`, 386 lines): `provenance_token_events(root,
  warnings:, strict:, chats:, **traversal_options)` — :98; `provenance_token_totals` —
  :343; `tokens` — :382.
- **live.rb** (`provenance/live.rb`, 1080 lines): `live_report(save_file, captured: [])`
  — :519; also `live_chat_state` :1056, `society_live` :998, `agent_view_live` :863.

## 5. Currency / drift

| File | Current | Reviewed snapshot | Verdict |
|------|---------|-------------------|---------|
| `workflow.rb` | 1,531 lines, 73,242 bytes, mtime 2026-10-08 19:41 | ~1,000 lines | **Drift**: +~53% vs snapshot. File untouched since Oct 8 (mtime predates the Nov 7 review), so the snapshot figure itself is stale/inaccurate for this checkout — later stages must re-measure, not trust ~1,000. |
| `lib/ChatAnalyst/tasks/timeline.rb` | 814 lines, mtime 2026-10-09 18:28 | ~814 lines | **Matches** exactly. No edits since Oct 9. |

Neither file changed after the reviewed dates; there is no fresh drift, but the
workflow.rb line-count snapshot in the plan is wrong for this checkout and should be
corrected to 1,531 in Stage 0 outputs.

Also noted for Stage 7/10 planning: workflow.rb declares 16 exported tasks (list at
workflow.rb:552–1483) PLUS the timeline pair (`timeline_index` timeline.rb:674,
`chat_timeline` timeline.rb:751) loaded via `require 'ChatAnalyst/tasks/timeline'`
(workflow.rb:1529) — 17 task names total live, one of them internal-only.

## 6. Environment note

The `/home/mvazque2/.scout/var/jobs/Planned/request/Default_4148636e8b1669aa8076377dc7f2405c.chat`
spec IS accessible from this surface (16180 bytes, mtime 2026-11-07 18:18, 92 lines).
It was read and used as the operative Stage 0–10 specification; the facts in this
report are consistent with it (spec lines: Stage 0 requirements at :21, Stage 7 thin
task list at :40 (line 8 of stages), Stage 10 adapter policy at :40, and the compact
shape assumption note at :52 — all satisfied by the spot-checks above; corrected
spec line refs: Stage 7 at :37, Stage 10 at :40).
