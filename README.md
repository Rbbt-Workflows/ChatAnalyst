ChatAnalyst: session introspection for Scout-AI

ChatAnalyst reads persisted Scout-AI chats with `Chat.load` and traverses job references through scout-ai's compact one-node provenance API `Chat.provenance_graph`. It inspects sessions, their lineage segments, producer jobs, agent logs, tool calls, and direct token usage without replaying them. Report state stays in ordinary Hashes and Arrays of paths, zero-based indices and counts; there is no Session or graph wrapper.

The exported interface is two-layered:

- a **public Ruby API** — plain module methods on `ChatAnalyst` (`lib/ChatAnalyst/api.rb` plus the inference and activity model in `lib/ChatAnalyst/inferences.rb`) returning serializable Hashes/Arrays;
- **workflow tasks** (`lib/ChatAnalyst/tasks/api_tasks.rb` for the analytical family, inline declarations in `workflow.rb` for the operational family) that serialize the module methods into Scout TSV tables, with two body-carrying exceptions (`chat_message`/`chat_range` are `:chat` outputs, `inbox_note` is `:text`).

The exported surface is exactly 25 tasks; **no task returns JSON**. Method names (`ChatAnalyst.overview`) and task names (`ChatAnalyst.job(:chat_overview, ...)`) are distinct surfaces: the method is the Ruby API, the task is the Scout workflow surface (CLI or agent tool). Tasks never re-implement provenance semantics; they call the module methods and encode the result.

All `file` inputs accept a chat path or a job root unless the task states a restriction. Task inputs that name a chat (`role`, `chat`) are filters that **narrow the listed rows only — summary counts stay raw**. Pagination (`page` 1-based, `per_page` default 50) applies only when `page` is given. Paths in TSV keys and cells are **escaped** ([encoding conventions](doc/developer/README.md)); unescape a path before feeding it back into a task `file` input.

**Where to go next**

- [doc/user/README.md](doc/user/README.md) — the retrieval ladder for analysts, token count categories and cost notes, per-task inputs and outputs, the operational addressing rules.
- [doc/developer/README.md](doc/developer/README.md) — public Ruby API and behavior notes, vocabulary (`meta` vs `agent_meta`), addressing internals, encoding conventions, the inference and activity-cluster model, caches and freshness, limitations.

# Tasks

Exactly 25 exported tasks. Every task produces a Scout TSV (`:tsv`) table of rows, except `chat_message`/`chat_range` (byte-exact `:chat` text) and `inbox_note` (`:text`). The entries below are grouped the way a reader usually reaches them — overview and relationships, messages and inferences, activity clusters, tool calls, tokens, and the operational family — see [doc/user/README.md](doc/user/README.md) for the per-task input/output tables.

## chat_overview

TSV overview of the chats in the loaded provenance tree, one row per chat.

Fields: message count, reference count (job references plus delegations) and warnings. Annotations carry the root path and the chats/jobs/delegations summary counts. Relationship references (import/continue/last) live in `chat_references`.

## job_overview

TSV overview of the job nodes of the provenance tree, including the job root when the root is a job.

Fields: result chat path when the job's result is a chat, direct dependency count, live log count. root_path/total annotations.

## chat_references

TSV reference index of one chat: job references, delegations and relationship references.

Sources: job references (from receipts/meta), delegations (`agent#conversation` references with target_kind=agent), and import/continue/last relationship references. Key = message id#reference type#occurrence; target_kind job|chat|agent; resolution flags with short controlled reasons only.

## job_dependencies

TSV of the direct job dependencies of the provenance tree, one row per declared edge.

Key = owner job#dependency#position (1-based declared order). Which job owns which edge lives in `job_overview`; the full recursive closure lives in `job_dependencies_recursive`.

## job_dependencies_recursive

TSV of the recursive dependency closure of the provenance tree, keyed by dependency#depth.

Breadth-first over the direct job dependencies. via_owner is the job that declared the edge (first in traversal order when several do at equal depth); smallest depth wins; traversal is cycle-safe and stops at `max_depth`.

## chat_role_counts

TSV role counts across the chats of the provenance tree.

Key = chat#role composite, native Integer counts (the table casts `:to_i`). root_path/total annotations.

## chat_messages

TSV index of every message in one chat.

Fields: role, character count, normalized timestamp (or \N) and a large-message flag (bool-string against a fixed threshold constant). Message bodies are never included. Role filter and pagination narrow the listed rows only.

## chat_message

