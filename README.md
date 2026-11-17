ChatAnalyst: session introspection for Scout-AI

ChatAnalyst reads persisted Scout-AI chats with `Chat.load` and traverses job references through scout-ai's compact one-node provenance API `Chat.provenance_graph`. It inspects sessions, their lineage segments, producer jobs, agent logs, tool calls, and direct token usage without replaying them. Report state stays in ordinary Hashes and Arrays of paths, zero-based indices and counts; there is no Session or graph wrapper.

The exported interface is two-layered:

- a **public Ruby API** — plain module methods on `ChatAnalyst` (`lib/ChatAnalyst/api.rb` plus the phase-3 inference model in `lib/ChatAnalyst/inferences.rb`) returning serializable Hashes/Arrays;
- **workflow tasks** (`lib/ChatAnalyst/tasks/api_tasks.rb` for the analytical family, inline declarations in `workflow.rb` for the operational family) that serialize the module methods into Scout TSV tables, with two body-carrying exceptions (`chat_message`/`chat_range` are `:chat` outputs, `inbox_note` is `:text`).

The exported surface is exactly 25 tasks; **no task returns JSON** (phase 3). Method names (`ChatAnalyst.overview`) and task names (`ChatAnalyst.job(:chat_overview, ...)`) are distinct surfaces: the method is the Ruby API, the task is the Scout workflow surface (CLI or agent tool). Tasks never re-implement provenance semantics; they call the module methods and encode the result.

All `file` inputs accept a chat path or a job root unless the task states a restriction. Task inputs that name a chat (`role`, `chat`) are filters that **narrow the listed rows only — summary counts stay raw**. Pagination (`page` 1-based, `per_page` default 50) applies only when `page` is given. Paths in TSV keys and cells are **escaped** (see the encoding conventions); unescape a path before feeding it back into a task `file` input.

**Where to go next**

- [doc/user/README.md](doc/user/README.md) — the retrieval ladder for analysts, token count categories and cost notes, per-task inputs and outputs, the operational addressing rules.
- [doc/developer/README.md](doc/developer/README.md) — public Ruby API and behavior notes, vocabulary (`meta` vs `agent_meta`), addressing contract internals, encoding conventions, identifier grammar, the inference/activity-cluster model, caches and freshness, retirements, the scout-ai version guard, limitations.
- `skills/chatanalyst-session-introspection/SKILL.md` — finding chats, jobs and receipts; provenance traversal; when to use ChatAnalyst instead of direct file reads.

# Tasks

Exactly 25 exported tasks (phase 3; zero JSON). Every analytical task output is a Scout TSV (`:tsv`) table; `chat_message`/`chat_range` are byte-exact `:chat` outputs and `inbox_note` is a `:text` output. Grouping follows the phase-3 contract (`research/phase3-contract.md` §2): A overview/relationships, B messages/inferences, C activity clusters, D tool calls, E tokens, F operational — see [doc/user/README.md](doc/user/README.md) for the per-task input/output tables.

## chat_overview

TSV overview of the provenance tree: one row per chat (messages, references = job references + delegations, warnings). Annotations carry root_path plus the chats/jobs/delegations summary counts. Import/continue/last relationship references live in chat_references.

## job_overview

TSV overview of the job nodes of the provenance tree (the job root included when the root is a job): result chat path when the job result is chat-typed, direct dependency count, live log count. root_path/total annotations.

## chat_references

