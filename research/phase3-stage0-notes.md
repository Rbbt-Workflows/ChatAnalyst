# Phase 3 Stage 0 notes — native TSV facility pinned + reconnaissance closure

Bout: ChatAnalyst phase 3, bout 1 (PLAN STEP 1). Discovery only; no production
code changed. All writes in `research/` and `tmp/phase3-stage0/`.
Load path for every probe: `/home/mvazque2/git/scout-ai/lib` (bash spelling
`/bulk/mvazque2/git/scout-ai/lib`), fresh Ruby process per probe.

Provenance of consumed artifacts (sha256, receipt
`tmp/phase3-stage0/receipts/consumed-sha256.txt`):

```
c1d2f455c4f1d21a9a391758d88525ea35156c52411ce8e9809fa6b3817dee44  research/revision-report.md
c348b63a3027142ce241c74dfa5bfcd057798e335363d2e40a37187a0c6aa3ac  research/performance-notes.md
6d78d33c5458336b583b35172a6e1f76b4047ebffe72ad4aa6c7d8935d469a4e  research/redesign-report.md
4bd6f675ce1896610f1ac1743592fb4aa73ce917d9fe99d5ef6aa5ffd878ac07  research/stage0-notes.md
e24549a3a38966dcf25148af0536d3dabaa459c8aae7cfeb08966bf966b7c68c  lib/ChatAnalyst/api.rb
918ce0a38b6eef05bd1a56a03dab12f40a12aeb6cbb655f686af6e083ce8591c  lib/ChatAnalyst/tasks/api_tasks.rb
94eca8117b715afc392d4080f50a3636311f5c8e36149e6a577fd33a8bea49b7  start_chat
```

Probe receipts (all under `tmp/phase3-stage0/receipts/`): `probe-a.out`
(types/casts round-trip), `probe-b.out` + `probe-b2.out` (escaping),
`probe-c.out` (casts/nulls/DSL forms), `probe-d.out` (scalar options,
one2one, task persistence), `probe-e.out` (metadata routes),
`probe-f.out` (annotation append + parse_header + task persistence),
`probe-g.out` (module-level annotation DSL + task persistence),
`probe-h.out` (per-field cast), `probe-i.out` (annotation scope, nil in
list/double), `large-chats.txt` + `large-chat-load.txt` (rehearsal chat),
`consumed-sha256.txt`. Probe sources beside the receipts under
`tmp/phase3-stage0/`. Scratch task-persistence workflows `Phase3Probe`,
`Phase3ProbeF`, `Phase3ProbeG` live under `tmp/phase3-stage0/scratch*/`
(their job outputs landed in `~/.scout/var/jobs/Phase3Probe*`, disposable;
the ChatAnalyst workflow file was never touched).

Test baseline entering the bout (carried, not re-run): 174 tests / 821
assertions / 0 failures / 0 errors, receipt `tmp/rev-phase2/final-confirm.log`.

## 1. Pinned TSV API facts (all EXECUTED against the loaded library)

Library identity: `TSV.method(:setup).source_location` =>
`/home/mvazque2/git/scout-gear/lib/scout/tsv.rb:36`; `TSV.method(:open)` =>
same file line 75. TSV is a Module (probe B2); instances are Hash subclasses
carrying annotations. The class comes from the scout stack reached through
the pinned load path, as the standing facts state.

### 1a. Construction, dump, read-back; the `#:` metadata line

- `TSV.setup(data, type:, key_field:, fields:, cast:, **opts)` constructs;
  `TSV.open(file_or_io, ...)` reads; `TSV.parse_header(io)` returns a header
  object whose `.options` carries every `#:` directive (probe F).
- Dump format (probe A): ONE physical `#:` line joining directives with `#:`:
  `#: :cast=:to_i#:type=:list`, or with annotations
  `#: :max_gap_seconds=120#:page=3#:type=:list` (probe F/G). DIVERGENCE from
  the search-stage fact sheet ("each #: directive on its own line"): the
  dumper emits a single joined line and the parser accepts it.
- The four types round-trip cleanly as String data (probe A):
  - `:single` — key => scalar string;
  - `:list` — key => aligned per-field strings;
  - `:flat` — key => arbitrary number of strings in one field
    (dumped tab-joined, read back split on TAB at read time, `|` when
    sep2 applies);
  - `:double` — key => per-field arrays; genuinely nested multi-element
    fields round-trip (probe G: `[["a1","a2"],["b1"]]` verbatim).
