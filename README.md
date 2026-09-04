Inspect Scout-AI sessions, their lineage segments, producer jobs, agent logs, tool calls, and direct token usage without replaying them.

ChatAnalyst uses the shared `Chat.traverse_provenance` primitive. It reads persisted chats with `Chat.load` and traverses every job referenced by `meta job=...`. The workflow keeps report state in ordinary Hashes and Arrays; it does not define a Session or graph wrapper.
For each job it follows persisted dependencies, chat results, and all
the chats saved in the job's `.files` sidecar, under two coexisting layouts:
the current layout writes the agent's full chat at
`<job>.files/<name>.chat` (`agent.chat` by default, otherwise named after the
agent, e.g. `worker.chat`) and every nested conversation under
`<job>.files/<name>.society/**/*.chat`; the legacy
`<job>.files/log/**/*.chat` layout (including the old `log/agent.chat` logs
and the `log/chats/...` projections) is written by older scout-ai, read for
compatibility, and never migrated.

Imported and continued chats are not part of core provenance; their content is
already inlined in the persisted chat file during `Chat.parse`. To account for
them anyway, `provenance_relationships` recovers `import:`, `continue:`, and
`last:` references from the uncompiled chat text and resolves them with
`Chat.find_file`, and `chat_accounting` accounts each chat of the import
closure separately from its own file.

## Provenance traversal and import closure

Two families of relationships are reported independently:

- Core provenance (job, dependency, log, result, agent_job), traversed by
  `Chat.traverse_provenance`. Every provenance task accepts a `follow` input
  to restrict traversal to a subset of relations; the default remains `all`.
- Chat-level references (`import:`, `continue:`, `last:`). They are invisible
  to core traversal, so they are recovered as explicit relationship events
  with position and resolved target, plus an import closure (post-order,
  cycle-safe). A chain of progressive imports is therefore accounted per
  chat: pass the root chat to `chat_accounting` with the default `scope:
  own` and every imported chat appears as its own entry, with the shared
  `closure` scope available for the merged total.

A meta message starts a response segment. The segment can contain several tool
calls, tool outputs, and an assistant message. It ends at another meta, a new
user/system turn, or the end of the chat. A meta with an empty segment is an
orphan record for a removed response message.

Direct `pt`, `ct`, `cct`, `rt`, and `tt` metadata records one inference. New
records carry an `inference_id`, which is used for exact deduplication; legacy
records fall back to conversational lineage and are marked accordingly. `meta
job=...` marks one response segment projected from an ask job and has no direct
token cost. The job's logs and dependencies contain the actual inference
metadata. Running `*_c` and `*_s` values are checkpoints and are not summed.

## Token count categories

These are typical token count categories. Not all are always available.

- pt: prompt tokens
- ct: completion tokens
- tt: total tokens
- cct: cache tokens (subset of prompt tokens)
- cwt: cache write tokens
- rt: reasoning tokens

When discussing tokens always consider that cache tokens are much less expensive in
general (about 10% of the normal cost).

## Society chats and legacy socialized projections

When a Manager or supervisor agent dispatches work to a specialist agent through
the `ask` tool with a named `conversation`, the specialist interaction is
persisted as a full chat of the society tree:

```text
<caller_job>.files/<name>.society/<AgentName>/<conversation>/agent.chat
```

The `<name>` component names the caller's own log (`agent.society` by
default, mirroring the agent's own log name, e.g. `worker.society`). These
files are the agent's full chats, including the tool calls and the direct
inference metadata of every model call, so they are counted directly by
`chat_tokens` and appear like any other chat of the session.

Older scout-ai wrote a different artifact for the same mechanism: a
**legacy socialized projection** (read for compatibility, never migrated) at

```text
<caller_job>.files/log/chats/<AgentName>/<conversation_name>.chat
```

These files are **projections**, not full agent logs. They contain the prompt,
propagated `option:` lines (including endpoint, model, backend, and potentially
credentials), a `meta: job=<path>` marker, and the assistant response — but they
carry **zero direct inference tokens**. The actual model calls and tool activity
are found by following the `meta: job=...` reference to the specialist's ask-job
and reading its `agent.chat` log and dependencies.

When inspecting a session that uses socialized agents, the legacy projection
files behave as follows (current society files behave like any other chat,
with their own inferences and tokens):

