---
name: chatanalyst-session-introspection
description: "Inspect recorded Scout-AI sessions with the ChatAnalyst workflow - find chats, jobs and receipts, walk provenance from a chat or job root, index messages and tool calls, retrieve byte-exact slices, and answer token questions. Use when you need to reconstruct what a session did, trace a job reference or delegated agent receipt, size or audit token usage, or decide between ChatAnalyst tables and direct file reads. Triggers: chat_overview, job_overview, chat_activity_clusters, chat_inferences, chat_tool_calls, chat_range, chat_tokens, chat_attribution, \"session introspection\", \"provenance graph\", \"delegation receipt\", \"find the chat\", \"token usage\"."
---

# ChatAnalyst session introspection

## What this skill covers

Finding and inspecting recorded Scout-AI sessions — chats, jobs, receipts
and provenance — with the ChatAnalyst workflow, and deciding when to use it
instead of reading session files directly. Covers the retrieval ladder
(overview → indexes → bodies), the addressing rules (escaped paths,
zero-based indices, `:chat` output semantics), token questions, and the
post/inbox side effects.

## When to use ChatAnalyst vs direct file reads

- **Use ChatAnalyst** when you need structure over volume: the tree shape
  (which chats/jobs a session produced), message indexes, tool-call
  metadata, token totals/attribution, activity clusters, or a byte-exact
  slice of one message. Every table passes only paths and integer indices —
  no digests or synthetic ids to track.
- **Use direct file reads** (`read`/`grep` on `var/cortex/...` or a chat
  path) for a single known small file or a literal string search — cheaper
  than a task run. Chat files are plain text and greppable; ChatAnalyst
  adds structure, not content.
- **Never** replay a chat to learn what it did — the persisted record plus
  ChatAnalyst answers without inference cost.

## Where sessions live

- Chats and jobs under a checkout's `var/` tree: chats as plain files,
  jobs as Step directories with `.info` sidecars (`var/jobs/<Workflow>/…`).
- Society chats (delegated agent conversations):
  `<caller_job>.files/<name>.society/<AgentName>/<conversation>/agent.chat`.
- All `file` inputs accept a chat path OR a job root (a Step directory
  detected by its `.info`); `root_type` overrides detection.

## The retrieval ladder

1. **Shape first**: `chat_overview` (tree: chats, message counts,
   references, delegations) or `job_overview` (jobs, result chats,
   dependency counts).
2. **Narrow temporally**: `chat_activity_clusters` (compact index — the
   DEFAULT temporal entry point), then `chat_activity_cluster` (one
   cluster's members) or `chat_inferences` (paged drill-down).
3. **References/dependencies**: `chat_references` (delegations, targets),
   `job_dependencies` / `job_dependencies_recursive`.
4. **Tool calls**: `chat_tool_calls` (filters + pagination) →
   `chat_tool_call` (one metadata row: sizes, status, output_message_id).
5. **Bodies last**: `chat_range` (inclusive first..last, cap 200 messages)
   or `chat_message` (one message).

Worked chain (failed tool call): `chat_overview` →
`chat_activity_clusters` → `chat_inferences` (chat filter) →
`chat_tool_calls` (success=false) → `chat_tool_call` → `chat_range` on the
output message id.

## Addressing rules that trip people

- Indices are **zero-based** positions in the parsed message sequence.
- Paths in TSV keys/cells are **escaped** (`%`→`%25`, `#`→`%23`, TAB/NL/CR);
  unescape before feeding a path back into a task input.
- `:chat` outputs (`chat_message`, `chat_range`) carry **no annotations**;
  their addressing lives in the persisted job inputs (`step.info`), not the
  output text.
- Message id = `escaped_chat_path#index` — split on the FIRST `#`.
- Filters (`role`, `chat`) narrow rows only; summary counts stay raw.
  Pagination applies only when `page` is given.

## Token questions

- `chat_tokens` — summary (deduplicated_total / chat_evidence /
  receipt_evidence / receipt_only). OVERLAP: chat_evidence and
  receipt_evidence must not be summed.
- `chat_token_events` / `chat_token_evidence` — per-event detail and
  evidence alignment.
- `chat_attribution` — root/delegated/unattributed split.
- Cache tokens (cct) cost ~10% of normal tokens; factor that in before
  calling a session "expensive".
- Programmatic alternative: `ChatAnalyst.tokens(path)`; CLI: `scout-ai llm
  prov <chat>`.

## Side effects (the only two)

- `post_inbox_advice` WRITES a note into a live chat's inbox (safeguards:
  chat-root guard, plain names, no-overwrite, reserved `abort` rejected).
  Replays from cache when inputs are unchanged — use distinct names when
  testing.
- Everything else is read-only over the persisted record.

## Common mistakes

- Retrieving bodies before narrowing (`chat_range` over a 3k-message chat
  you have not indexed).
- Summing chat_evidence + receipt_evidence.
- Feeding an escaped path from a TSV cell back as a `file` input without
  unescaping.
- Expecting annotations on a `:chat` output.
- Following delegation targets manually — `chat_references` +
  `job_overview` do it structurally.

## Going deeper (repo-relative pointers, optional)

- `ChatAnalyst/doc/user/README.md` — retrieval ladder, per-task tables
  (A-F), token categories, addressing rules.
- `ChatAnalyst/doc/developer/README.md` — encoding conventions,
  identifier grammar, inference/activity-cluster model, retirements,
  scout-ai version guard.
- `ChatAnalyst/README.md` — the 25 task entries.
