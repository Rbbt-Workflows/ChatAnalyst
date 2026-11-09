# Performance notes — plan step 7 measurements (token accounting, timeline freshness)

Measurement-only revision. No behavior changed: nothing outside
`tmp/rev-measure/` and this file was written, and no lib/, workflow.rb,
test/, README.md or start_chat path was touched (a concurrent bout is
editing those; verified at the end of this bout by listing what this bout
created). The test suite was NOT run (shared fixed `@__test_dir` would
collide with the concurrent bout's runs).

## 1. Question and decision supported

Plan step 7 quantifies two candidate costs in the ChatAnalyst public API
(`lib/ChatAnalyst/api.rb`, phase 1 complete, unchanged here):

1. **Token accounting cost** — `ChatAnalyst.tokens` runs
   `Chat.provenance_token_events` once plus `Chat.provenance_token_totals`
   once per scope (4 scopes) plus one more totals call for conflicts.
2. **Timeline cache-freshness cost** — `timeline_freshness_identity`
   hashes the content of every reachable chat/job file on EVERY timeline
   call, including cache hits.

Decision supported: whether either cost is material enough to justify a
change. A scout-ai core change (single-pass totals, digest caching) is OUT
OF SCOPE for this project — any such change is a scout-ai-repo follow-up
decision, not this project's. The deliverable is this report with a
keep/change recommendation for each area.

## 2. Methodology

- **Runtime pin.** Every probe is a fresh child process with
  `$LOAD_PATH.unshift('/home/mvazque2/git/scout-ai/lib')` — the installed
  scout-ai 2.0.0 gem predates the provenance APIs (the checkout's test
  canary asserts `Chat.respond_to?(:provenance_graph)`). Ruby 3.3.1.
- **Instrumentation.** Module-level monkey-patch counters/timers around
  `Chat.provenance_token_events`, `Chat.provenance_token_totals`,
  `Chat.provenance_graph`, `Chat.traverse_provenance`,
  `Chat.provenance_closure`, `Chat.provenance_chat_files`,
  `Chat.provenance_chat_load`, and
  `ChatAnalyst.timeline_file_digest` / `ChatAnalyst.timeline_freshness_identity`,
  defined INSIDE each probe process only. `lib/` was never edited; the
  patches wrap the original methods (`alias_method` + call-through), so
  behavior is unchanged and only counts/timings are added.
- **Fixtures.** Synthetic persisted-layout trees under
  `tmp/rev-measure/fixtures/` built by `tmp/rev-measure/build_trees.rb`
  following the same conventions as `test/scout/agent_meta_fixtures.rb`
  (receipt chats via `meta:` envelopes with `job=` references, job
  `.files/agent.chat` logs, `.info` sidecars with dependencies). Three
  trees: small (1 chat), mid (1 parent + 3 worker jobs + 1 dep + nested
  receipt; 4 chats), large (1 parent + 20 worker jobs + 4 deps; 21 chats).
  Scaling trees for freshness: parent + 5/20/50 worker logs under
  `tmp/rev-measure/scale/`.
- **Repeats.** N=5 per measurement, one measurement per fresh process;
  medians and min/max spread reported. `GC.start` before each repeat.
  Repeatability check: three additional fresh processes re-measured the
  large-fixture tokens median at 0.282–0.316 s and the timeline hit at
  0.021 s (`logs/replay_tokens_large.log`).
- **Machine caveats.** Single shared multi-user host (bulk ext4
  filesystem), no CPU pinning; absolute wall times carry ±10% run-to-run
  variation (see replay log), relative shares are stable. Process load
  cost (Ruby + scout-ai boot) is EXCLUDED from all numbers: timing starts
  after load, around the measured call.

## 3. Measurement 1 — token accounting cost

### 3.1 Call counts per one `ChatAnalyst.tokens` call (instrumented, not from comments)

All three trees, first repeat, from `logs/tokens_<tree>.log`
(`first-repeat counts:` lines):

| core entry point | small | mid | large |
|---|---|---|---|
| `provenance_token_events` (top-level calls) | 6 | 6 | 6 |
| `provenance_token_totals` | 5 | 5 | 5 |
| `provenance_chat_files` → `provenance_closure` → `traverse_provenance` | 6 / 6 / 6 | 6 / 6 / 6 | 6 / 6 / 6 |
| chat file loads (run-cache MISS: real `Chat.load`) | 1 | 4 | 21 |
| chat load run-cache HITS | 17 | 68 | 357 |

Reading: exactly **6 traversals per tokens call** — the events call (1) +
4 per-scope totals calls + 1 conflicts totals call, each running its own
`provenance_closure`. The code's comment ("~6 core calls") is confirmed by
instrumentation, not by the comment. The `with_provenance_run_cache`
wrapper makes the CHAT PARSING effectively single-pass across those 6
traversals (21 real loads vs 357 cached lookups on large): the repeated
work per traversal is graph/edge/collection logic, not file re-parsing.

### 3.2 Wall time per `ChatAnalyst.tokens` call (N=5, median [min, max], seconds)

From `logs/tokens_<tree>.log`:

| tree | chats reachable | token events | median wall | spread |
|---|---|---|---|---|
| small | 1 | 1 | 0.0067 [0.0067–0.0071] | 0.0005 |
| mid | 4 | 17 | 0.0377 [0.0375–0.0410] | 0.0035 |
| large | 21 | 193 | 0.3556 [0.3468–0.3685] | 0.0218 |
| scale/c50 (parent + 50 logs) | 51 | 483 | 0.6928 [0.6904–0.7239] | 0.0335 |

(`logs/tokens_c5.log`: 0.0684 s @ 6 chats; `logs/tokens_c20.log`:
0.2605 s @ 21 chats — consistent linear-in-chats growth.)

### 3.3 Phase breakdown: events pass vs per-scope totals vs conflicts

From `logs/tokens_breakdown_<tree>.log` (median repeat of 5; each phase's
column sums the phase's core calls):

| tree | events pass | totals ×4 scopes | conflicts pass | total instrumented |
|---|---|---|---|---|
| small | 0.0008 s (10.2%) | 0.0055 s (~72%) | 0.0014 s (17.9%) | 0.0076 s |
| mid | 0.0066 s (8.8%) | 0.0529 s (~71%) | 0.0153 s (20.5%) | 0.0748 s |
| large | 0.0524 s (8.0%) | 0.4699 s (~71%) | 0.1347 s (20.5%) | 0.6562 s |

Each of the four per-scope totals passes costs ≈ 2× the events pass
(e.g. large: events 0.0524 s; per-scope totals 0.109–0.159 s each),
because one totals call = the events collection PLUS the scope selection,
both full re-traversals). Net:
**the events pass is ~8–10% of the call; the 5 extra totals traversals
are ~90%**, split ~71% across the 4 scope totals and ~20% for the
conflicts pass.

Cross-check (`logs/tokens_core_share_<tree>.log`, depth-tracked so the
nested events call inside each totals call is counted once): the share of
total wall time spent inside the core token API calls is 39.5% (small),
89.8% (mid), 98.6% (large), 99.2% (c50) — i.e. at real scales essentially
all of the tokens cost is the core's repeated traversals, and
ChatAnalyst-side serialization is negligible.

### 3.4 Scale-limit statement

Fixtures are small (1–51 chats). Growth is linear in reachable chats
(~13 ms/chat at this shape: 0.0067→0.6928 s over 1→51 chats). Extrapolating
to production trees with ~500 chats would put one `tokens` call around
6–7 s under the current 6-traversal shape; the run cache keeps parsing
single-pass, but collection logic is re-executed 6×. A production-scale
extrapolation would require: measuring on a real production tree (the
only available real trees here are the tiny Planned-job fixtures under
`~/.scout/var/jobs/Planned/…`, ≤6 chats), and separating traversal cost
from event-collection cost at that shape. Single-pass totals is a
scout-ai core API change (`Chat.provenance_token_totals` re-derives events
per call by design) — a scout-ai-repo follow-up decision.

### 3.5 Recommendation — token accounting: **KEEP (no change in this project)**

- At fixture scale the whole call is 7–700 ms; the 5 redundant traversals
  cost ~90% of that but the absolute numbers are immaterial for the
  interactive report use case (one call per report generation).
- The cost is linear and modest per chat; it only becomes material at
  ~hundreds of chats, which no consumer currently exhibits.
- The redundancy is core-by-design (`provenance_token_totals` calls
  `provenance_token_events` internally; the API deliberately does not
  accept a precomputed events list). Removing the 5 redundant traversals
  from ChatAnalyst's side is possible (compute events once, derive the
  four scope selections + conflicts locally — all selection rules are
  public core semantics: `event[:evidence]` origins, `event[:conflict]`,
  `event[:incomplete_evidence]`), and would cut the call to ~1/6 of its
  current cost. That is a behavior-preserving local optimization, but it
  duplicates core selection semantics in ChatAnalyst, and the current
  cost does not justify the duplication now. If a consumer with hundreds
  of reachable chats appears, prefer asking scout-ai for a
  totals-from-events API over local re-derivation.