- Legacy projection files will appear in `chat_overview` with `tool_calls: N`
  reflecting only the calls visible in the projected segment, not the full set
  of calls in the underlying job.
- Legacy projection files will show `inferences: 0` and zero tokens in
  `chat_tokens` because they only carry a projection marker.
- The `chat_overview` edges connect legacy projections to their producer jobs via
  `result` edges and to the caller job via `log` edges.
- To find the real token usage and full tool-call count, follow the
  `meta: job=...` reference to the specialist's ask-job and inspect its
  `agent.chat` log (or the equivalent top-level log in the layout that job
  was saved with) and any nested dependencies (such as gather or
  pre-processing jobs).

Typical programmatic use:

    report = ChatAnalyst.job(:chat_report,
      file: '/path/to/session.chat').run

For command-line inspection of the same model, use:

    scout-ai llm prov /path/to/session.chat

Since the scout-ai provenance revamp (commit 3a37b24), the default tree
numbers every node with `evidence=`, a subtree-deduplicated closure of the
direct inference events reachable from that node; these values overlap between
siblings and ancestors and are never a per-part cost. Job nodes additionally
carry `delta=`, the direct totals of the job's persisted chat-typed result
(the accounting delta; deltas sum to the root total on continuation chains).
Both modes end with a root footer `deduplicated_total=<tt> (<N> events) ...`,
which is the one authoritative cost figure; with `--component` the per-node
numbers are relabeled `direct=` (per-component direct tokens) while the
footer stays authoritative.

Note that these logs are written automatically when workflows `ask` tasks are
used for inference and are defined using the function `chat_task` from the
`AgentWorkflow` mixin, and that they save societies recursively. Without a
surrounding `ask` `chat_task` these detailed logs will be lost, but agent
receipts (`agent_meta`) will still be available, containing some auditable
information.

## Delegated agent receipts (`agent_meta`)

When an agent requests help from another agent using `ask` (or a
`hand_off_to_*` tool), the `function_call_output` envelope may include an
`agent_meta` array carrying the delegated inference's meta records: direct
token records and, when the child ran as a `chat_task`, a `job=` reference to
the producing Step. These receipts make delegation auditable even when no
child chat or job was saved.

Receipt records are *embedded evidence*, not messages of the parent chat, and
are never added to the parent Chat Array. Provenance traversal follows their
`job=` references as `agent_job` edges, and token accounting counts their
direct events once, deduplicated by `inference_id` against any saved child log
that carries the same event. A receipt copy and a saved child-log copy of the
same event are two evidence locations for one paid inference; both stay
visible, the cost is counted once. Legacy receipts without an `inference_id`
are marked unresolved and may be over-counted when no child log exists.

# Tasks

## message_index
Return a compact index of every discovered message

The task traverses the whole session from the root chat and indexes every
persisted message in every discovered chat. Each entry carries a flat string
address (`"path#index"`), the message lineage ID and its previous lineage ID,
role, fingerprint, and truncated parsed metadata.

Use it first to see the size and shape of a session, or to obtain the addresses
that `message_content` can retrieve. The `role` input selects one role, and the
`page`/`per_page` inputs return a paginated envelope (`messages` plus
`page`, `per_page`, `total`, `total_pages`, `next_page`, `prev_page`) when the
index is too large for one response.

Embedded `agent_meta` receipts are **not** messages of the parent chat and are
therefore never listed here; use `meta_evidence` for those.
The `page`/`per_page` inputs paginate the message list without touching any
other field: totals and counts always cover the full session.

## message_content
Retrieve full content for selected indexed messages

Pass flat string IDs (`"path#index"`) returned by `message_index` or
`chat_tool_calls`. The task returns the persisted role and untruncated content
without compiling or executing the chat. It resolves real persisted message
addresses only; receipt evidence addresses belong to `meta_evidence` and
`chat_reasoning`.

## chat_overview
Summarize discovered chats, jobs, and typed provenance relations

The structural map of a session: one record per discovered chat (messages,
roles, visible `job=` references, tool-call count, receipt record count) and
per discovered job (workflow, task, status, dependency count, log count),
together with the typed edges between them (`job`, `dependency`, `log`,
`result`, `agent_job`) and aggregate counts.

