# Search brief — fine-grained provenance extraction & separate accounting in ChatAnalyst

## Main question
How can ChatAnalyst extract the provenance relationships of any chat (including import/continue/last references that core traversal deliberately ignores) and follow/account each related chat separately — e.g. account one chat in a progressive-import chain without accounting for the previous imported chats?

## Key findings

### 1. Core (scout-ai) provenance API — what exists today
File: `/home/mvazque2/git/scout-ai/lib/scout/llm/chat/provenance.rb`

- `PROVENANCE_RELATIONS = %i[job dependency log result agent_job]` (line ~4). There is **no `:import` relation**.
- `Chat.traverse_provenance(root, root_type:, follow:, on_error:, &block)` (line 142):
  - `follow:` accepts `:all` (default) or an Array of relation symbols; **unknown relations raise `ParameterException`** (so adding `:import` to `follow` would raise unless core is changed).
  - BFS over chat/job nodes, yields `(kind, object, parent_kind, parent, relation, first_visit, detail)`; `detail` carries the agent_meta receipt record for `:agent_job` edges (call_id, tool_name, output/evidence address, job ref) — two receipts to the same job stay two distinct edges.
  - **By design it never follows `import`/`continue`/`last` references** (documented in the code comment at lines ~138-141): imports are a chat-compilation concern, resolved during `Chat.chat`/`Chat.parse` and their content is already inlined in compiled/persisted session chats.
- Derivatives all accept `**traversal_options` (so `follow:` passes through): `provenance_edges` (276), `provenance_chat_files` (301), `provenance_jobs` (309), `provenance_token_events` (426), `provenance_token_totals` (656).
- `Chat.load` (`process/meta.rb:187`) parses **without compiling** — import/continue/last roles survive as messages in the parsed chat, so the references are recoverable from any source chat file.
- Token events are deduplicated by `inference_id` (fallback `[:lineage, lineage_id]`) — **token accounting is already correct; do not change it** (confirmed by prior research).

### 2. Import/continue/last mechanics (recoverable relationships)
File: `/home/mvazque2/git/scout-ai/lib/scout/llm/chat/process/files.rb`

- `Chat.find_file(file, original, caller_lib_dir)` (line 16) resolves a reference: relative to the importing file's dir → caller_lib_dir (`chats/`) → literal path → `Scout.chats[file]`. Raises "Import not found" otherwise.
- `Chat.imports` (line 38): `import` inlines `LLM.purge(new)` (whole chat), `continue` keeps only the last non-empty message, `last` keeps `LLM.purge(new).last`. Inlining happens at the reference's position in the file, **with no marker** in the compiled result.
- Consequence: inside a compiled/persisted session chat, imported content is unattributed; attributing it to the source chat requires identity matching (lineage id / message fingerprints), not byte digests (splice normalizes newlines — see `03-duplication-evidence.md`).
- `meta: job=` references (the cross-conversation channel): `Chat#job_paths` / `alias jobs` at `process/meta.rb:177-183`. These ARE followed as `:job` edges by traversal, including shared-context (`chat: current`) receipts — the root cause of the earlier closure blow-up.
- Duplication mechanism (context): `Chat.follow` splice at `annotation.rb:115-146` + `lib/scout/llm/tools/call.rb:170-181` embeds child transcripts into parent logs; one chat can appear byte-identical in 8 parent logs.

### 3. ChatAnalyst workflow — current state
File: `/bulk/mvazque2/git/workflows/ChatAnalyst/workflow.rb` (~730 lines; git `50e369b` + uncommitted test/README work)

