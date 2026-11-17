# ChatAnalyst user documentation

Analyst-facing usage of the ChatAnalyst workflow: how to walk a session,
which task answers which question, token-count vocabulary, and the
operational addressing rules. The task surface itself is in
[ChatAnalyst/README.md](../../README.md); internals, encoding contract and
retirements are in [doc/developer/README.md](../developer/README.md).

## The retrieval ladder for analysts

Start from an overview, narrow through indexes, retrieve bodies last. Every
step passes ONLY paths and integer indices between tasks — no digests to
memorize, no synthetic ids:

1. `chat_overview` (tree shape: chats, message counts, reference counts,
   delegations) or `job_overview` (jobs, result chats, dependency counts).
2. Temporal narrowing: `chat_activity_clusters` (compact index; the DEFAULT
   temporal entry point — it never returns all inferences), then
   `chat_activity_cluster` for one cluster's members, or `chat_inferences`
   paged for the explicit drill-down.
3. References and dependencies: `chat_references` (delegations and their
   targets; follow a delegation's materialized job through `job_overview`),
   `job_dependencies` (declared order) / `job_dependencies_recursive`
   (closure).
4. Tool-call detail: `chat_tool_calls` (filters + pagination) to locate a
   call, `chat_tool_call` for its metadata row (sizes, status, timestamps,
   output_message_id).
5. Evidence: `chat_range` on the call-start and/or output message ids
   (`first == last` for one message), or `chat_message` with a Message id
   directly.

Worked chain (a failed tool call): `chat_overview` ->
`chat_activity_clusters` -> `chat_inferences` (chat filter, page) ->
`chat_tool_calls` (success=false) -> `chat_tool_call` (metadata row) ->
`chat_range` on the output message id.

## Addressing rules you need when reading tables

- Message indices are **zero-based** positions in the parsed message
  sequence of one chat file; `chat_range` spans are inclusive at both ends.
- `characters` counts the characters of the **parsed message content**
  string; it is never a file byte offset.
- Paths in TSV keys and cells are **escaped** per the encoding conventions
  (developer doc): unescape a path before feeding it back into a task
  `file` input.
- `:chat` outputs (`chat_message`, `chat_range`) are the bare persisted
  chat text — no `#:` annotation line, no metadata sidecar. Their
  addressing (chat path, first/last indices) lives in the **persisted job
  inputs** (`step.info`), never in the output text. Consumers cannot read
  annotations from a `:chat` output.
- All `file` inputs accept a chat path or a job root unless the task states
  a restriction. Filters (`role`, `chat`) narrow the listed rows only —
  summary counts stay raw. Pagination (`page` 1-based, `per_page` default
  50) applies only when `page` is given; an out-of-range page yields empty
  rows, and `total` always counts the unpaginated universe.

## Task tables (phase 3 grouping)

Grouping follows the phase-3 contract (`research/phase3-contract.md` §2).

**A. Overview and relationship tables**

| task | output / key | purpose |
|---|---|---|
| `chat_overview` | :tsv, Chat | Tree overview: one row per chat (messages, references, warnings); annotations root_path/total/chats/jobs/delegations. Inputs: `file`, `root_type`. |
| `job_overview` | :tsv, Job | Jobs of the tree: result_chat (escaped chat-typed result or `\N`), dependency_count, live_log_count. Input: `file`. |
| `chat_references` | :tsv, Reference = message_id#reference_type#occurrence | Reference index of ONE chat: job_reference / delegation / import / continue / last rows with target_kind (job/chat/agent), target_id, resolved, unresolved_reason. Input: `file` (chat). |
| `job_dependencies` | :tsv, Dependency = owner_job#dependency#position | Direct declared edges, 1-based position. Input: `file`. |
| `job_dependencies_recursive` | :tsv, Dependency = dependency#depth | Recursive closure (see developer doc). Inputs: `file`, `max_depth` (default 10). |
| `chat_role_counts` | :tsv, ChatRole = chat#role | Message counts per chat and role; the only `:to_i`-cast table in group A. Input: `file`. |

**B. Message and inference tables**

| task | output / key | purpose |
|---|---|---|
| `chat_messages` | :tsv, Message | Zero-based index of every message in one chat: role, characters, timestamp, large flag. Never bodies. Inputs: `file` (chat), `role` (filter), `page`, `per_page`. |
| `chat_message` | :chat | Byte-exact persisted text of ONE message. Input: `message_id` (the Message id grammar; the chat and index are recovered by parsing it). Addressing in the persisted job inputs. |
| `chat_range` | :tsv->:chat | Byte-exact persisted slice of one chat, `first`..`last` inclusive (`first == last` valid); cap 200 messages per request. Inputs: `file` (chat only; job roots rejected), `first`, `last`. The old `raw` input is retired: the byte-exact form is THE output. Addressing in the persisted job inputs. |
| `chat_inferences` | :tsv, Inference = meta Message id | Tree-wide chronological inference list: timestamp, reasoning_present, reasoning_characters, first/last/trigger/assistant Message ids, activity_cluster_id, tool_call_count. Inputs: `file`, `max_gap_seconds` (default 120), `page`, `per_page`, `chat` (filter). Paginated. |

**C. Activity clusters**

| task | output / key | purpose |
|---|---|---|
| `chat_activity_clusters` | :tsv, Cluster = first inference's Message id | COMPACT INDEX ONLY (no member lists): first/last timestamp, duration_seconds, inference_count, chats (multi-value), tool_call_count, delegation_count; annotations clusters/inferences/unclustered. Inputs: `file`, `max_gap_seconds`. |
| `chat_activity_cluster` | :tsv, Inference | Member detail of ONE cluster, one row per member inference in chronological order (field list identical to chat_inferences); validated through a task dependency on chat_activity_clusters. Inputs: `file`, `cluster_id`, `max_gap_seconds`. |

**D. Tool-call tables**

| task | output / key | purpose |
|---|---|---|
| `chat_tool_call` | :tsv, ToolCall = call-start Message id | ONE metadata row for exactly one call: same field list as chat_tool_calls (sizes and addresses only — bodies are retrieved through chat_range on the call/output message ids). Inputs: `file` (chat), `call_index`. |
| `chat_tool_calls` | :tsv, ToolCall | Tree-wide call index: output_message_id, tool, call_id, status, reason, timestamps, argument/output characters, inference_id, delegated, target_agent/target_conversation, copy_of, source_kind. Inputs: `file`, `page`, `per_page`, `dedupe`, filters `tool`/`agent`/`conversation`/`chat`/`success`; applied filters ride the `filters` annotation. Paginated. |
| `chat_tool_call_jobs` | :tsv, CallJob = call_message_id#escaped_job_path | One row per (call, referenced job) pair; the `job` cell is the alignment copy. Input: `file`. |

**E. Token tables**

| task | output / key | purpose |
|---|---|---|
| `chat_tokens` | :tsv, Scope (`:to_i` cast) | SUMMARY: four rows (deduplicated_total, chat_evidence, receipt_evidence, receipt_only) x pt/ct/tt/cct/cwt/rt; annotations conflicts/incomplete_evidence. Input: `file`. OVERLAP WARNING: chat_evidence and receipt_evidence overlap and must not be summed; only deduplicated_total and receipt_only compare additively. The retired `attribution` input moved to chat_attribution. |
| `chat_token_events` | :tsv, TokenEvent | Paginated deduplicated event list: token counts, deduplication enumeration (inference_id/provider_response_id/lineage/receipt), conflict/incomplete flags, canonical evidence source/origin. Inputs: `file`, `page`, `per_page`. |
| `chat_token_evidence` | :tsv, Evidence = token_event_id#occurrence | Aligned evidence rows, canonical evidence first (occurrence 1): origin, source, call_id, tool_name, and the origin-specific addresses. Input: `file`. |
| `chat_attribution` | :tsv, Bucket | Three rows (root, delegated, unattributed) of the canonical-evidence-source split, plus events count; conflicts/incomplete_evidence as quality annotations. Input: `file`. The linked/unresolved job lists stay on the overview/job surfaces. |

**F. Operational tasks**

| task | output / key | purpose |
|---|---|---|
| `chat_accounting` | :tsv, Chat | Per-chat accounting over the import closure: imports/unresolved_imports/delegated_subtrees (multi-value), messages, pt..rt, token_events, conflicts, incomplete_evidence, tool_calls, direct/delegated splits, warnings. Inputs: `file` (chat root only), `scope` (own/closure; rides the `scope` annotation). |
| `live_chats` | :tsv, Chat | Live-chat DISCOVERY (files): mtime, age_seconds, size, likely_active, source (provenance/glob/jobs), jobs_file. Newest-first; fail-soft. Input: `file`. Keys and jobs_file carry escaped absolute paths. |
| `chat_live_report` | :tsv, Entry | Core LIVE report (running state): kind (inference/workload_context/agent_activity/dangling_job), path, state, status, chat_task, agent, conversation, source (multi). Separate from live_chats by design. Input: `file`. |
| `inbox_state` | :tsv, Note | Inbox INDEX ONLY: state (pending/delivered), name, mtime, size — never note bodies (read them with inbox_note). Input: `file` (chat save file). Missing directories = empty table. |
| `inbox_note` | :text | Exact contents of ONE inbox note (point read). Inputs: `file` (chat save file), `name` (plain file name). |
| `post_inbox_advice` | :tsv, Posted | Posts one advice note (side effect) and returns one row: name, save_file, inbox_dir, size. Inputs: `file` (chat save file), `message`, optional `name`. Safeguards: chat-root guard, plain-name validation, non-empty message, reserved `abort` name rejected before any write, no-overwrite, default timestamped name. |

## Token count categories

- pt: prompt tokens
- ct: completion tokens
- tt: total tokens
- cct: cache tokens (subset of prompt tokens)
- cwt: cache write tokens
- rt: reasoning tokens

When discussing tokens always consider that cache tokens are much less
expensive in general (about 10% of the normal cost).

## Programmatic and command-line use

Typical programmatic use (the Ruby API layer — see the developer doc for
the full method list):

    report = ChatAnalyst.tokens('/path/to/session.chat')
    view   = ChatAnalyst.attribution('/path/to/session.chat')

For command-line inspection of the same model, use:

    scout-ai llm prov /path/to/session.chat