`agent_job` edges are produced by delegated receipts: their `detail` carries
the call ID, tool name, output address, and receipt evidence address that
produced the link. The `totals` block also reports receipt-only events,
identity conflicts, and incomplete-evidence events. `warnings` lists malformed
receipts and provenance problems. Start here when orienting in an unknown
session; use `chat_tokens` for costs and `chat_agents` for delegation.

The `follow` input restricts traversal to a subset of core relations (for
example `job,log`); the default `all` keeps the previous behavior.

## chat_tool_calls
Compact index of function calls with retrievable addresses

The task pairs `function_call`/`mcp_call` messages with their
`function_call_output` by call ID. Each entry reports the tool name, call and
output addresses (`"path#index"`), success state with timestamps, and, for
agent-oriented calls, the target agent and conversation parsed from the
arguments.

For calls carrying a delegated `agent_meta` receipt, the entry includes an
`agent_meta` summary: receipt meta count, direct event IDs, receipt-only event
IDs, the receipt direct token total, referenced `job=` paths, unresolved
legacy receipt count, and any receipt warnings. Use `message_content` with the
call or output address for the full arguments and output text; the summary
never re-parses the output JSON.

Set `page` (optionally `per_page`) to paginate the call list; totals,
`by_tool`, and failure counts still cover every call. A session holds several
persisted copies of the same logical call — socialized projections under
`log/chats` (legacy), result chats, and job logs replay identical call ids and
arguments — so with `dedupe: true` every later copy is marked with `copy_of`
(the address of its first occurrence) and the result reports `copies` and
`unique_calls` alongside the raw `total`, which keeps counting every evidence
copy.

## chat_tokens
Deduplicated direct inference token usage with evidence locations

The authoritative cost report for a session. Each direct inference event is
counted once, keyed by `inference_id` (with the documented fallbacks for
legacy records), and every event keeps all of its evidence locations, so any
amount can be traced to the chat or receipt it was persisted in.

Read the totals as follows: `deduplicated_total` is the only global cost
total; `chat_evidence` and `receipt_evidence` are overlapping coverage scopes
and must never be summed; `receipt_only` is the disjoint delegated
contribution with no saved child chat/log — the part that was invisible before
receipts were accounted for. Job projection metadata and `*_c`/`*_s`
checkpoints are never counted as inference usage. Events flagged `conflict`
(disagreeing token fields or provider response IDs) are counted once from
canonical evidence, so a total containing conflicts is best-effort rather than
authoritative; `conflicts` and `incomplete_evidence` list those cases and
`warnings` collects discovery problems.

Set `page` (optionally `per_page`) to page through the event list; every
total (deduplicated, coverage scopes, receipt-only) still covers all events,
so a paginated call is a bounded cost summary.

## chat_agents
Agent interactions with receipt evidence and agent_job links

The task selects every delegation call — `ask`, `cortex_continue`,
`cortex_brief`, any `hand_off_to_*` tool — and, as a generic fallback, any
call whose `function_call_output` carries `agent_meta` receipt records, so
delegation tools from other suites are never silently missed. It reports,
per interaction: source chat, call ID, target agent (in the raw
`Agent/brief` form when present) and conversation when present in the
arguments, success state, the receipt summary (event IDs, receipt-only IDs,
receipt token total, referenced jobs), the matching `agent_job` edge
details, the linked producer Step, the child evidence classification
(`receipt_only`, `log_only`, `both`, `receipt_unresolved`, or `none`), and
the delegated cost rollup: `delegated_token_total` and
`delegated_event_count`, the deduplicated tokens of the events whose
canonical evidence lies in the union of the linked jobs' subtree chats.

Associations come exclusively from `agent_job` edge details recorded in the
receipt, never from path or agent-name conventions. Use this task to answer
"what did delegation cost and where did each delegated answer come from".

Set `page` (optionally `per_page`) to page through the interactions; the
`failed` count still covers all of them.

## meta_evidence
Unified meta evidence across ordinary messages and receipts

