# lib/ChatAnalyst/api.rb
#
# Public Ruby API for the ChatAnalyst redesign — ALL TEN methods implemented
# (redesign complete; thin workflow tasks live in lib/ChatAnalyst/tasks/).
# Plain module methods over the Scout-AI core Chat APIs.
# Every result is a serializable Hash/Array holding path strings, integers
# and counts only: no Chat/Step/Path objects, no synthetic ids, no
# "path#index" concatenated identifiers, and no materialized graph rebuild
# (provenance_edges / provenance_chat_files / provenance_jobs /
# provenance_closure are never called from here).
#
# Conventions:
# - Message indices are zero-based positions in the parsed message sequence
#   of ONE chat file (Chat.load order); ranges are inclusive at both ends.
# - Paths are canonical absolute paths (realpath'd when the file exists), the
#   same spelling Chat.provenance_graph resolves job references to, so every
#   returned path can be fed back into these methods or Step.load directly.
# - There is no `follow` input anywhere in this API (Stage 0 decision): the
#   overview/timeline traversal always follows job references and direct
#   dependencies, and never follows delegation targets or live sidecar chats.
#
# Stage plan:
# - Stage 2 (implemented): overview
# - Stage 3 (implemented): message_index, message, range
# - Stage 4 (implemented): timeline (temporal bursts only; all semantic
#   heuristics of the old timeline removed; freshness identity from ONE
#   traversal; compact-result cache)
# - Stage 5 (implemented): tool_calls
# - Stage 6 (implemented): tokens, relationships, live
# - Minimal revision step 2 (implemented): tool_call — full evidence for
#   exactly one call (arguments, output content, error detail)
# - Minimal revision phase 2 (implemented): attribution — the root/delegated/
#   unattributed token split over ONE deduplicated event list, with linked and
#   unresolved delegation jobs (promoted from the retired report adapter)

require 'set'
require 'time'
# - Minimal revision step 2 (implemented): tool_call — full evidence for
#   exactly one call (arguments, output content, error detail)

require 'time'