## 4. Measurement 2 — timeline cache-freshness cost

### 4.1 Freshness identity alone (N=5, median [min, max], seconds)

From `logs/timeline_<tree>.log` (`== timeline_freshness_identity alone ==`
blocks):

| tree | reachable chats | digest calls (identity run) | digested bytes | median identity time |
|---|---|---|---|---|
| small | 1 | 1 (per identity run: 5 over 5 runs) | 99 B/chat | 0.0004 [0.0003–0.0017] |
| mid | 4 chats + 5 jobs | 9 per identity (45 over 5 runs) | 1,816 B | 0.0029 [0.0029–0.0045] |
| large | 21 chats + 24 jobs | 49 per identity (245 over 5 runs) | 9,596 B | 0.0163 [0.0162–0.0185] |

Digest-call counts confirm the design: one SHA256 per visited chat, one
per visited job result + one per job `.info`, per identity run. The
identity traversal also re-runs `Chat.provenance_graph` over every node
(that work dominates the digest cost — 49 digests of ~200 B files hash in
well under a millisecond; the ~16 ms is graph+load machinery, not hashing).

### 4.2 Cold vs cache-hit timeline call (N=5, median, seconds)

From `logs/timeline_<tree>.log` (`== cold vs cache-hit timeline ==`):

| tree | cold timeline | cache-hit timeline | freshness share of hit |
|---|---|---|---|
| small | 0.0049 | 0.0040 | 8.1% |
| mid | 0.0102 | 0.0071 | 47.8% |
| large | 0.0397 | 0.0216 | 80.9% |