- After reopen, `TSV#options` carries ONLY the framework keys
  (`:key_field, :fields, :type, :cast, :filename, :namespace, :unnamed,
  :identifiers, :serializer, :entity_options`) — custom Scalar options passed
  to `setup` do NOT reappear there (probes A, D).

### 1b. Casts

- Cast syntax pinned: GLOBAL SYMBOL ONLY. `cast: :to_i` / `cast: :to_f`
  persists as `#: :cast=:to_i` and applies on read-back with correct classes
  (probe A/D: `"42"` => `42`).
- Per-field Hash cast (`cast: {N: :to_i}`) is ACCEPTED at setup but silently
  dropped: nothing in the `#:` line, `back.cast == nil`, values stay Strings
  (probe H). Never use it; it is a silent-data-shape trap.
- GLOBAL CAST APPLIES TO EVERY FIELD (probe D): a `:list` table
  fields `[Role, Count]` with `cast: :to_i` loads as `{"m1"=>[0, 10]}` —
  the Role string "user" became Integer 0. Contract consequence: only
  tables whose EVERY field is numeric may cast; mixed tables keep Strings
  and the contract documents the string encoding.
- Numeric guard (probe C): under `:to_f`, the text `NaN` => `0.0` and `Inf`
  => `0.0`; under `:to_i`, `abc` => `0`. Empty cell under cast => `nil`.
  The search-stage NaN warning is confirmed and extends to any non-numeric
  text: cast never raises, it zeroes.

### 1c. Key/cell escaping — what the native facility holds

Executed with proper scalar assignment (probe B2; probe B's first pass used
array assignment under `:single`, which was the wrong shape and is retained
only as evidence that mis-assignment stores raw strings):

- Round-trip VERBATIM in keys AND scalar cells: `%`, `#`, `~`, `|`, `,`,
  space, backslash, double quote, CR. Real-world shapes confirmed:
  `/home/u/a b/c#3`, `/home/u/a%25b#12`, `~/.scout/x#0`.
- CANNOT be held: TAB (splits into fields), NEWLINE (splits into rows).
- Multi-value contexts add one constraint: `|` is the sep2 join on dump, so
  a value inside a `:flat`/`:double`/list-multi field cannot contain `|`
  verbatim (probe B/G: `a|b` splits); a custom read-side `sep2` does not
  change what the dumper writes (probe H `sep2: ','` dumped tab-joined and
  read back split on TAB).