module ChatAnalyst

  # Characters of normalized reasoning text kept in a bout record.  The full
  # reasoning stays retrievable through message() by anchor index.
  TIMELINE_PREVIEW_CHARACTERS = 240

  # Compact timeline results are memoized per (freshness identity, burst
  # gap).  The cache holds plain serializable data only, is capped, and
  # entries are deep-copied on return so a caller can never mutate shared
  # state.  See timeline_freshness_identity for what invalidates an entry.
  TIMELINE_CACHE = {}
  TIMELINE_CACHE_MAX_ENTRIES = 32

  # Delegation tool names (minimal revision phase 1, plan step 4): the old
  # workflow-module DELEGATION_TOOLS constant moved here because this file is
  # now its only consumer; a literal (not ChatAnalyst::...) so the file loads
  # standalone, e.g. in probes, without load-order coupling.
  DELEGATION_TOOL_NAMES = %w[ask cortex_continue cortex_brief].freeze

  # -- Stage 2: overview -----------------------------------------------------

  # Compact overview of the provenance tree rooted at +root+.
  #
  # +root+ is a chat file path or a job path (a persisted Step directory,
  # detected by its .info sidecar); +root_type+ (:chat or :job) overrides the
  # detection.  Traversal is queue-based (breadth-first) and calls
  # Chat.provenance_graph once per node.  The visited set is keyed on the
  # (root type, canonical path) pair, so chat identity and job identity stay
  # distinct even when a chat-producing job and its output chat share one
  # path.  Referenced jobs (standalone meta job= references and
  # receipt-derived references) and direct job dependencies are enqueued as
  # job nodes; delegation references ("Agent#conversation") and live sidecar
  # paths are recorded as supplementary info but never traversed.  A job node
  # contributes ONLY its generated output chat; its input chat is invocation
  # context and is never read.
  #
  # Per chat node record: path, message count, role counts, job references
  # keyed by originating message index (Array value when two references share
  # one index), delegation references keyed by index, live paths, warnings.
  # Per job node record: canonical path, direct dependencies as canonical
  # paths in declared order (the owning job is the record itself), live
  # paths, warnings.
  #
  # Returns a Hash:
  #   {root: {type:, path:}, chats: [...], jobs: [...],
  #    live_missing: [...],           # only when a listed live path is gone
  #    unloaded_references: [...]}    # only when a discovered node failed
  #
  # Every discovered node that fails to load is reported as
  # {kind: :chat|:job, path:, error:, via: {from_kind, from_path, context}}
  # (via is nil for the root itself, which has no originating reference):
  # the queue carries the reference that enqueued each node, so an
  # unloaded_reference states WHO referenced it, not just THAT it failed
  # (minimal revision phase 2, plan step 6).
  def self.overview(root, root_type: nil)
    root_kind, root_value = resolve_api_root(root, root_type)

    chats = []
    jobs = []
    live_missing = []
    unloaded = []
    visited = {}
    queue = [[root_kind, root_value, nil]]
    visited[[root_kind, canonical_node_path(root_kind, root_value)]] = true

    Chat.with_provenance_run_cache do
      until queue.empty?
        node_kind, node_value, via = queue.shift
        begin
          if node_kind == :chat
            path = Chat.provenance_path(:chat, node_value)
            graph = Chat.provenance_graph(path, root_type: :chat)
            chat = Chat.provenance_chat_load(path)
            chats << {
              path: path,
              messages: chat.length,
              roles: role_counts(chat),
              job_references: normalize_reference_map(graph[:chats]),
              delegation_references: normalize_delegation_map(graph[:delegation]),
              live: graph[:live].collect { |live_path| plain_string(live_path) },
              warnings: graph[:warnings]
            }
            collect_missing_live(graph[:live], live_missing)
            graph[:chats].values.flatten.uniq.each do |job_path|
              enqueue_node(queue, visited, :job, job_path,
                           from_kind: :chat, from_path: path, context: 'job reference')
            end
          else
            step = Step === node_value ? node_value : Step.load(node_value.to_s)
            path = Chat.provenance_path(:job, step)
            graph = Chat.provenance_graph(step, root_type: :job)
            jobs << {
              path: path,
              dependencies: graph[:dependencies].collect { |dep| canonical_plain_path(dep) },
              live: graph[:live].collect { |live_path| plain_string(live_path) },
              warnings: graph[:warnings]
            }
            collect_missing_live(graph[:live], live_missing)
            transcript = Chat.job_result_chat_file(step)
            enqueue_node(queue, visited, :chat, transcript.to_s,
                         from_kind: :job, from_path: path, context: 'result chat') if transcript
            graph[:dependencies].each do |dependency_path|
              enqueue_node(queue, visited, :job, dependency_path,
                           from_kind: :job, from_path: path, context: 'direct dependency')
            end
          end
        rescue StandardError => error
          unloaded << {kind: node_kind, path: node_fallback_path(node_value),
                       error: "#{error.class}: #{error.message}", via: via}
        end
      end
    end

    result = {root: {type: root_kind, path: canonical_node_path(root_kind, root_value)},
              chats: chats, jobs: jobs}
    result[:live_missing] = live_missing.uniq if live_missing.any?
    result[:unloaded_references] = unloaded if unloaded.any?
    result
  end

  # -- Stage 3: message index and retrieval -----------------------------------
  #
  # Coordinate convention (documented choice): indices are zero-based
  # positions in the parsed message sequence of the single addressed chat,
  # and ranges are inclusive at both ends.  NO cumulative character offsets
  # are exposed: `characters` counts the characters of the parsed message
  # content string and is a property of the parsed sequence, NOT a file byte
  # offset.  Omitting offsets keeps exactly one coordinate system (parse
  # position) that cannot drift from Chat.load.  Message bodies are never
  # returned by message_index; a large message is identified by its
  # character count alone.

  # Zero-based index of every message in one chat: role, character count,
  # and the timestamp when the message carries one (meta messages do;
  # everything else reports nil).  Never bodies.
  def self.message_index(chat_path)
    chat = load_single_chat(chat_path)
    chat.each_with_index.collect do |message, index|
      {
        index: index,
        role: message[:role].to_s,
        characters: (message[:content] || '').length,
        timestamp: message_timestamp(message)
      }
    end
  end

  # Full retrieval of exactly one message (zero-based +index+).
  def self.message(chat_path, index)
    chat = load_single_chat(chat_path)
    check_message_index!(chat_path, chat, index)
    message_record(chat_path, chat, index)
  end

  # Inclusive retrieval of messages +first+..+last+ (zero-based, both ends
  # inclusive) from one chat.  Loads ONLY the addressed chat.
  def self.range(chat_path, first, last)
    chat = load_single_chat(chat_path)
    path = canonical_chat_path(chat_path)
    valid = "0..#{chat.length - 1}"
    unless Integer === first && first >= 0
      raise ParameterException, "Invalid range start #{first.inspect} for #{path}: must be a non-negative integer (valid range #{valid})"
    end
    unless Integer === last && last >= first
      raise ParameterException, "Invalid range end #{last.inspect} for #{path}: must be an integer >= first (#{first}); valid range #{valid}"
    end
    if last >= chat.length
      raise ParameterException, "Range #{first}..#{last} out of range for #{path}: valid range #{valid} (#{chat.length} messages)"
    end

    messages = first.upto(last).collect { |i| message_record(nil, chat, i) }
    {chat: path, first: first, last: last, messages: messages}
  end

  # -- Stage 4: timeline --------------------------------------------------------
  #
  # Bout model: one persisted planned interaction is the user/meta/assistant
  # triplet ANCHORED AT THE META MESSAGE (the inference anchor); bouts are
  # never modeled as alternating meta/assistant pairs.  Tool calls that
  # occur without a covering meta (before the first one, or in chats without
  # meta messages) form implicit bouts labelled implicit: true.  Reasoning
  # is reported as character count plus a compact preview only; full text
  # stays retrievable through message() by anchor index.
  #
  # Bursts are TEMPORAL groupings only: a new burst starts when the elapsed
  # time between consecutive bouts (in chronological order) exceeds
  # +burst_gap+ seconds.  No semantic phase claims of any kind.  A bout
  # without a parseable timestamp never splits a burst (its gap is treated
  # as unknown, not as infinite).
  #
  # Cross-chat references are chat path + zero-based message indices of the
  # OWNING chat; indices never restart across chats.
  #
  # Freshness/caching: the result is memoized in TIMELINE_CACHE keyed by a
  # freshness identity derived from ONE traversal (the old implementation
  # ran three independent full closures per identity check) plus the burst
  # gap.  The identity hashes the canonical root, every visited node
  # (kind + path), the content digest of every visited chat, the result and
  # .info digests of every visited job, and each node's live sidecar PATH
  # set (relationship discovery).  Appending to a reachable chat, changing a
  # job result or .info, discovering a new job/chat reference or live
  # sidecar, all change the identity and force recomputation.  Live sidecar
  # CONTENT is deliberately not digested: the timeline never traverses live
  # chats, so in-flight appends to them do not invalidate anything.

  # Chronological timeline of interaction bouts for the provenance tree
  # rooted at +root+ (a chat path or a chat-producing job path, detected by
  # its .info sidecar).  With +bursts+ empty the result carries every bout
  # compactly plus all bursts with bout counts; with a list of 1-based burst
  # ids the selected bursts are returned with their bout records inlined.
  def self.timeline(root, bursts: [], burst_gap: 120)
    unless Numeric === burst_gap && burst_gap > 0
      raise ParameterException, "Invalid burst_gap #{burst_gap.inspect}: must be a positive number of seconds"
    end
    requested = Array(bursts)
    selected = requested.collect do |id|
      Integer === id ? id : (String === id && id =~ /\A[1-9]\d*\z/ ? id.to_i : nil)
    end
    invalid = requested.zip(selected).reject { |_raw, normalized| normalized }.map(&:first)
    raise ParameterException, "Invalid burst ids #{invalid.inspect}: burst ids are 1-based integers" unless invalid.empty?
    selected = selected.compact.uniq.sort

    root_kind, root_value = resolve_api_root(root, nil)
    identity = timeline_freshness_identity(root_kind, root_value)
    cache_key = [identity, burst_gap.to_f]
    if (cached = TIMELINE_CACHE[cache_key])
      result = Marshal.load(Marshal.dump(cached))
    else
      result = timeline_build(root_kind, root_value, burst_gap.to_f)
      TIMELINE_CACHE.shift if TIMELINE_CACHE.length >= TIMELINE_CACHE_MAX_ENTRIES
      TIMELINE_CACHE[cache_key] = Marshal.load(Marshal.dump(result))
    end

    return result if selected.empty?

    # Selection mode is a DETAIL view: the selected bursts inline exactly
    # their bouts, and the full bout array leaves the result entirely (the
    # old shape kept :bouts AND inlined the selected bouts again, so every
    # selected bout appeared twice and the compact response was still
    # unbounded).  Indexes identify evidence and indicate its size; detail
    # requests retrieve only the selected evidence.
    all_bouts = result.delete(:bouts)
    lookup_bursts = result[:bursts].select { |burst| selected.include?(burst[:id]) }
    result[:selected_burst_ids] = selected
    result[:bursts] = lookup_bursts.collect do |burst|
      records = all_bouts[burst[:first_bout]..burst[:last_bout]]
      burst.except(:first_bout, :last_bout).merge(bouts: records)
    end
    result[:bouts_total] = all_bouts.length
    result
  end

  # -- Stage 5: tool calls --------------------------------------------------------
  #
  # Per-chat tool-call index over the Chat.tool_calls parser.  Receipt
  # derived job references attach to the call whose OUTER
  # function_call_output index carries them (the compact graph's `chats`
  # mapping already anchors them there); ask-call delegations come from the
  # graph's `delegation` mapping, and an ask WITHOUT a job reference is
  # still a valid delegation entry (delegated: true, jobs: nil).  A
  # delegation and a materialized inference job are kept distinct: the
  # delegation target string never turns into a job path.  Delegation
  # classification follows the old task's notion: the delegation tool names
  # below, hand_off_to_* prefixes, or the generic agent_meta receipt
  # fallback.  Nothing is inferred from agent name, society directory or
  # path convention.
  #
  # Every discovered call is listed independently: this method performs NO
  # deduplication at all (deduplication with strict identity evidence is a
  # task-layer concern), so identical calls with missing call ids can never
  # auto-collapse here.

  # Tool calls of one chat, optionally restricted to calls whose call
  # message index lies in +first+..+last+ (zero-based, inclusive; nil means
  # 0 and length-1).  Entries carry indices, tool name, timestamps when the
  # persisted output envelope records them, success/failure/unknown status,
  # output character count, delegation classification/target and receipt
  # derived job paths.  Arguments and outputs are never inlined.
  def self.tool_calls(chat_path, first: nil, last: nil)
    chat = load_single_chat(chat_path)
    path = canonical_chat_path(chat_path)
    valid = "0..#{chat.length - 1}"
    first = 0 if first.nil?
    unless Integer === first && first >= 0
      raise ParameterException, "Invalid first #{first.inspect} for #{path}: must be a non-negative integer (valid range #{valid})"
    end
    last = chat.length - 1 if last.nil?
    unless Integer === last && last >= first
      raise ParameterException, "Invalid last #{last.inspect} for #{path}: must be an integer >= first (#{first}); valid range #{valid}"
    end
    if last >= chat.length
      raise ParameterException, "Range #{first}..#{last} out of range for #{path}: valid range #{valid} (#{chat.length} messages)"
    end

    graph = Chat.provenance_graph(path, root_type: :chat)
    records = timeline_call_records(chat, graph, path)
      .select { |call| Integer === call[:call_index] && call[:call_index] >= first && call[:call_index] <= last }
    {chat: path, first: first, last: last, calls: records}
  end

  # Full evidence for exactly ONE tool call of one chat (the detail
  # counterpart of the compact tool_calls index; call_index is the
  # function_call/mcp_call message index, the same integer the compact index
  # reports).  Retrieves the arguments and the ACTUAL persisted output
  # message content plus the error envelope fields a failed call carries,
  # so a failed call can be investigated without loading anything else:
  # tool_call -> range(first == last on the output index) stays open.
  #
  # Record shape: {chat, call_index, output_index?, tool, call_id?, role,
  # arguments (parsed Hash when parseable, else the raw persisted String),
  # argument_characters, status (:success/:failure/:unknown), reason,
  # error? (exception/exit_status), timestamp?, start_timestamp?, output
  # (persisted output content, nil when the call has no output message),
  # output_info? (envelope fields minus content), output_characters,
  # delegated, delegation_target?, jobs, copy_of?}.
  def self.tool_call(chat_path, call_index)
    chat = load_single_chat(chat_path)
    path = canonical_chat_path(chat_path)
    valid = "0..#{chat.length - 1}"
    unless Integer === call_index && call_index >= 0
      raise ParameterException, "Invalid call index #{call_index.inspect} for #{path}: must be a non-negative integer (valid range #{valid})"
    end
    if call_index >= chat.length
      raise ParameterException, "Call index #{call_index} out of range for #{path}: valid range #{valid} (#{chat.length} messages)"
    end

    parsed = Chat.tool_calls(chat)
    call = parsed.find { |entry| entry[:call_index] == call_index }
    unless call
      started = parsed.collect { |entry| entry[:call_index] }.compact
      raise ParameterException,
            "No tool call starts at index #{call_index} of #{path}: the message at that index is not a function_call/mcp_call start. Tool calls start at #{started.inspect}"
    end

    graph = Chat.provenance_graph(path, root_type: :chat)
    compact = timeline_call_records(chat, graph, path)
      .find { |record| record[:call_index] == call_index }

    arguments = call[:arguments]
    parsed_arguments = Chat.parse_json(arguments) if String === arguments
    arguments = parsed_arguments if Hash === parsed_arguments
    argument_characters = timeline_argument_characters(call)

    status = Chat.tool_call_status(call)
    output_info = Hash === call[:output_info] ? call[:output_info] : {}
    error = {}
    error[:exception] = status[:exception] if status[:exception]
    error[:exit_status] = status[:exit_status] if status.key?(:exit_status)

    record = {
      chat: path,
      call_index: call_index,
      tool: call[:name].to_s,
      role: call[:role].to_s,
      arguments: arguments,
      argument_characters: argument_characters,
      status: status[:success].nil? ? :unknown : (status[:success] ? :success : :failure),
      reason: status[:reason],
      timestamp: timeline_safe_timestamp(output_info['timestamp']),
      start_timestamp: timeline_safe_timestamp(output_info['start_timestamp']),
      output: call[:output],
      output_characters: call[:output].to_s.length,
      delegated: compact ? compact[:delegated] : nil,
      jobs: compact ? compact[:jobs] : []
    }
    record[:call_id] = call[:call_id] if call[:call_id]
    record[:output_index] = call[:output_index] if call[:output_index]
    record[:error] = error if error.any?
    record[:output_info] = output_info.except('content') if output_info.any?
    record[:delegation_target] = compact[:delegation_target] if compact && compact[:delegation_target]
    record[:copy_of] = compact[:copy_of] if compact && compact.key?(:copy_of)
    record[:inference_id] = compact[:inference_id] if compact
    record[:source_kind] = compact ? compact[:source_kind] : nil
    if compact && compact[:target_agent]
      record[:target_agent] = compact[:target_agent]
      record[:target_conversation] = compact[:target_conversation]
    end
    record
  end

  # -- Stage 6: tokens, relationships, live --------------------------------------

  # Token scopes delegated to the core total API (see tokens below).  They are
  # EVIDENCE COVERAGE descriptions, never a partition of cost: chat_evidence
  # and receipt_evidence overlap and must not be summed; only
  # deduplicated_total and receipt_only compare additively.
  TOKEN_SCOPES = %i[deduplicated_total chat_evidence receipt_evidence receipt_only].freeze

  # Deduplicated direct-inference token accounting for the provenance tree
  # rooted at +root+, delegated wholesale to Chat.provenance_token_events and
  # Chat.provenance_token_totals (no rebuilt accounting here: field semantics
  # pt/ct/tt/cct/cwt/rt, canonical-evidence counting, identity/conflict rules
  # and the checkpoint exclusion of *_c/*_s all live in the core).
  #
  # Returns:
  #   {root: {type:, path:},
  #    scopes: {deduplicated_total: {pt:, ct:, tt:, cct:, cwt:, rt:}, ...},
  #    conflicts: {events:, incomplete_evidence_events:, authoritative:},
  #    events: [...], warnings: [...]}
  #
  # Per event: {inference_id:, identity:, deduplication:, tokens:,
  # conflict:, incomplete_evidence:, evidence: [{origin:, source:, call_id:,
  # tool_name:, meta_address:|[evidence_address:, output_address:,
  # agent_meta_index:]}]} with absolute source paths and message indices; the
  # canonical (counted) evidence is evidence.first.  A conflicting event is
  # counted once from canonical evidence, so a total containing conflicts is
  # best-effort: conflicts[:authoritative] is false exactly then.
  def self.tokens(root)
    root_kind, root_value = resolve_api_root(root, nil)
    warnings = []
    conflicts = {}
    scopes = {}
    events = nil
    Chat.with_provenance_run_cache do
      events = Chat.provenance_token_events(root_value, root_type: root_kind, warnings: warnings)
      # Every totals call runs its own traversal; each must route traversal
      # agent_meta problems (unresolved job references, malformed receipts)
      # into a warnings Array the same way the events call does, or the first
      # such problem raises instead of being reported (verified against the
      # N1 ghost-job fixture).
      TOKEN_SCOPES.each do |scope|
        scopes[scope] = Chat.provenance_token_totals(root_value, root_type: root_kind,
                                                     scope: scope, warnings: [])
      end
      Chat.provenance_token_totals(root_value, root_type: root_kind, conflicts: conflicts, warnings: [])
    end

    {
      root: {type: root_kind, path: canonical_node_path(root_kind, root_value)},
      scopes: scopes,
      conflicts: conflicts,
      events: events.collect { |event| compact_token_event(event) },
      warnings: warnings.collect { |warning| plain_token_warning(warning) }
    }
  end

  # Import/continue/last-chat references of ONE chat, kept strictly separate
  # from core provenance (the core traversal deliberately ignores them;
  # Chat.load keeps the reference messages; Chat.find_file resolves).  Every
  # reference keeps its zero-based message index and its resolution outcome;
  # an unresolved local reference is reported (resolved: false,
  # unresolved_reason: :missing), never raised, and a remote reference keeps
  # its text with unresolved_reason: :remote.  import_closure is the post-order
  # walk over resolved `import:` references only (deepest/oldest first, root
  # last), cycle-safe.
  def self.relationships(chat_path)
    path = canonical_chat_path(chat_path)
    raise ParameterException, "Chat not found: #{chat_path}" unless File.file?(path)

    references = relationship_references(path)
    by_target = references.group_by { |reference| reference[:target] || reference[:reference] }
    targets = by_target.collect do |target, group|
      {
        target: target,
        resolved: group.first[:resolved],
        types: group.collect { |reference| reference[:type] }.tally,
        references: group.length
      }
    end

    {
      chat: path,
      references: references,
      targets: targets,
      import_closure: import_closure_of(path)
    }
  end

  # LIVE (in-flight) state for the tree rooted at +root+, delegated to
  # Chat.live_report over the root's save file (a chat root IS its save file;
  # a job root contributes its generated result chat when chat-typed, else the
  # job path).  Everything is fail-soft: an absent sidecar, absent agent save
  # file, absent society tree or unreadable job yields nothing and never
  # raises.  Entry kinds: :inference, :workload_context, :agent_activity,
  # :dangling_job; entries are folded/deduplicated by job id exactly as the
  # core report does.  The core's transient :step objects are stripped: every
  # entry carries its :path/:reference as plain strings instead.
  def self.live(root)
    root_kind, root_value = resolve_api_root(root, nil)
    base = if root_kind == :job
             result = Chat.job_result_chat_file(root_value)
             result ? result.to_s : root_value.path.to_s
           else
             root_value.to_s
           end

    report = Chat.live_report(base)
    {
      root: {type: root_kind, path: canonical_node_path(root_kind, root_value)},
      base: plain_string(base),
      entries: report[:entries].collect { |entry| plain_live_value(entry) },
      scanned: report[:scanned]
    }
  end

  # -- minimal revision phase 2: attribution -------------------------------------

  # Root/delegated/unattributed token split for the provenance tree rooted
  # at +root+ (minimal revision phase 2, plan step 5, decision D2: promoted
  # from the retired report composite; every pinned semantic is kept).
  #
  # Token events are fetched ONCE (a single ChatAnalyst.tokens call, which
  # itself makes one provenance_token_events traversal — pass +tokens_report:
  # a prefetched report to share a fetch you already made); the split is over
  # canonical evidence (evidence.first[:source]):
  # - root events: canonical evidence in the root chat itself, or (job root)
  #   in the job's OWN chats — its generated result chat and its direct log
  #   chats — never its dependencies;
  # - delegated events: canonical evidence in any chat file of a LINKED
  #   delegation job (its own logs and result chats, recursively through
  #   nested delegation jobs);
  # - unattributed events: everything else (e.g. events imported from chats
  #   of no linked subtree).
  #
  # Linked jobs come from the same frontier walk the retired report used: the
  # receipt-derived job references of every chat the tree traversal loads
  # (overview job_references) PLUS the job references carried by the ROOT
  # JOB'S OWN direct log chats (agent.chat sidecars are listed as live,
  # never traversed, so their receipts are read explicitly here), then
  # nested jobs through each linked job's generated result chat, cycle-safe.
  # The root job itself is never counted as a linked job.
  #
  # unresolved_jobs lists referenced delegation jobs whose cost is missing
  # because the job could not be resolved (nil NEVER leaks: reference-less
  # problems are counted in malformed_edges instead — pinned by
  # test_unresolved_jobs_nil.rb).
  #
  # Returns:
  #   {root: {type:, path:}, total: {pt, ct, tt, cct, cwt, rt, events},
  #    root_chat_tokens: ..., root_chat_events: Integer,
  #    delegated_tokens: ..., delegated_events: Integer,
  #    unattributed_tokens: ..., unattributed_events: Integer,
  #    linked_jobs: [canonical paths] (excludes the root job's own path),
  #    unresolved_jobs: [String], malformed_edges: Integer, warnings: [...]}
  # +tokens_report+ lets a caller that already fetched ChatAnalyst.tokens
  # pass the report in, so chat_tokens?attribution=true computes everything
  # from ONE token fetch (the standalone call fetches its own).
  def self.attribution(root, tokens_report: nil)
    tokens_report = tokens(root) unless tokens_report
    events = tokens_report[:events]
    root_kind = tokens_report[:root][:type]
    root_path = tokens_report[:root][:path]

    # Root chat set: the root chat itself, or (job root) the job's OWN chats.
    root_chat_paths = Set[root_path]
    if root_kind == :job
      root_step = Step.load(root_path)
      transcript = Chat.job_result_chat_file(root_step)
      root_chat_paths << File.expand_path(transcript.to_s) if transcript
      Chat.direct_job_chat_files(root_step).each do |log|
        root_chat_paths << File.expand_path(log.to_s)
      end
    end

    linked_jobs = []
    visited_jobs = Set.new
    job_frontier = Chat.with_provenance_run_cache do
      own_log_chats = root_kind == :job ? Chat.direct_job_chat_files(Step.load(root_path)) : []
      frontier = overview_job_frontier(root) + own_log_chats.flat_map do |chat_file|
        tool_calls(chat_file)[:calls].flat_map { |call| call[:jobs] || [] }
      end
      frontier.collect { |job_path| plain_string(job_path) }.uniq
    end
    until job_frontier.empty?
      job_path = job_frontier.shift
      next unless visited_jobs.add?(job_path)
      linked_jobs << job_path
      step = begin
               Step.load(job_path)
             rescue StandardError
               nil
             end
      next unless step
      transcript = Chat.job_result_chat_file(step)
      next unless transcript
      graph = Chat.with_provenance_run_cache { Chat.provenance_graph(transcript, root_type: :chat) }
      graph[:chats].values.flatten.uniq.each { |child| job_frontier << plain_string(child) }
    end

    # Delegated chat set: every chat file of every linked job.
    delegated_chats = Set.new
    linked_jobs.each do |job_path|
      step = begin
               Step.load(job_path)
             rescue StandardError
               nil
             end
      next unless step
      transcript = Chat.job_result_chat_file(step)
      delegated_chats << File.expand_path(transcript.to_s) if transcript
      Chat.direct_job_chat_files(step).each { |log| delegated_chats << File.expand_path(log.to_s) }
    end

    delegated_events = events.select do |event|
      source = canonical_event_source(event)
      source && delegated_chats.include?(File.expand_path(source.to_s))
    end
    root_events = events.select do |event|
      source = canonical_event_source(event)
      source && root_chat_paths.include?(File.expand_path(source.to_s))
    end
    unattributed_events = events - delegated_events - root_events

    unresolved_warnings = tokens_report[:warnings].select { |warning| warning[:reason] == :unresolved_job_reference }
    unresolved_jobs = unresolved_warnings.collect { |warning| warning[:reference] }.compact.uniq
    malformed_edges = unresolved_warnings.count { |warning| warning[:reference].nil? }

    {
      root: {type: root_kind, path: root_path},
      total: tokens_report[:scopes][:deduplicated_total].merge(events: events.length),
      root_chat_tokens: sum_events(root_events),
      root_chat_events: root_events.length,
      delegated_tokens: sum_events(delegated_events),
      delegated_events: delegated_events.length,
      unattributed_tokens: sum_events(unattributed_events),
      unattributed_events: unattributed_events.length,
      linked_jobs: linked_jobs.reject { |job| root_chat_paths.include?(job) },
      unresolved_jobs: unresolved_jobs,
      malformed_edges: malformed_edges,
      warnings: tokens_report[:warnings]
    }
  end

  # The frontier of directly referenced jobs: the receipt-derived references
  # (anchored at their outer function_call_output indices) of every chat the
  # tree traversal loads.
  def self.overview_job_frontier(root)
    overview(root)[:chats].flat_map { |record| record[:job_references].values }.flatten.uniq
  end

  # -- internal helpers ---------------------------------------------------------

  # Resolve +root+ to a (kind, value) pair: [:chat, absolute path] or
  # [:job, Step].  With +root_type+ nil this is the same detection the
  # workflow's resolve_root helper performs (candidate chain incl. the
  # Scout.chats path map, then the .info sidecar test; a .files directory
  # alone is NOT job evidence).  An explicit +root_type+ bypasses detection.
  def self.resolve_api_root(root, root_type = nil)
    if root_type
      kind = root_type.to_sym
      raise ParameterException, "Unknown root type: #{root_type.inspect} (use :chat or :job)" unless %i[chat job].include?(kind)
      if kind == :job
        step = Step === root ? root : Step.load(File.expand_path(root.to_s))
        path = step.path.to_s
        raise ParameterException, "Job not found: #{root}" unless File.exist?(path) || File.exist?(path + '.info')
        return [:job, step]
      end
      path = File.expand_path(root.to_s)
      raise ParameterException, "Chat not found: #{root}" unless File.file?(path)
      return [:chat, path]
    end

    candidates = [root, "#{root}.chat", File.expand_path(root.to_s), File.expand_path("#{root}.chat")]
    begin
      candidates << Scout.chats[root].find
      candidates << Scout.chats[root].find_with_extension(:chat).find
    rescue StandardError
    end
    candidate = candidates.compact.find { |c| File.file?(c.to_s) }
    raise ParameterException, "Chat or job not found: #{root}" unless candidate

    path = File.expand_path(candidate.to_s)
    File.exist?(path + '.info') ? [:job, Step.load(path)] : [:chat, path]
  end

  # Canonical spelling for one node.  Job values coming from the compact
  # graph (its `chats` values and `dependencies`) are already canonical
  # realpath'd absolute paths, so they pass through unchanged; Step objects
  # and chat paths are canonicalized through Chat.provenance_path so every
  # visited-set key and recorded path uses the same spelling the graph
  # itself resolves references to.
  #
  # ScoutCoder: Chat.provenance_path raises NoMethodError for the :job kind
  # with a String root (it calls object.path); pass a Step for :job, or keep
  # an already-canonical String as is, exactly as done here.
  def self.canonical_node_path(kind, value)
    return value.to_s if kind == :job && String === value
    Chat.provenance_path(kind, value)
  end

  def self.enqueue_node(queue, visited, kind, value, from_kind: nil, from_path: nil, context: nil)
    key = begin
            canonical_node_path(kind, value)
          rescue StandardError
            value.to_s
          end
    pair = [kind, key]
    return if visited[pair]
    visited[pair] = true
    via = from_kind ? {from_kind: from_kind, from_path: plain_string(from_path.to_s), context: context} : nil
    queue << [kind, value, via]
  end

  # Reference maps from the compact graph ({index => job path(s)} and
  # {index => "Agent#conversation"}): rebuild every value as a plain
  # canonical String, collapsing a single-element Array to the bare String
  # (two references sharing one index stay an Array), so no Path instance
  # and no alias spelling can leak through a public result.  Keys (message
  # indices) are already plain Integers.
  def self.normalize_reference_map(map)
    map.collect do |index, reference|
      values = Array(reference).collect { |job_path| canonical_plain_path(job_path) }
      [index, values.length == 1 ? values.first : values]
    end.to_h
  end

  def self.normalize_delegation_map(map)
    map.collect do |index, target|
      [index, plain_string(target.to_s)]
    end.to_h
  end

  # Canonical plain String for a job-path-like value (realpath through the
  # same core spelling Chat.provenance_path uses, expanded fallback when the
  # path does not exist on disk).
  def self.canonical_plain_path(path)
    plain_string(Chat.provenance_path(:chat, path.to_s))
  rescue StandardError
    plain_string(File.expand_path(path.to_s))
  end

  # Live sidecar paths are copied, never traversed; a listed path that no
  # longer exists is tolerated with one aggregate note instead of per-file
  # warnings (the listing globs the filesystem, so this is defensive only).
  # The note carries a PLAIN String (live entries are Path-extended, and no
  # Path instance may leak into a public result).
  def self.collect_missing_live(live_paths, missing)
    live_paths.each { |path| missing << plain_string(path) unless File.exist?(path) }
  end

  # graph[:live] entries are Path.setup'd strings (Path extends String, so
  # #to_s returns the same extended object): rebuild a plain String so no
  # public result carries a Path instance anywhere.
  def self.plain_string(value)
    String.new(value.to_s)
  end

  # Canonical (realpath, fallback to expanded) spelling of a chat path, the
  # SAME spelling Chat.provenance_path resolves references to, so every
  # public operation that echoes a chat path — range, tool_calls,
  # tool_call, relationships — returns one canonical form however the file
  # was addressed (/home vs /bulk, symlinked directories, ~-short inputs
  # already expanded upstream).  minimal revision phase 2, plan step 6.
  def self.canonical_chat_path(chat_path)
    Chat.provenance_path(:chat, chat_path)
  end

  def self.role_counts(chat)
    chat.each_with_object(Hash.new(0)) do |message, counts|
      counts[message[:role].to_s] += 1
    end
  end

  def self.load_single_chat(chat_path)
    path = File.expand_path(chat_path.to_s)
    raise ParameterException, "Chat not found: #{chat_path}" unless File.file?(path)
    Chat.load(path)
  end

  # Timestamp of a meta message (the writer records `timestamp=` in the meta
  # line); nil for every other role and for meta lines without one.  The raw
  # string is reported; parsing belongs to Stage 4.
  def self.message_timestamp(message)
    return nil unless message[:role].to_s == 'meta'
    Chat.parse_meta(message[:content].to_s)['timestamp']
  end

  def self.check_message_index!(chat_path, chat, index)
    valid = "0..#{chat.length - 1}"
    unless Integer === index && index >= 0
      raise ParameterException, "Invalid message index #{index.inspect} for #{File.expand_path(chat_path.to_s)}: indices are zero-based and must be non-negative (valid range #{valid})"
    end
    if index >= chat.length
      raise ParameterException, "Message index #{index} out of range for #{File.expand_path(chat_path.to_s)}: valid range #{valid} (#{chat.length} messages)"
    end
  end

  def self.message_record(path, chat, index)
    message = chat[index]
    record = {index: index, role: message[:role].to_s, content: message[:content]}
    record[:chat] = path if path
    record
  end

  def self.node_fallback_path(node_value)
    (Step === node_value ? node_value.path : node_value).to_s
  rescue StandardError
    node_value.to_s
  end

  # Phase-2 helpers (attribution) -------------------------------------------------

  def self.sum_events(events)
    fields = %i[pt ct tt cct cwt rt]
    totals = Hash.new(0)
    totals[:events] = events.length
    events.each do |event|
      tokens = event[:tokens] || {}
      fields.each { |field| totals[field] += tokens[field] || 0 }
    end
    totals
  end

  # Canonical (counted) evidence source of one compact token event: the
  # absolute path of evidence.first, or nil when the event carries no
  # evidence at all.
  def self.canonical_event_source(event)
    canonical = event[:evidence].first
    canonical && canonical[:source]
  end

  # Compact serializable form of one token event: keeps identity, tokens,
  # flags and every evidence location, with absolute paths and message
  # indices only (no Chat/Step/Path instances, no short-path spellings).
  # evidence.first is the canonical (counted) evidence.
  def self.compact_token_event(event)
    {
      inference_id: event[:inference_id],
      identity: event[:identity],
      deduplication: event[:deduplication],
      tokens: event[:tokens],
      conflict: event[:conflict] || false,
      incomplete_evidence: event[:incomplete_evidence] || false,
      evidence: event[:evidence].collect do |item|
        record = {
          origin: item[:origin],
          source: item[:source] && plain_string(item[:source]),
          call_id: item[:call_id],
          tool_name: item[:tool_name]
        }
        if item[:origin] == :chat_meta
          record[:meta_address] = item[:meta_address]
        else
          record[:evidence_address] = item[:evidence_address]
          record[:output_address] = item[:output_address]
          record[:agent_meta_index] = item[:agent_meta_index]
        end
        record
      end
    }
  end

  # Warnings from the token collector are Hashes that may embed Step/Path
  # objects (evidence records, identity values): rebuild a plain shape with
  # stringified paths so the public result stays JSON-clean.
  def self.plain_token_warning(warning)
    plain = warning.collect do |key, value|
      [key, case value
            when String then plain_string(value)
            when Step then plain_string(value.path)
            else value
            end]
    end.to_h
    if plain[:evidence].is_a?(Array)
      plain[:evidence] = plain[:evidence].collect { |item| item.is_a?(Hash) ? plain_token_warning(item) : plain_string(item) }
    end
    plain
  end

  # import:/continue:/last: reference events of one chat (ported from the
  # retired workflow helper chat_relationship_references, keeping its
  # resolution semantics: Chat.find_file from the chat path, remote refs kept
  # as text, missing local refs reported not raised).
  def self.relationship_references(path)
    chat = Chat.load(path)
    chat.each_with_index.filter_map do |message, index|
      type = message[:role].to_s
      next unless %w[import continue last].include?(type)

      reference = message[:content].to_s.strip
      found = Chat.find_file(reference, path)
      if found && !Open.remote?(found.to_s) && Open.exist?(found.to_s)
        target = begin
                   Chat.provenance_path(:chat, found.to_s)
                 rescue StandardError
                   File.expand_path(found.to_s)
                 end
        {type: type.to_sym, reference: reference, message_index: index,
         resolved: true, target_kind: :chat, target: target}
      else
        {type: type.to_sym, reference: reference, message_index: index,
         resolved: false, target_kind: :chat, target: nil,
         unresolved_reason: Open.remote?(found.to_s) ? :remote : :missing}
      end
    end
  end

  # Post-order import closure (deepest/oldest first, root last), cycle-safe
  # by canonical path.  `continue:`/`last:` are message-level references, not
  # conversation boundaries, and never enter the closure.
  def self.import_closure_of(path)
    order = []
    root_path = canonical_chat_path(path)
    seen = {root_path => true}
    walk = lambda do |chat_path|
      canonical = canonical_chat_path(chat_path)
      relationship_references(canonical)
        .select { |reference| reference[:type] == :import && reference[:resolved] }
        .each do |reference|
          target = reference[:target].to_s
          next if seen[target]
          seen[target] = true
          walk.call(target)
        end
      order << canonical
    end
    walk.call(root_path)
    order
  end

  # One live entry, stripped of the core's transient objects (:step and any
  # Path-extended values): reference/path/state/status/chat_task/agent_log/
  # agent/conversation/via/parent/activity survive as plain data.
  def self.plain_live_value(entry)
    entry.reject { |key, _| key == :step }.collect do |key, value|
      [key, case value
            when String then plain_string(value)
            when Step then plain_string(value.path)
            when Hash then plain_live_value(value)
            when Array then value.collect { |item| item.is_a?(Hash) ? plain_live_value(item) : item }
            else value
            end]
    end.to_h
  end

  # -- timeline internals -----------------------------------------------------

  # One light breadth-first traversal producing the freshness identity:
  # canonical root + one row per visited node (kind, canonical path, chat
  # content digest; job result and .info digests; live sidecar PATH sets).
  # Rows are sorted before hashing so the identity is order-independent.
  # Live CONTENT is not digested: live chats are never traversed by the
  # timeline, so in-flight appends to them must not invalidate results.
  def self.timeline_freshness_identity(root_kind, root_value)
    rows = []
    visited = {}
    queue = [[root_kind, root_value]]
    visited[[root_kind, canonical_node_path(root_kind, root_value)]] = true

    Chat.with_provenance_run_cache do
      until queue.empty?
        kind, node = queue.shift
        begin
          if kind == :chat
            path = Chat.provenance_path(:chat, node)
            graph = Chat.provenance_graph(path, root_type: :chat)
            rows << [:chat, path, timeline_file_digest(path), graph[:live].map(&:to_s).sort]
            graph[:chats].values.flatten.uniq.each do |job_path|
              enqueue_node(queue, visited, :job, job_path)
            end
          else
            step = Step === node ? node : Step.load(node.to_s)
            path = Chat.provenance_path(:job, step)
            graph = Chat.provenance_graph(step, root_type: :job)
            rows << [:job, path, timeline_file_digest(path), timeline_file_digest(path + '.info'), graph[:live].map(&:to_s).sort]
            transcript = Chat.job_result_chat_file(step)
            enqueue_node(queue, visited, :chat, transcript.to_s) if transcript
            graph[:dependencies].each do |dependency_path|
              enqueue_node(queue, visited, :job, dependency_path)
            end
          end
        rescue StandardError => error
          rows << [:error, error.class.name, error.message]
        end
      end
    end

    Digest::SHA256.hexdigest(JSON.generate([
      root_kind.to_s, canonical_node_path(root_kind, root_value),
      rows.sort_by { |row| JSON.generate(row) }
    ]))
  end

  def self.timeline_file_digest(path)
    File.file?(path.to_s) ? Digest::SHA256.file(path.to_s).hexdigest : 'missing'
  end

  # Full timeline construction: the same traversal as overview, but building
  # bout records for every visited chat.  unloaded_references entries carry
  # kind + via exactly like overview's (see there).
  def self.timeline_build(root_kind, root_value, burst_gap)
    bouts = []
    live_missing = []
    unloaded = []
    chat_count = 0
    job_count = 0
    visited = {}
    queue = [[root_kind, root_value, nil]]
    visited[[root_kind, canonical_node_path(root_kind, root_value)]] = true

    Chat.with_provenance_run_cache do
      until queue.empty?
        kind, node, via = queue.shift
        begin
          if kind == :chat
            path = Chat.provenance_path(:chat, node)
            graph = Chat.provenance_graph(path, root_type: :chat)
            chat = Chat.provenance_chat_load(path)
            chat_count += 1
            bouts.concat(timeline_bouts_for_chat(path, chat, graph))
            collect_missing_live(graph[:live], live_missing)
            graph[:chats].values.flatten.uniq.each do |job_path|
              enqueue_node(queue, visited, :job, job_path,
                           from_kind: :chat, from_path: path, context: 'job reference')
            end
          else
            step = Step === node ? node : Step.load(node.to_s)
            path = Chat.provenance_path(:job, step)
            graph = Chat.provenance_graph(step, root_type: :job)
            job_count += 1
            collect_missing_live(graph[:live], live_missing)
            transcript = Chat.job_result_chat_file(step)
            enqueue_node(queue, visited, :chat, transcript.to_s,
                         from_kind: :job, from_path: path, context: 'result chat') if transcript
            graph[:dependencies].each do |dependency_path|
              enqueue_node(queue, visited, :job, dependency_path,
                           from_kind: :job, from_path: path, context: 'direct dependency')
            end
          end
        rescue StandardError => error
          unloaded << {kind: kind, path: node_fallback_path(node),
                       error: "#{error.class}: #{error.message}", via: via}
        end
      end
    end

    bouts = timeline_sort_bouts(bouts)
    bursts = timeline_make_bursts(bouts, burst_gap)
    calls = bouts.flat_map { |bout| bout[:calls] }
    summary = {
      chats: chat_count,
      jobs: job_count,
      bouts: bouts.length,
      implicit_bouts: bouts.count { |bout| bout[:implicit] },
      calls: calls.length,
      delegations: calls.count { |call| call[:delegated] },
      bursts: bursts.length
    }
    result = {root: {type: root_kind, path: canonical_node_path(root_kind, root_value)},
              summary: summary, bouts: bouts, bursts: bursts}
    result[:live_missing] = live_missing.uniq if live_missing.any?
    result[:unloaded_references] = unloaded if unloaded.any?
    result
  end

  # Chronological order: parseable timestamp first, then chat path, then the
  # bout's first index.  Unparseable/missing timestamps sort last,
  # deterministically.
  def self.timeline_sort_bouts(bouts)
    bouts.sort_by do |bout|
      time = timeline_parse_time(bout[:timestamp])
      [time ? time.to_f : Float::INFINITY, bout[:chat].to_s, bout[:first].to_i]
    end
  end

  # Bout records of ONE chat.  Explicit bouts anchor at meta messages.
  # Persisted order is user -> calls -> meta -> assistant, so a bout covers
  # BACKWARD from its anchor to the previous bout's end (or the leading
  # user/system request) and FORWARD to the assistant (stopping before the
  # next meta or a new user/system request).  Calls inside the span belong
  # to the bout; calls outside every explicit span form implicit bouts
  # grouped by their nearest preceding user/system boundary.
  def self.timeline_bouts_for_chat(path, chat, graph)
    call_records = timeline_call_records(chat, graph)

    meta_indexes = []
    chat.each_with_index do |message, index|
      meta_indexes << index if message[:role].to_s == 'meta'
    end

    request_start = lambda do |from, upto|
      (from..upto).select { |index| %w[user system].include?(chat[index][:role].to_s) }.max
    end

    covered = {}
    bouts = []
    previous_end = -1
    meta_indexes.each_with_index do |anchor, position|
      ending = position + 1 < meta_indexes.length ? meta_indexes[position + 1] - 1 : chat.length - 1
      boundary = (anchor + 1..ending).find do |index|
        %w[user system].include?(chat[index][:role].to_s)
      end
      ending = boundary - 1 if boundary

      span_start = request_start.call(previous_end + 1, anchor) || (previous_end + 1)
      previous_end = ending

      meta_fields = Chat.parse_meta(chat[anchor][:content].to_s)
      # The trigger is the nearest preceding user/system request ANYWHERE in
      # the chat (the leading request keeps triggering every triplet that
      # follows it); :first stays non-overlapping with the previous bout.
      trigger = (anchor - 1).downto(0).find do |index|
        %w[user system].include?(chat[index][:role].to_s)
      end
      assistants = (anchor..ending).select { |index| chat[index][:role].to_s == 'assistant' }
      assistant = assistants.last
      calls = call_records.select do |call|
        Integer === call[:call_index] && call[:call_index] >= span_start && call[:call_index] <= ending
      end
      calls.each { |call| covered[call[:call_index]] = true }
      last_index = [assistant, calls.map { |call| call[:output_index] || call[:call_index] }.compact.max, anchor].compact.max

      bouts << {
        chat: path,
        implicit: false,
        anchor_index: anchor,
        first: span_start,
        last: last_index,
        trigger_index: trigger,
        assistant_index: assistant,
        timestamp: timeline_safe_timestamp(meta_fields['timestamp']),
        reasoning: timeline_reasoning_summary(meta_fields['reas']),
        calls: calls,
        job_references: timeline_bout_job_references(graph, span_start..ending, calls)
      }
    end

    implicit_calls = call_records.reject { |call| covered[call[:call_index]] }
    implicit_calls.group_by do |call|
      (call[:call_index].to_i - 1).downto(0).find do |index|
        %w[user system].include?(chat[index][:role].to_s)
      end || :root
    end.each do |trigger, calls|
      calls = calls.sort_by { |call| call[:call_index].to_i }
      last_call = calls.max_by { |call| call[:output_index] || call[:call_index] }
      bouts << {
        chat: path,
        implicit: true,
        anchor_index: nil,
        first: calls.first[:call_index],
        last: (last_call[:output_index] || last_call[:call_index]),
        trigger_index: Integer === trigger ? trigger : nil,
        assistant_index: nil,
        timestamp: timeline_safe_timestamp(calls.map { |call| call[:timestamp] }.compact.min),
        reasoning: nil,
        calls: calls,
        job_references: []
      }
    end
    bouts
  end

  # Standalone meta job= references (anchored at their own index) that fall
  # inside a bout's span and are not consumed by a call's output envelope.
  def self.timeline_bout_job_references(graph, span, calls)
    consumed = calls.map { |call| call[:output_index] }.compact
    graph[:chats].select do |index, _reference|
      span.cover?(index) && !consumed.include?(index)
    end.collect do |index, reference|
      {index: index, path: Array(reference).collect { |job_path| plain_string(job_path) }}
    end
  end

  # Compact per-call records shared by timeline bouts and tool_calls: never
  # arguments, never outputs, never error text.
  # +inference_chat_path+ (optional, the chat's canonical path) enables the
  # inference_id foreign key: each call is owned by the LAST inference meta
  # BEFORE it in the same chat (the pinned EMITTER rule - scout-ai unshifts
  # the meta before its response segment; a call with no preceding inference
  # meta is unassociated, nil).
  def self.timeline_call_records(chat, graph, inference_chat_path = nil)
    delegation = graph[:delegation]
    receipts = Chat.agent_meta_evidence(chat).group_by { |record| record[:call_id] }
    parsed = Chat.tool_calls(chat)
    owners = inference_chat_path ? inference_owner_map(chat) : {}
    records = parsed.collect do |call|
      status = Chat.tool_call_status(call)
      output_info = Hash === call[:output_info] ? call[:output_info] : {}
      target = delegation[call[:call_index]] || timeline_arguments_delegation_target(call)
      receipt_delegation = receipts[call[:call_id]].to_a.any?
      owner_index = owners[call[:call_index]]
      record = {
        tool: call[:name].to_s,
        call_id: call[:call_id],
        call_index: call[:call_index],
        output_index: call[:output_index],
        status: status[:success].nil? ? :unknown : (status[:success] ? :success : :failure),
        reason: status[:reason],
        timestamp: timeline_safe_timestamp(output_info['timestamp']),
        start_timestamp: timeline_safe_timestamp(output_info['start_timestamp']),
        argument_characters: timeline_argument_characters(call),
        output_characters: call[:output].to_s.length,
        delegated: !target.nil? || receipt_delegation || timeline_delegation_tool?(call[:name]),
        delegation_target: target,
        jobs: timeline_refs_at(graph[:chats], call[:output_index]) || []
      }
      # Inference fields are attached ONLY when the owning chat path is given:
      # the timeline passes none, so timeline()/chat_timeline records keep
      # their exact pre-phase-3 shape (no behavior change there).
      if inference_chat_path
        target_agent, target_conversation = delegation_target_parts(target)
        record[:inference_id] = owner_index ? Ids.message_id(inference_chat_path, owner_index) : nil
        record[:source_kind] = :primary
        record[:target_agent] = target_agent
        record[:target_conversation] = target_conversation
      end
      record
    end
    # Strict copy identity (replaces the old MD5-of-[tool, call_id, arguments]
    # which auto-collapsed identical independent calls whose ids were missing):
    # a call is a copy of an EARLIER call only when BOTH carry the same
    # non-nil call id and identical tool name and identical arguments.  With
    # no call id there is never enough identity evidence, so two identical
    # id-less calls stay independent entries.
    originals = {}
    parsed.each_with_index do |call, position|
      next unless call[:call_id]
      key = [call[:call_id], call[:name].to_s, timeline_arguments_string(call)]
      first_position = originals[key]
      if first_position && first_position != position
        records[position][:copy_of] = records[first_position][:call_index]
        records[position][:source_kind] = :copy
      end
      originals[key] = position unless first_position
    end
    records
  end

  # Inference ownership (phase 3, plan step 3; rule PINNED from real chats -
  # the OPPOSITE of the first-draft "meta follows call" rule): scout-ai
  # UNSHIFTS each inference meta BEFORE the response segment it accounts for
  # (backends/default.rb process_response: `output.unshift({role: :meta,
  # ...})`), so the persisted shape per inference is META, [assistant text],
  # [the tool calls that response generated], [outputs].  Real-chat evidence
  # (b3_pin_layout_consolidated, b3_pin_ownership_decisive): dominant
  # inter-meta segment `function_call_output > META > function_call`
  # (1026/1034, 507/514, 1131/1133 metas); call execution timestamps sit
  # closest to the PRECEDING meta (1015:20, 240:15, 520:0).  A call
  # therefore belongs to the LAST inference meta BEFORE it in the same chat -
  # its EMITTER; a call with no preceding inference meta (an opening
  # unaccounted call, or a trailing call after the last meta whose meta
  # never arrived) stays unassociated.  NO synthetic inference is created.
  # job= projection markers own nothing (the search chat opens with one).
  def self.inference_owner_map(chat)
    owners = {}
    owner_index = nil
    chat.each_with_index do |message, index|
      role = message[:role].to_s
      if role == 'meta'
        owner_index = index unless Chat.parse_meta(message[:content].to_s).key?('job')
      elsif %w[function_call mcp_call].include?(role)
        owners[index] = owner_index if owner_index
      end
    end
    owners
  end

  # Split a delegation target "agent#conversation" into its two parts; a
  # target without '#' keeps the whole string as the agent and nil
  # conversation.  Returns [nil, nil] for absent targets.
  def self.delegation_target_parts(target)
    return [nil, nil] unless String === target && !target.empty?
    agent, conversation = target.split('#', 2)
    [agent, conversation.nil? || conversation.empty? ? nil : conversation]
  end

  # Canonical comparison spelling for argument identity (parses JSON strings
  # when the persisted call carries them serialized).
  def self.timeline_arguments_string(call)
    arguments = call[:arguments]
    return '' if arguments.nil?
    arguments = Chat.parse_json(arguments) if String === arguments
    return arguments.to_s unless Hash === arguments
    sorted = arguments.sort_by { |key, _| key.to_s }
    sorted.collect { |key, value| "#{key}=#{value.inspect}" }.join('&')
  end

  # Character count of the arguments a call actually persisted: the length of
  # the raw persisted string when the arguments arrived serialized, else the
  # canonical JSON length of the parsed value (nil arguments count 2, the
  # JSON spelling of null).
  def self.timeline_argument_characters(call)
    arguments = call[:arguments]
    return 2 if arguments.nil?
    return arguments.length if String === arguments
    JSON.generate(arguments).length
  end

  # Job paths anchored at a message index, normalized to an Array of plain
  # Strings (the compact graph stores two refs at one index as an Array).
  def self.timeline_refs_at(reference_map, index)
    return nil unless Integer === index && reference_map.key?(index)
    Array(reference_map[index]).collect { |job_path| plain_string(job_path) }
  end

  # Delegation classification mirrors the old chat_tool_calls task: the
  # delegation tool names, any hand_off_to_* prefix, or the generic receipt
  # fallback (handled by the caller).
  def self.timeline_delegation_tool?(name)
    name = name.to_s
    DELEGATION_TOOL_NAMES.include?(name) || name.start_with?('hand_off_to_')
  end

  # Delegation target from call ARGUMENTS (never from job/path conventions).
  # ask targets normally come from the graph's delegation mapping already;
  # this covers the other delegation tools and hand_off_to_* prefixes.
  def self.timeline_arguments_delegation_target(call)
    name = call[:name].to_s
    if name.start_with?('hand_off_to_')
      return "#{name.sub(/\Ahand_off_to_/, '')}#default"
    end
    return nil unless DELEGATION_TOOL_NAMES.include?(name)

    arguments = call[:arguments]
    arguments = Chat.parse_json(arguments) if String === arguments
    return nil unless Hash === arguments
    agent = arguments['agent'] || arguments['agent_name'] || arguments['target']
    return nil unless agent
    conversation = arguments['conversation'] || arguments['chat']
    conversation = 'default' if conversation.nil? || conversation.to_s.empty?
    "#{agent}##{conversation}"
  end

  # Reasoning is reported as character count plus compact preview only.
  def self.timeline_reasoning_summary(text)
    return nil unless String === text && !text.strip.empty?
    normalized = text.gsub(/\s+/, ' ').strip
    preview = if normalized.length > TIMELINE_PREVIEW_CHARACTERS
                normalized[0, TIMELINE_PREVIEW_CHARACTERS] + '...'
              else
                normalized
              end
    {characters: normalized.length, preview: preview}
  end

  # The raw timestamp string is kept only when it parses; unparseable or
  # missing values become nil and never abort anything.
  def self.timeline_safe_timestamp(value)
    return value if String === value && !value.empty? && timeline_parse_time(value)
    nil
  end

  def self.timeline_parse_time(value)
    return nil unless String === value && !value.empty?
    Time.parse(value)
  rescue ParameterException, TypeError
    nil
  end

  # Bursts are contiguous runs of the chronologically sorted bouts array; a
  # run ends when the elapsed gap between consecutive bouts exceeds
  # burst_gap.  A bout with no parseable timestamp never splits a run.
  # Each burst records the positions of its bouts in the sorted array
  # (first_bout/last_bout) so a detail request can inline exactly them
  # without inventing bout ids.
  def self.timeline_make_bursts(bouts, burst_gap)
    return [] if bouts.empty?
    bursts = []
    current = []
    current_first_position = 0
    bouts.each_with_index do |bout, position|
      if current.empty?
        current = [bout]
        current_first_position = position
        next
      end
      gap = timeline_bout_gap_seconds(current.last, bout)
      if gap && gap > burst_gap
        bursts << timeline_finalize_burst(bursts.length + 1, current, current_first_position, position - 1)
        current = [bout]
        current_first_position = position
      else
        current << bout
      end
    end
    bursts << timeline_finalize_burst(bursts.length + 1, current, current_first_position, bouts.length - 1)
    bursts
  end

  def self.timeline_bout_gap_seconds(previous, current)
    previous_time = timeline_parse_time(previous[:timestamp])
    current_time = timeline_parse_time(current[:timestamp])
    previous_time && current_time ? current_time - previous_time : nil
  end

  def self.timeline_finalize_burst(id, bouts, first_bout, last_bout)
    calls = bouts.flat_map { |bout| bout[:calls] }
    start_time = timeline_parse_time(bouts.first[:timestamp])
    end_time = timeline_parse_time(bouts.last[:timestamp])
    {
      id: id,
      start: bouts.first[:timestamp],
      end: bouts.last[:timestamp],
      duration_seconds: start_time && end_time ? (end_time - start_time).round(3) : nil,
      chats: bouts.map { |bout| bout[:chat] }.uniq,
      calls: calls.length,
      delegations: calls.count { |call| call[:delegated] },
      bouts: bouts.length,
      first_bout: first_bout,
      last_bout: last_bout
    }
  end
end