Instrumented digest counts during the hit call equal the cold call's
(large: 49 digests, 9,596 B both) — i.e. a cache hit re-does the ENTIRE
identity traversal (graph per node + digests) and then serves the cached
result; the ~2× cold/hit ratio is exactly the avoided build+serialize.

### 4.3 Freshness scaling with reachable chats (synthetic 6/21/51-chat trees)

From `logs/timeline_scale.log` (median of 5 per point):

| chats (parent + worker logs) | digest calls per hit | digested bytes | freshness alone | cache-hit timeline | freshness share of hit |
|---|---|---|---|---|---|
| 6 | 11 | 1,586 | 0.0035 | 0.0074 | 47.6% |
| 21 | 41 | 6,101 | 0.0128 | 0.0171 | 74.9% |
| 51 | 101 | 15,191 | 0.0324 | 0.0369 | 87.9% |

Freshness cost is linear in reachable chats (~0.6 ms/chat here) and
asymptotically dominates the hit call: at 51 chats the cache hit costs
nearly as much as a cold build minus parse. The hash share of that cost is
tiny (15 KB hashed ≈ 0.05 ms); the cost is the per-node
`Chat.provenance_graph` re-execution (job resolution, agent_meta receipt
parsing, tool_call scanning) that the identity traversal performs.

### 4.4 Scale-limit statement