Byte-exact retrieval of exactly one message as a `:chat` output (the message's `Chat.print` text).

A `:chat` output carries no metadata envelope: the chat path and index ride the persisted job inputs — here the `message_id` input itself (escaped chat path, `#`, zero-based index) is the addressing record. Malformed ids and out-of-range indices raise ParameterException.

## chat_range

Byte-exact retrieval of a slice of one chat as a `:chat` output (the exact `Chat.print` text).

The slice is the persisted text itself, verbatim. Task-level cap of 200 messages per request; use sub-ranges for longer spans. The addressing (file/first/last) lives in the persisted job inputs because a `:chat` output carries no metadata envelope.

## chat_inferences

TSV index of all inferences in the provenance tree (root-scoped, chronological), one row per inference.

Fields: reasoning presence and character count, span/trigger/assistant message ids, activity cluster id and tool-call count. Serializes `ChatAnalyst.inferences`. Paginated when `page` is given.

## chat_activity_clusters

TSV compact index of activity clusters — runs of related inferences — keyed by the cluster id.

The cluster id is the Message id of the first inference in the cluster. Fields: first/last timestamps, duration, member inference count, chats (multi-value), tool-call and delegation counts. No member lists; members live in `chat_activity_cluster`.

## chat_activity_cluster

TSV member detail of one activity cluster, one row per member inference in chronological order.

Field list identical to `chat_inferences`. The grouping is the same (root, max_gap_seconds) clustering that `chat_activity_clusters` indexes, and the task runs as a dependency on it; an unknown cluster id raises ParameterException.

## chat_tool_call

Metadata-only TSV row for exactly one tool call (field list identical to `chat_tool_calls`).

Fields: status, controlled reason, timestamps, argument/output character counts, output message id, delegation split, inference ownership, copy marking. The row carries sizes and addresses only — retrieve bodies through `chat_range` on the call/output message ids.

## chat_tool_calls

Tree-wide TSV index of tool calls, keyed by the ToolCall (the call-start Message id).

Metadata only, never argument or output bodies. Filters (`tool`/`agent`/`conversation`/`chat`/`success`) and pagination narrow the listed rows only; the total annotation counts the raw call universe and the applied filters ride the `filters` annotation. Derive counts from the rows themselves.

## chat_tool_call_jobs

Flat call-to-job TSV, one row per (tool call, referenced job) pair.

Universe: the tree-wide call universe (overview chats plus job live log chats, uniq — the same universe `chat_tool_calls` uses). Key = call-start Message id # escaped job path; the job cell is the alignment copy. A call with three job references yields three rows.

## chat_tokens

TSV token summary: four Scope rows x pt/ct/tt/cct/cwt/rt.

Scope rows: deduplicated_total, chat_evidence, receipt_evidence and receipt_only. Native Integers via the `:to_i` cast. OVERLAP: chat_evidence and receipt_evidence are evidence-coverage rows that overlap and must not be summed; only deduplicated_total and receipt_only compare additively. The event list, evidence rows and attribution view live in `chat_token_events` / `chat_token_evidence` / `chat_attribution`.

## chat_token_events

Paginated TSV of deduplicated token events, keyed by the TokenEvent identity composite.

The identity composite looks like `inference_id#w1` or `receipt#<escaped evidence address>`. Fields: token counts (int-strings), the deduplication enumeration (inference_id | provider_response_id | lineage | receipt), conflict/incomplete_evidence flags, and the canonical evidence source/origin (canonical = evidence first). Serializes `ChatAnalyst.tokens(file)[:events]` — one tokens computation per run.

## chat_token_evidence

TSV of token-event evidence rows, aligned by construction, keyed by Evidence = token_event_id#occurrence.

Occurrence is 1-based with canonical evidence first (the counted copy is occurrence 1). Fields: origin (chat_meta | agent_meta), escaped source path, call_id/tool_name where the record carries them, and origin-specific addresses: meta_address (Message id; chat_meta rows), evidence_address (message_id#meta#index) / output_address (Message id) / agent_meta_index (agent_meta rows), \N where the field does not apply. Shares the single tokens computation with `chat_token_events`.

## chat_attribution

TSV token attribution: three Bucket rows of the canonical-evidence-source split.

Buckets: root, delegated and unattributed; each row carries pt/ct/tt/cct/cwt/rt (int-strings) and the event count. Conflicts and incomplete_evidence ride as quality annotations. Linked/unresolved job lists are not cells; they remain available through the overview and job surfaces.

## chat_accounting

TSV accounting for a chat and every chat it imports: one row per closure chat, or one merged closure row.

The scope annotation carries which. Columns: imports/unresolved_imports/delegated_subtrees (multi, |-joined), messages, pt..rt, token_events, conflicts, incomplete_evidence, tool_calls, direct/delegated splits, warnings — all int-strings (mixed table, no cast). Accepts a chat root only; composition is single-pass.

## live_chats

Live-chat discovery TSV, newest-first rows keyed by the canonical chat path.

Fields: mtime (iso8601(3)), age_seconds, size, likely_active, source (provenance|glob|jobs) and jobs_file (escaped path or \N, :jobs rows only). Discovery sources keep their precedence and fail-soft behavior: chats that vanish mid-scan are skipped. The job root stays addressable through `chat_overview`/`job_overview`.

## chat_live_report

TSV live report, one row per live entry of ChatAnalyst.live.

ChatAnalyst.live is the fail-soft wrapper over `Chat.live_report`. Key = the job reference when non-empty else the escaped path; fields kind (inference|workload_context|agent_activity|dangling_job), path, state, status, chat_task, agent, conversation, source (multi, |-joined subset of sidecar|agent_view|society). Separate from `live_chats` file discovery.

## inbox_state

Inbox index TSV, one row per pending/delivered note keyed by the absolute escaped note path.

Fields: state (pending|delivered), name, mtime, size. Note bodies are not included — read them with `inbox_note`. Missing directories are an empty table, never an error; a note consumed between listing and stat is skipped.

## inbox_note

Read one inbox note as a `:text` output (the note's exact contents).

A point read, not discovery: the note name must be a plain file name and the note must exist in the pending or delivered inbox of the save file, else ParameterException.

## post_inbox_advice

Post advice into a live chat inbox; the result is a one-row TSV keyed by the escaped posted path.

The posting itself is the side effect; the result row carries name, save_file, inbox_dir and size. Safeguards: chat-root guard, plain-file-name validation, non-empty message, reserved abort name rejected before any write, no-overwrite, and a default timestamped name. Delivery is consume-once on the next real inference; the moved file in inbox_removed/ is the delivery record.