TSV reference index of ONE chat: job references (from receipts/meta), delegations (raw agent#conversation, target_kind=agent), and import/continue/last relationship references. Key = message id#reference type#occurrence; target_kind job|chat|agent; resolution flags and short controlled reasons only.

## job_dependencies

TSV direct job dependencies of the provenance tree: one row per declared edge, key = owner job#dependency#position (1-based declared order). Ownership lives in job_overview; the recursive closure lives in job_dependencies_recursive.

## job_dependencies_recursive

TSV recursive dependency closure of the provenance tree: BFS over direct job dependencies, key = dependency#depth, via_owner = the owner that declared the edge (first in traversal order when several do at equal depth). Smallest-depth wins, cycle-safe, stops at max_depth.

## chat_role_counts

TSV role counts of the chats of the provenance tree: key = chat#role composite, native Integer count (table casts :to_i). root_path/total annotations.

## chat_messages

TSV index of every message in one chat: role, character count, normalized timestamp or \N, large flag (bool-string; threshold constant unchanged). Never bodies. Role filter and pagination narrow the list only.

## chat_message

Byte-exact retrieval of exactly ONE message as a :chat output (the message's Chat.print text). A :chat output carries no metadata envelope: the chat path and index ride the persisted job inputs - here the message_id input itself (escaped chat path, #, zero-based index) is the addressing record. Malformed ids and out-of-range indices raise ParameterException.

## chat_range

Byte-exact persisted slice of one chat as a :chat output (the exact Chat.print text; the old raw:true behavior is now THE output, the raw input is retired - pinned behavior change). Task-level cap 200 messages per request; use sub-ranges for longer spans. The addressing (file/first/last) lives in the persisted job inputs because a :chat output carries no metadata envelope.

## chat_inferences

TSV tree-wide inference index (root-scoped, chronological): one row per inference meta with reasoning presence/characters, span/trigger/assistant message ids, activity cluster id and tool-call count. Serializes ChatAnalyst.inferences - no reimplementation. Paginated when page is given.

## chat_activity_clusters

TSV COMPACT INDEX of activity clusters (replaces chat_timeline temporal grouping): key = the cluster id (Message id of the first inference), first/last timestamps, duration, member inference count, chats (multi-value), tool-call and delegation counts. No member lists; members live in chat_activity_cluster.

## chat_activity_cluster

TSV member detail of ONE activity cluster (the two-mode selection chat_timeline had): one row per member inference in chronological order, field list identical to chat_inferences. Validated against the SAME (root, max_gap_seconds) clustering through a task dependency on chat_activity_clusters; an unknown id raises ParameterException.

## chat_tool_call

Metadata-only TSV row for exactly one tool call (field list identical to chat_tool_calls): status, controlled reason, timestamps, argument/output character counts, output message id, delegation split, inference ownership, copy marking. PINNED behavior change (contract 1e/2D): this row carries sizes and addresses ONLY - retrieve bodies through chat_range on the call/output message ids (the old JSON task returned full arguments and output content).

## chat_tool_calls

Tree-wide TSV tool-call index keyed by ToolCall (the call-start Message id): metadata only, never arguments/output bodies. Filters (tool/agent/conversation/chat/success) and pagination narrow the listed rows only; the total annotation counts the raw call universe; the applied filters ride the filters annotation. The retired JSON summary block is NOT carried (settled simplification): derive counts from the rows.

## chat_tool_call_jobs

Flat call-to-job TSV: one row per (tool call, referenced job) pair over the tree-wide call universe (overview chats plus job live log chats, uniq - the same universe chat_tool_calls uses). Key CallJob = call-start Message id # escaped job path; the job cell is the alignment copy. A call with three job references yields three rows.

## chat_tokens

Token SUMMARY TSV (contract 2E): four Scope rows (deduplicated_total, chat_evidence, receipt_evidence, receipt_only) x pt/ct/tt/cct/cwt/rt, native Integers via the :to_i cast. OVERLAP: chat_evidence and receipt_evidence are evidence-coverage rows that overlap and must not be summed (only deduplicated_total and receipt_only compare additively). The event list, evidence rows and attribution view moved to chat_token_events / chat_token_evidence / chat_attribution; the attribution input (and the event pagination inputs) are retired - pinned behavior change.

## chat_token_events

Paginated TSV of deduplicated token events: key TokenEvent (the 1a identity composite, e.g. inference_id#w1 or receipt#<escaped evidence address>), token counts (int-strings), the deduplication enumeration (inference_id | provider_response_id | lineage | receipt), conflict/incomplete_evidence flags, and the canonical evidence source/origin (canonical = evidence first). Serializes ChatAnalyst.tokens(file)[:events] - ONE tokens computation per run, no reimplementation.

## chat_token_evidence

Aligned-by-construction TSV of token-event evidence rows: key Evidence = token_event_id#occurrence (1-based, canonical evidence first - the counted copy is occurrence 1), then origin (chat_meta | agent_meta), escaped source path, call_id/tool_name where the record carries them, and the origin-specific addresses: meta_address (Message id; chat_meta rows), evidence_address (message_id#meta#index) / output_address (Message id) / agent_meta_index (agent_meta rows), \N where the field does not apply. Same single tokens computation as chat_token_events.

## chat_attribution

Token attribution TSV (contract 2E): three Bucket rows (root, delegated, unattributed) of the canonical-evidence-source split - ChatAnalyst.attribution semantics unchanged - each with pt/ct/tt/cct/cwt/rt (int-strings) and the event count; conflicts/incomplete_evidence ride as quality annotations. The linked/unresolved job lists are NOT cells (settled simplification, contract 2E): they remain available through the overview/job surfaces.

## chat_accounting

Accounting TSV for a chat and every chat it imports (contract 2F): own scope = one row per closure chat, closure scope = ONE merged row keyed by the root (the scope annotation carries which). Columns: imports/unresolved_imports/delegated_subtrees (multi, |-joined), messages, pt..rt, token_events, conflicts, incomplete_evidence, tool_calls, direct/delegated splits, warnings - all int-strings (mixed table, no cast). Chat-root-only guard and single-pass composition unchanged.

## live_chats

Live-chat discovery TSV (contract 2F): newest-first rows keyed by the CANONICAL chat path, fields mtime (iso8601(3)), age_seconds, size, likely_active, source (provenance|glob|jobs) and jobs_file (escaped path or \N, :jobs rows only). Discovery sources keep their precedence and fail-soft behavior (vanishing chats skipped). Recorded simplification: the JSON job-root status block is dropped (the root stays addressable through chat_overview/job_overview).

## chat_live_report

Core LIVE report TSV (contract 2F): one row per live entry of ChatAnalyst.live (the fail-soft wrapper over Chat.live_report - no reimplementation). Key Entry = the job reference when non-empty else the escaped path; fields kind (inference|workload_context|agent_activity|dangling_job), path, state, status, chat_task, agent, conversation, source (multi, |-joined subset of sidecar|agent_view|society). KEPT SEPARATE from live_chats file discovery.

## inbox_state

Inbox INDEX TSV (contract 2F): one row per pending/delivered note keyed by the absolute escaped note path, fields state (pending|delivered), name, mtime, size. Recorded behavior change: note bodies are NO LONGER embedded (read them with inbox_note). Missing directories are an empty table, never an error; per-entry race tolerance unchanged (a note consumed between listing and stat is skipped).

## inbox_note

Read ONE inbox note (:text output; the note's exact contents). A point read, not discovery: the note name must be a plain file name and the note must exist in the pending or delivered inbox of the save file, else ParameterException. Together with the index-only inbox_state this replaces the old full-content embedding.

## post_inbox_advice

Post advice into a live chat inbox (contract 2F): ONE-row TSV result (name, save_file, inbox_dir, size) keyed by the escaped posted path; the posting itself is the side effect. Every safeguard is kept: chat-root guard, plain-file-name validation, non-empty message, reserved abort name rejected BEFORE any write, no-overwrite, default timestamped name. Delivery is consume-once on the next real inference, never persisted in the transcript (the moved file in inbox_removed/ is the delivery record).