One list of every metadata record a session offers, with its origin:
`chat_meta` for a real persisted `meta:` message (address `meta_address`) and
`agent_meta` for a delegated receipt entry embedded in a
`function_call_output` (address `evidence_address`, plus `call_id`,
`tool_name`, and `output_address`). Each record includes the parsed meta
(truncated unless `full` is set, which also returns `raw_message` for
receipts), its classification (`direct`, `job_projection`, or `other`), the
job reference and inference/provider IDs when present, and receipt warnings.

Use it when the question is "where are all the metadata records and what do
they say", including reasoning summaries, without treating a receipt as a
parent-chat message.

## chat_reasoning
Reasoning fields from messages and delegated receipts

Returns every non-empty `reas=` reasoning field found by `meta_evidence`,
from both ordinary chat meta and delegated receipts, each with its provenance:
origin, address, inference and provider response IDs, timestamp, source, and
for receipts the call ID, tool name, linked `agent_job` Step, and whether the
event is receipt-only (no saved child log).

By default each item is compact: an MD5 fingerprint, an 80-character prefix
(and suffix for long fields), character count, and the evidence address. Pass
the selected addresses in `addresses`, or set `full`, to retrieve the
untruncated reasoning text for exactly those items. This two-phase pattern
keeps large reasoning traces out of reports until they are needed.

## chat_report
Return a concise combined session snapshot

The one-screen summary for a session: root, chat/job/edge counts,
`agent_job` edge count, the deduplicated and receipt-only token totals with
event counts, multi-evidence and conflict/incomplete counts, tool-call totals,
the first failures, up to three receipt summaries, warnings, and a delegation
block. The delegation block reports, per linked job, the tokens and event
count of its subtree chats (deduplicated, uniq by job), plus the root chat
tokens (canonical events in the root chat file and the root job's own
chats), the summed delegated tokens, `unattributed_tokens` (the remainder,
e.g. import-closure evidence), and `unresolved_jobs` from provenance
warnings that report an unresolved job reference. `deduplicated_total`
already includes resolved delegated subtrees; per-node subtree values may
overlap when several calls link the same job. The delegation block also
carries `malformed_edges`, the count of reference-less unresolved-receipt
warnings (malformed agent_job edges), which are kept out of
`unresolved_jobs` so that list stays strings-only. Use it as the first
answer to "what happened here", then drill into the dedicated tasks.

## provenance_relationships
Chat-level import, continue, and last reference events and import closure

Recover the fine-grained provenance relationships of any chat file. For each
`import:`, `continue:`, or `last:` line found in the uncompiled chat text the
task reports a reference event with type, raw reference, message index, and
resolved target (through the `Chat.find_file` resolution order). Unresolved
references are kept with `resolved: false` and an `unresolved_reason` instead
of raising. A `targets` summary collapses events per target with reference
counts and types, and `import_closure` lists the imported chats and the root
in post-order, handling cycles.

These references are not part of core provenance traversal, so this task is
the complement of the core provenance tasks: use it to know exactly which
chats a session imports, continues, or references with `last:`.

## chat_accounting
Separate accounting for a chat and every chat it imports

Account a chat and each chat of its import closure separately, from its own
file and with its own job/log provenance, so the root chat totals never absorb
the cost of imported chats. With the default `scope: own` the task returns one
entry per chat with messages, deduplicated token totals, token event count,
conflicts, incomplete evidence, tool calls, direct jobs, warnings, and the
list of imports (plus `unresolved_imports` when a reference cannot be
resolved). With `scope: closure` it merges all closure events with
`inference_id` deduplication into a single root entry, reporting token events
per chat. Each entry also splits its cost: `direct_tokens` are the canonical
events located in that chat file itself, while `delegated_tokens` (with the
`delegated_subtrees` job list) are the canonical events in `agent_job`
subtrees reachable from that chat. The existing `tokens` field keeps its old
meaning, which includes delegated subtrees whenever the `follow` option
resolves `agent_job` edges.

This is the task for the progressive-import use case: run it on the latest
chat of a chain and get the accounting of every previous chat separately. For
example, with the chain `doc_inconsistencies <- documentation_fix <-
provenance_issue`, running `chat_accounting` on `provenance_issue` returns one
entry for `documentation_fix` (its own events, its own totals, plus its
dangling `doc_inconsistencies` import under `unresolved_imports`) and one entry
for `provenance_issue`; the root entry keeps only its own cost, so no imported
chat is silently absorbed.