ESCAPING-SCHEME IMPLICATION (spec requirement: identifier round-trip for
paths containing %, #, tab, newline):

1. `%25`/`%23` escaping is required ONLY by the message-ID grammar (the
   final `#` separates path from index). TSV capacity does not force it:
   both raw and escaped forms round-trip.
2. The scheme MUST extend beyond `%25`/`%23` to TAB (`%09`) and NEWLINE
   (`%0A`): the native facility cannot hold those characters in any key or
   cell, so without the extension such identifiers cannot round-trip at all.
   (CR round-trips verbatim but should be encoded too for line-safety
   symmetry; decision for the freeze bout.)
3. Because cells hold only controlled values per the spec, the `|` constraint
   is a documented invariant (no `|` inside any multi-value cell), not a
   blocker.

### 1d. Scalar options / metadata line — the pagination + scope mechanism

Three candidate routes executed (probes D, E, F, G):

- Extra options in a hand-written `#:` preamble or `to_s(options)` or a
  replaced `@annotations` array: the directives are WRITTEN, but
  `TSV.open(...).options` does NOT expose them (probes D, E). Only
  `TSV.parse_header(io).options` recovers them, typed (probe F:
  `{:max_gap_seconds=>120, :page=>3, :root_path=>"/tmp/a b.chat"}`).
- `TSV.setup(..., annotations: [...])` RAISES `NameError: uninitialized
  constant TSV::ANNOTATION_TYPES` (probe E) — dead end, do not use.
- MODULE-LEVEL DSL (probe G) — DECIDED MECHANISM:

  ```ruby
  TSV.annotation :page, :per_page, :total, :total_pages, :next_page,
                 :prev_page, :root_path, :max_gap_seconds, :one2one
  tsv.page = 3; tsv.root_path = '...'   # Scalar values
  ```

  Dumped into the `#:` line; recovered by BOTH `TSV.open` (via the defined
  accessors, `options[:page] => 3 (Integer)`) AND task persistence
  (`Step#load.load.options[:page] => 3`, probe G) — the only route that
  survives both surfaces without hand parsing. `TSV.parse_header` remains
  the belt-and-braces reader for any consumer that got the file without the
  registration (probe F recovered page/total/root_path from a persisted job
  file).

  Constraints pinned (probes G, I): values must be Scalars (Setter needs the
  name registered first — unregistered `root_note=` raises NoMethodError);
  no TAB/NEWLINE inside annotation strings (the `#:` line is one physical
  line); registration is process-global so every TSV instance gains the
  accessors, but instances that never set them dump CLEAN (probe I: the
  plain table's dump had no `#:` pollution and its reopen was clean) — the
  global registration is therefore harmless for unrelated tables.

- Pagination metadata (page, per_page, total, total_pages, next_page,
  prev_page) and cluster scope (root_path, max_gap_seconds) will ride this
  mechanism. `next_page`/`prev_page` set to nil simply omit themselves from
  the `#:` line (probe F wrote them nil; they were absent) — absent means
  nil, which is the correct "no next page" encoding.

### 1e. one2one — DECIDED

Executed (probes D, G): no `one2one` option reaches the dump bytes; after
reload `options[:one2one]` is nil even when the value was set, and an
explicit `one2one: true` at open produces values IDENTICAL to a plain
`:double` open. one2one is an attach/traverse option, not a persisted type
annotation — the search-stage discrepancy is RESOLVED in favor of "not
persisted".

DECISION (candidate (a) of the work order): aligned one-value-per-field
relations are `:list` tables whose fields align by construction
(`chat_references`, `chat_role_counts`, `chat_token_evidence`), with the
alignment contract documented in each task desc and the README. `:double` is
reserved for genuinely nested multi-value fields. Rationale: `:list` is the
type whose in-memory shape is exactly one aligned value per field; inventing
a `#: :one2one=true` convention that only our own writer/reader pair honors
would be a silent private convention, which the spec forbids. (If the freeze
bout prefers a visible marker anyway, the module-annotation route CAN carry
`one2one=true` through both surfaces — probe G proved `options[:one2one]`
round-trips as TrueClass — but it would still be OUR convention, not a
native type.)

### 1f. Task-typed persistence

Executed through disposable scratch workflows (probes D, F, G): a
`task :x => :tsv` block returning a TSV persists the `#:` line + rows;
`step(:x).load` (and `Step#load.load`) returns the Hash with
`type/key_field/fields/cast` intact and casts applied. With the
module-annotation route the extra metadata also survives `Step#load`
(probe G: `options[:page]=3 total=123 root_path=... one2one=true` after
load). A `dep`-chained TSV dependency therefore loads back with metadata
intact, which is what the spec's task-dependency rule needs.

### 1g. Null convention — candidates recorded, decision belongs to freeze

Executed (probes C, I):

- `:single`: a row whose value cell is ENTIRELY ABSENT reads back `nil`; an
  EMPTY cell reads back `""` — a native, explicit distinction, but only
  expressible for the final field of a row.
- `:list`: a nil element degrades to `""` on read-back; `:double`: a nil
  element degrades to `[]`. No native null inside multi-field rows.
- Under cast, an empty cell reads back `nil` (distinct from the zeroing of
  non-numeric text, 1b).

Candidates for the contract: (a) rely on the absent-trailing-cell/empty-cell
asymmetry where the shape allows it; (b) an explicit sentinel string in
String columns (SQL-style `\N` or similar), documented in the README — needed
for any null inside `:list`/`:double` rows; (c) for cast numeric columns,
native empty-cell=>nil. Recommendation (not a decision): (b) for text
columns + (c) for numeric + document that `""` always means empty string,
never null. REQUIRED at the freeze bout.

## 2. Reconnaissance closure

### 2a. Operational task internals read for phase 3

- `chat_accounting` (workflow.rb:137): chat-root-only; `scope` `own` (each
  closure chat accounted separately, direct vs delegated token split by
  canonical evidence source) vs `closure` (one merged root entry);
  single-pass memoized fetch per chat (relationships + tokens + overview
  computed once per chat per response). TSV conversion must preserve: the
  chat-root-only guard, both scopes, the once-per-chat composition, and the
  direct/delegated split columns.
- `live_chats` (workflow.rb:428): three discovery sources — settled
  traversal (`live_chat_files`), in-flight `.jobs` sidecar entries
  (delegations invisible to settled provenance), glob fallback; settled
  wins over `.jobs` for the same file; entries newest-first with mtime/age/
  size, `likely_active` flag on the first entry, per-entry `source`
  (traversal mode or `:jobs`), and for a job root a status block
  (status/running/done/error/aborted/started). Vanishing-chat races are
  skipped, never raised. TSV conversion must preserve: all three sources and
  their precedence, the likely-active flag, the fail-soft behavior, live
  file tolerance (mutable logs are read best-effort).
- `inbox_state` (workflow.rb:496): chat-root-only; pending (inbox dir) and
  delivered (removed dir) with FULL NOTE CONTENTS embedded; missing
  directories are empty lists, never errors; list/read race skips the entry.
  Phase-3 change: index-only (name, mtime, size — no bodies); bodies move to
  the new `inbox_note(note_id)` plain-text task. Preserve: chat-root guard,
  empty-not-error, race tolerance, the canonical dir derivations via
  `Chat.inbox_dir` / `Chat.inbox_removed_dir`.
- `post_inbox_advice` (workflow.rb:535): chat-root-only; name must be a
  plain file name (no `/`); message must be non-empty; the reserved abort
  filename (`Chat::INBOX_ABORT_FILE`, 'abort') is REJECTED before any write;
  no-overwrite on an existing note; default timestamped `-advice.md` name;
  result records posted path, name, size and the delivery semantics note.
  TSV conversion must keep every safeguard and the small result row shape.
- `chat_live_report` (new task per spec): core is
  `Chat.live_report(save_file, captured:)` at
  scout-ai `lib/scout/llm/chat/provenance/live.rb:519` — sidecar pass with
  dependency expansion (`expand_live_jobs`), captured-id folding, entry
  kinds (:inference, :workload_context, :agent_activity, :dangling_job),
  dedup by job id; `ChatAnalyst.live` (api.rb:~514) wraps it fail-soft and
  strips transient `:step` objects to plain strings. NO workflow task
  exposes it today; the spec adds one. Keep it separate from `live_chats`
  file discovery exactly as the spec says.

### 2b. Reference kinds: core surface vs spec enumeration

Core `Chat.provenance_graph` (scout-ai provenance.rb:280, doc block :258)
returns exactly: `chats` (message index => resolved canonical JOB path, from
`meta: job=` and agent_meta receipts), `dependencies` (job's direct
Step#dependencies canonical paths, declared order), `delegation` (ask
tool-call index => `<agent>#<conversation>`), `live` (supplementary sidecar
chat paths — explicitly NOT authoritative provenance nodes), `warnings`.
Message-level reference events come from `ChatAnalyst.relationship_references`
(api.rb:899): roles `import`, `continue`, `last`, each resolved via
`Chat.find_file` with remote/missing unresolved reasons.

Mapping to the spec's `reference_type` [job_reference/delegation/import/
continue/last]:

| spec reference_type | core counterpart | note |
|---|---|---|
| `job_reference` | `graph[:chats]` | index => canonical job path |
| `delegation` | `graph[:delegation]` | ask call index => agent#conversation |
| `import` | relationship_references role `import` | closure walker exists (import_closure_of) |
| `continue` | relationship_references role `continue` | message-level |
| `last` | relationship_references role `last` | message-level |

No spec name lacks a core counterpart. Two core kinds deliberately do NOT
become chat_references rows: `dependencies` (belongs to the job_dependencies
relation, spec A) and `live` (mutable work in flight, discovery surface for
live_chats, not provenance). This is a freeze-bout input: confirm both
exclusions.

### 2c. Consumer set of the current JSON tasks

Unchanged from research/stage0-notes.md §1. Quick sweep this bout: zero
references to `ChatAnalyst.` in scout-ai / scout-gear / scout-essentials
libs; zero non-test/non-research/non-tmp in-repo consumers of the current
task names; the only hits outside the checkout are historical Planned job
artifacts under AgentSuite/Research/var (chat transcripts of past sessions,
not code consumers). The only real consumer remains the ChatAnalyst agent
itself.

### 2d. Largest real chat for the rehearsal

Receipts `tmp/phase3-stage0/receipts/large-chats.txt` and
`large-chat-load.txt`:

- LARGEST: `/home/mvazque2/.scout/var/jobs/Planned/work/Default_4e19a1bc1a38e6c83ce393c236b99c29.chat.files/Manager.society/ScoutCoder/chatanalyst-redesign/agent.chat`
  — 3128 messages, 6,590,242 bytes; roles: function_call=1035,
  function_call_output=1035, meta=1034, tool=7, user=6, system=4.
- The phase-2-era Critic chat: `.../Default_4e19a1bc1a38e6c83ce393c236b99c29.chat.files/Manager.society/Critic/default/agent.chat`
  — 1151 messages, 1,410,623 bytes; meta=378, function_call=377,
  function_call_output=377.
- Also loaded fine: the 66-message 4 MB Manager chat (large bodies, few
  messages — useful as the big-cell stress case).

## 3. Settled decisions (this bout)

1. one2one mechanism: `:list` with alignment-by-construction + documented
   contract (1e). Native persistence does not exist; no private convention
   invented.
2. Escaping scheme implication: extend to `%09`/`%0A` (TAB/NEWLINE) —
   mandatory for the required identifier round-trip; `%25`/`%23` are
   grammar-driven, not capacity-driven (1c).
3. Pagination/scope metadata mechanism: module-level `TSV.annotation` DSL,
   read via `TSV#options` after open/`Step#load`; `parse_header` as the
   registration-free fallback reader (1d). Scalar-only, no TAB/NEWLINE in
   annotation strings; absent directive means nil (correct for
   next_page/prev_page).
4. Cast syntax: global `:to_i`/`:to_f` Symbol only; per-field Hash cast is
   a silent trap and is banned; global cast hits every field so only
   all-numeric tables may cast (1b).
5. sep2: read-side only; the dumper always rejoins multi-values with the
   default — custom sep2 does not survive a round-trip as a convention
   (1c/1h probes). Cells must not contain `|` in multi-value contexts.

## 4. Decisions required at the contract-freeze bout

1. Null convention (1g): sentinel string vs absent-cell asymmetry vs
   cast-nil; recommendation recorded, final call open.
2. Confirm exclusion of `dependencies` and `live` from chat_references
   reference_type rows (2b).
3. Whether CR also gets a `%0D` escape for line-safety symmetry (1c).
4. Mixed-type tables stay all-Strings (cast ban consequence, 1b) — confirm
   the string encoding of numeric columns in mixed tables (e.g. counts as
   decimal strings) is acceptable for the analytical surface.
5. Summary-counts placement (overview vs cluster-index metadata) — the spec
   leaves it as an implementation decision to record; not resolved here.

## 5. Divergences from the search-stage fact sheet

1. "each #: directive on its own line" — the dumper emits ONE joined line
   (`#: :cast=:to_i#:type=:list`); the parser accepts it (1a).
2. "cast is an open option" — true only for the global Symbol form;
   per-field Hash casts are accepted then silently dropped (1b, probe H).
   The fact sheet did not distinguish.
3. "non-Scalar options do not survive dump/reload" — confirmed, and
   extended: even SCALAR options passed to `setup` do not survive into
   `TSV#options`; the module-annotation DSL is the only route that
   round-trips Scalars through both dump and task persistence (1d).
4. one2one discrepancy RESOLVED: not persisted; decision (a) adopted (1e).
5. "cast :to_f turns NaN into 0.0" — confirmed; additionally ANY non-numeric
   text zeroes under cast, and empty cells become nil under cast (1b).
6. "TSV.open(tsv) re-materializes a copy" — consistent with observed
   behavior (every open returns a fresh Hash instance; no TSV.get exists).

## 6. Core improvement ideas (recorded, NOT acted on — scout-ai stays unchanged)

- Per-field cast persistence (the `#: :cast=` line could carry a Hash form).
- A native null sentinel honored by list/double readers.
- sep2 symmetry (dump honoring the table's sep2 instead of always `|`).
- `TSV.setup(annotations:)` raising `NameError` on an uninitialized constant
  is an opaque failure mode; a clear exception would help.