At fixture scale even the largest tree's identity is 16 ms. The share
grows linearly and would pass 90% around ~100 chats; a production tree
with ~500 chats would spend ~0.3 s per timeline call on freshness alone.
That is still small against a cold build of the same tree (the identity
spares the bout construction and serialization). Honest caveat: the
identity's correctness depends on hashing file CONTENT (any append to any
reachable chat invalidates), so a cheaper mtime-based identity would
change invalidation semantics (mtime granularity) — not measured here.

### 4.5 Recommendation — timeline freshness: **KEEP (no change in this project)**

- The design goal — correct invalidation on any reachable-file content
  change — is met, and the cost is 0.4–33 ms at all measured scales.
- The cache still pays: a hit is ~2× cheaper than cold at 21 chats and
  remains cheaper at 51 (0.037 vs a cold build that would be ~0.06+ s at
  that shape). The hit-path identity traversal is the price of
  content-identical correctness.
- If a consumer iterates timeline over trees with hundreds of chats in a
  tight loop, the in-process cache key could gain an mtime/size
  short-circuit BEFORE the full identity traversal (cheap stat-only
  pre-check; fall back to content digests on any mismatch). That is a
  local ChatAnalyst change, no core involvement — but again, current
  absolute costs do not justify it now. Content-hash-on-every-call in the
  freshness identity itself is scout-ai-independent (it lives in
  ChatAnalyst), so this remains an available local lever, deliberately
  not pulled.

## 5. Deviations and measurement failures

- **Breakdown probe mirrors the call shape, not the method.**
  `probe_tokens_breakdown.rb` reproduces the six-phase structure of
  `ChatAnalyst.tokens` (events + 4 scopes + conflicts, each in its own
  `with_provenance_run_cache` block) rather than calling the method
  itself, because per-phase timing requires interleaved phase labels a
  wrapper around the single method cannot supply. Its instrumented total
  (large: 0.6562 s) is ~1.8× the method's wall time (0.3556 s) — the
  mirror opens a FRESH run-cache block per phase while the real method
  keeps ONE cache for all six phases, so chat loads are re-served from
  cache in the real call but partially re-parsed in the mirror. The
  per-phase SHARES are still valid (each phase's share of its own run's
  total, stable across repeats), but treat the mirror's absolute totals
  as an upper bound. The shares agree with the independent core-share
  probe (§3.3 cross-check).
- **`probe_tokens_eventshare.rb` first version double-counted** nested
  calls (a totals call internally invokes provenance_token_events; the
  inclusive timer summed both). Reported shares >100% exposed it; the
  fixed version depth-tracks and counts each nested events call once via
  its totals wrapper. Only the fixed version's logs are kept
  (`logs/tokens_core_share_*.log`).
- **Fixture trees are synthetic, not production trees.** The only real
  persisted trees reachable from this checkout are the Planned workflow's
  own job chats under `~/.scout/var/jobs/Planned/…` (≤6 chats) — too
  small and not representative of agent-run delegation depth, so
  synthetic trees following the documented persisted-layout conventions
  were built instead. Scale conclusions are bounded by that.
- **Git is broken in this checkout**, so no diff-based footprint
  verification was possible; footprint was verified by construction (all
  writes went to `tmp/rev-measure/` and this file) and by listing the
  created paths.
- **The test suite was not run** (work-order constraint: shared fixed
  `@__test_dir` would collide with the concurrent bout's runs). No
  behavior changed, so no test outcome is affected by this bout.

## 6. Files

- Probes (fresh-process scripts, re-runnable as-is):
  `tmp/rev-measure/build_trees.rb`,
  `tmp/rev-measure/probe_tokens.rb`,
  `tmp/rev-measure/probe_tokens_breakdown.rb`,
  `tmp/rev-measure/probe_tokens_eventshare.rb`,
  `tmp/rev-measure/probe_timeline.rb`,
  `tmp/rev-measure/probe_timeline_scale.rb`,
  `tmp/rev-measure/probe_replay.rb`.
- Raw logs: `tmp/rev-measure/logs/*.log` (9 files).
- Fixture trees (inputs, read-only during measurement):
  `tmp/rev-measure/fixtures/{small,mid,large}/`,
  `tmp/rev-measure/scale/{c5,c20,c50}/`.