- `helper :provenance_data` (lines ~96-148) calls the four `Chat.provenance_*` APIs with **no `follow:`/scope options** — always the full closure. It **memoizes per `file`** (`@provenance_data[file]`), so any new options must become part of the memo key.
- `helper :resolve_root` (lines ~33-46): accepts chat file or chat-producing job (`.info`/`.files` heuristics + `Scout.chats` lookup); returns `[:chat, Path]` or `[:job, Step]`.
- Tasks (all take only `file` + small filters; no scope/per-chat option):
  - `message_index` (323; only task with `page`/`per_page`), `message_content` (377), `chat_overview` (398), `chat_tool_calls` (455), `chat_tokens` (473), `chat_agents` (507), `meta_evidence` (580), `chat_reasoning` (638), `chat_report` (707).
  - `message_index` entries carry `address: "path#index"` and lineage ids (`id`, `prev` from `Chat#message_index`, `process/meta.rb:241`) — per-chat filtering is already possible client-side here; all aggregate `totals` in other tasks are global.
- Warnings normalization (`normalize_provenance_warning`, `warning_key`) already dedups collector/traversal warnings.
- README documents tasks in Scout format (`# Tasks` + `## task` sections, no headers inside task bodies).

### 4. Prior research — decision-ready fix plan (read first)
Dir: `/home/mvazque2/git/scout-ai/research/chatanalyst-provenance/`
`final-report.md` + `05-fix-plan.md` contain a prioritized, source-anchored plan:

1. **Fix 3 (QW)** expose edges/filters (`chat_edges` task; `relation:`/`call_id:`/`job:` filters on meta_evidence/chat_reasoning).
2. **Fix 5 (QW)** paginate/summarize heavy tasks (`chat_tool_calls`, `chat_tokens`, `chat_agents`, `meta_evidence`) like `message_index` (a live 136,942-char refusal was reproduced).
3. **Fix 1+2 (QW+M, the user's core ask)** pass `follow:` through in ChatAnalyst; add conversation-boundary scoping in scout-ai (`job_refs: :own | :own|:all`, default `:all`); skipped shared-context refs reported as a new `:context` edge kind — never silently hidden. Recommended: **configurable, not default**.
4. **Fix 7 (M)** `chat_diff(file, other_file)` — symmetric difference of two closures ("what is new in this run").
5. **Fix 4 (QW/M)** dedup content counts by lineage identity (not file, not byte digest).
6. **Fix 6 (S)** writer-side: persist `meta: job=<child>` + digest instead of re-embedding transcripts; add `agent=`/`instructions_digest=`/`conversation=` meta. Changes persisted formats — do deliberately, last.

"What NOT to do": don't default to `follow:` filtering; don't silently drop shared-context jobs; don't touch token accounting.

### 5. Real-world chain fixtures for this exact use case (exist on disk now)
- `~/git/scout-gear/chats/documentation_fix` — line 1: `import: ~/scout-essentials/chats/doc_inconsistencies` (chain A→B)
- `~/git/scout-gear/chats/documentation_fix2` — line 2: `import: ~/git/scout-essentials/chats/doc_inconsistencies`
- `~/git/scout-gear/chats/doc_learning` — line 1: `import: scout-essentials/doc_learning` (relative + `Scout.chats` resolution)
- `~/chats/scout-ai/provenance_issue` — line 1: `import: ~/git/scout-gear/chats/documentation_fix`; line 40: `last: ~/git/scout-gear/chats/doc_learning` (progressive/mid-file reference; ideal fixture)
- `~/git/scout-essentials/chats/doc_inconsistencies` (chain root; contains `meta: job=Planned/ask/Default_4574d35f...` refs)
- `Scout.chats[name]` resolves these (e.g. `Scout.chats["doc_learning"]` → `/bulk/mvazque2/git/scout-gear/chats/doc_learning`); ChatAnalyst `resolve_root` already uses it.
- Prior session chats (context, read-only): `~/.scout/chats/ChatAnalyst/{traverse_prov,update_prov,agent_meta_update,tooling,pagination}` — `traverse_prov` is the current session's chat (`last: ~/chats/scout-ai/provenance_issue`).

### 6. Test infrastructure (offline pattern to follow)
- `test/scout/agent_meta_fixtures.rb`: builds persisted-layout fixtures in tmpdir (Scout-AI receipt envelope shape) — standalone, no network.
- `test/test_helper.rb`: per-test tmpdir + `Workflow.directory` under it.
- `test/test_agent_meta_tasks.rb` / `test/test_cross_consumer_tokens.rb`: scenario tests incl. nested chains (`test_nested_chain_counts_every_event_once`), two-receipts-one-job, conflict/incomplete evidence.
- New tests should add a chain fixture with `import:`/`continue:`/`last:` roles and a shared-context `meta job=` to exercise scoping and per-chat accounting.

### 7. Workflow/tooling notes
- Test via WorkflowCoder `run_task(..., clean: true)` / `task_inputs` / `job_info`; `error_phase` distinguishes load/task/input-validation/execution failures.
- Scout README format: `# Tasks` + `## task_name`, no header chars inside task descriptions.
- Reading `~/git/...` paths inside `bash` sometimes fails under the sandbox (bwrap mount); prefer `read`/`list_directory` tools or `/bulk/...` realpaths (noted in `01-repo-map.md`).

## Sources
- `/home/mvazque2/git/scout-ai/lib/scout/llm/chat/provenance.rb` (traverse_provenance 142, provenance_edges 276, PROVENANCE_RELATIONS ~4)
- `/home/mvazque2/git/scout-ai/lib/scout/llm/chat/process/files.rb` (find_file 16, imports 38)
- `/home/mvazque2/git/scout-ai/lib/scout/llm/chat/process/meta.rb` (Chat.load 187, job_paths 177, message_index 241, trace_indices ~270)
- `/home/mvazque2/git/scout-ai/lib/scout/llm/chat/annotation.rb` (follow 115-146), `lib/scout/llm/tools/call.rb` (170-181)
- `/bulk/mvazque2/git/workflows/ChatAnalyst/workflow.rb` (provenance_data ~96-148, tasks 318-730)
- `/home/mvazque2/git/scout-ai/research/chatanalyst-provenance/` (00-07, final-report.md, resumption.md)
- Real chats: `~/git/scout-gear/chats/*`, `~/git/scout-essentials/chats/*`, `~/chats/scout-ai/provenance_issue`

## Relevant skills
- None: `match_skills` returned an empty catalog ("No skills in catalog") — no skill routing available in this environment.

## Uncertainties
- Whether the user wants `:import`-style edges added to scout-ai core (`PROVENANCE_RELATIONS`) or extracted ChatAnalyst-side only. Core today raises on unknown `follow:` symbols; research recommends core `:context` edge kind for skipped shared-context job refs, configurable not default.
- "Progressively import" exact granularity: per-reference event (each `import:`/`last:` line, at its position) vs per-target-chat. `provenance_issue` shows both patterns (head import + mid-file `last:`).
- Attribution of inlined imported content inside compiled sessions has no persisted marker; lineage-id/fingerprint matching is the reliable route (byte digests fail due to newline normalization).
- The user's first sentence in the original request is truncated ("the most important is being able to …"); only the provenance use case is fully specified.

## Recommendation
Knowledge-level guidance for implementers (not design decisions):
1. Read `research/chatanalyst-provenance/final-report.md` + `05-fix-plan.md` first; they contain the accepted fix order and explicit "do not" list.
2. The two facts that shape any solution: (a) core traversal intentionally ignores import/continue/last, but those references survive parsing and are resolvable via `Chat.find_file`; (b) token totals are already deduplicated by `inference_id` — only content/structure accounting needs scoping.
3. Validate on the real chain (`doc_inconsistencies` → `documentation_fix` → `provenance_issue` [+ `last: doc_learning`]) and reproduce the "account one chat alone" question end-to-end; extend the offline tmpdir fixtures with an import chain.
4. Any option added to `provenance_data` must be part of its memo key; unknown `follow:` symbols raise `ParameterException` in core.
5. Keep the full closure as default behavior; scope/follow must be opt-in; skipped references should remain visible (e.g. as `:context`-style edges), never silently dropped.
