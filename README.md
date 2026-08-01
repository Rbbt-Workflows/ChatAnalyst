Inspect Scout-AI sessions, their lineage segments, producer jobs, agent logs, tool calls, and direct token usage without replaying them.

ChatAnalyst reads persisted chats with `Chat.load`, follows `import`, `continue`,
and `last` references, and traverses every job referenced by `meta job=...`.
For each job it follows persisted dependencies, chat results, and all
`.files/log/**/*.chat` files — including the regular `log/agent.chat` logs and
the socialized chat projections under `log/chats/<AgentName>/<conversation>.chat`.

A meta message starts a response segment. The segment can contain several tool
calls, tool outputs, and an assistant message. It ends at another meta, a new
user/system turn, or the end of the chat. A meta with an empty segment is an
orphan record for a removed response message.

Direct `pt`, `ct`, and `tt` metadata records one inference. `meta job=...` marks
one response segment projected from an ask job and has no direct token cost.
The job's logs and dependencies contain the actual inference metadata. Running
`*_c` and `*_s` values are checkpoints and are not summed.

## Socialized chat files

When a Manager or supervisor agent dispatches work to a specialist agent through
the `ask` tool with a named `conversation`, the specialist interaction is
persisted as a socialized chat file at:

```text
<caller_job>.files/log/chats/<AgentName>/<conversation_name>.chat
```

These files are **projections**, not full agent logs. They contain the prompt,
propagated `option:` lines (including endpoint, model, backend, and potentially
credentials), a `meta: job=<path>` marker, and the assistant response — but they
carry **zero direct inference tokens**. The actual model calls and tool activity
are found by following the `meta: job=...` reference to the specialist's ask-job
and reading its `agent.chat` log and dependencies.

When inspecting a session that uses socialized agents:

- Socialized chat files will appear in `chat_overview` with `tool_calls: N`
  reflecting only the calls visible in the projected segment, not the full set
  of calls in the underlying job.
- Socialized chat files will show `inferences: 0` and zero tokens in
  `chat_tokens` because they only carry a projection marker.
- The `chat_overview` edges connect socialized chats to their producer jobs via
  `result` edges and to the caller job via `log` edges.
- To find the real token usage and full tool-call count, follow the
  `meta: job=...` reference to the specialist's ask-job and inspect its
  `agent.chat` log and any nested dependencies (such as gather or pre-processing
  jobs).

Typical programmatic use:

    report = ChatAnalyst.job(:chat_report,
      file: '/path/to/session.chat').run

For command-line inspection of the same model, use:

    scout-ai llm info /path/to/session.chat

# Tasks

## message_index
Return a compact index of every discovered message

Each result includes a file/index ID for retrieval, the message lineage ID,
its previous lineage ID, role, fingerprint, and parsed metadata when present.
Use the optional `role` input to select one message role.

## message_content
Retrieve full content for selected indexed messages

Pass IDs returned by `message_index`. The task returns the persisted role and
untruncated content without compiling or executing the chat.

## chat_overview
Summarize discovered chats, jobs, and provenance relationships

The result lists role and message counts, producer-job references, tool-call
counts, Workflow dependencies, agent-log counts, and import, result,
dependency, and log edges.

## chat_tool_calls
Analyze function calls and their outputs

The task pairs `function_call` or `mcp_call` messages with
`function_call_output` messages by call ID. It reports tool names, output
positions, and success or failure when an exception or non-zero exit status is
recorded.

## chat_tokens
Report direct token usage across the lineage trace

The task counts each direct metadata segment once using `pt`, `ct`, and `tt`.
It reports per-file values and an aggregate across all discovered chats. Job
projection metadata and cumulative/session checkpoints are not counted as
independent inference usage.

## chat_agents
List agent-oriented tool interactions

The task selects calls named `ask` or `hand_off_to_*` and reports their source
file, call ID, output position, and success state.

## chat_report
Return a compact combined session report

The result combines session size, job count, aggregate direct tokens, trace
record count, the first tool-call records, failures, and discovery warnings.
