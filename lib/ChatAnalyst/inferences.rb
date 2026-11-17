# lib/ChatAnalyst/inferences.rb
#
# Phase 3, plan step 3: the inference/activity-cluster model (user-approved
# spec; contract research/phase3-contract.md sections 1h/2B/2C as amended by
# C1/C2/C3).  Loaded from workflow.rb after api.rb (see research contract 5).
#
# PINNED SEMANTICS (real-chat evidence; probes b3_pin_layout_consolidated,
# b3_pin_ownership_decisive, b3_pin_reas_surface over the 3128-message
# ScoutCoder chat (1034 inference metas), the 1686-message port_neko chat
# (1133 metas) and the 1556-message FitAgent search chat (514 metas)):
#
# - LAYOUT (decisive; flips the work order's assumption): scout-ai UNSHIFTS
#   each inference meta BEFORE the response segment it accounts for
#   (default.rb process_response: `output.unshift({role: :meta, ...})`).
#   Persisted shape per inference: META, [assistant text when present], [its
#   tool calls], [outputs].  Real-file confirmation: dominant inter-meta
#   pattern `function_call_output > META > function_call` (1026/1034,
#   507/514, 1131/1133); execution timestamps sit closest to the PRECEDING
#   meta (1015:20, 240:15, 520:0).  The raw search chat literally opens
#   `meta: job=...` / `meta: ...inference_id=...` / `function_call:`.
# - Exactly ONE inference per non-job meta message (any 'meta' whose parsed
#   fields lack 'job'; job= projection markers own NOTHING).  Metas without
#   inference_id (legacy) still mark inferences.
# - Span: first = message right after the PREVIOUS inference meta in that
#   chat (chat's first message for the first), last = the meta itself.
#   Consecutive metas (reasoning-only rounds, 871/1133 in port_neko) yield
#   first == last == the meta.  A chat OPENING with a projection marker then
#   an inference meta (search chat) gives span [marker..meta], trigger nil.
# - trigger = the NEAREST PRECEDING non-meta message (the user message, or
#   the tool output the model reacts to); carry-over across consecutive
#   metas scans past them; nil when nothing precedes.
# - assistant = the meta's IMMEDIATE successor when its role is 'assistant'
#   (pinned: a present assistant ALWAYS sits right after its meta - 4/4,
#   1/1, 7/7 across the three chats; 0 assistants are directly followed by
#   a meta).
# - reasoning_present/characters from the META's 'reas' field ONLY (204/1034,
#   311/1133 metas carry it; assistant messages carry plain answer text).
#   Whitespace-normalized character count; content NEVER leaves this module.
# - Tool-call ownership (PINNED, opposite of the order's draft rule): a call
#   belongs to the inference meta that PRECEDES it in the same chat - its
#   EMITTER.  A call with NO preceding inference meta is unassociated (nil
#   inference_id); NO synthetic inference is ever created.
# - Clustering (C1): maximal runs of consecutive TIMESTAMPED inferences
#   (tree-wide chronological) with adjacent gaps <= max_gap_seconds; undated
#   inferences join no cluster and influence no gap; unclustered is real.

module ChatAnalyst
  INFERENCE_CACHE = {}
  INFERENCE_CACHE_MAX_ENTRIES = 32

  class << self
    # Tree-wide inference records for the provenance tree rooted at +root+
    # (chat path or chat-producing job path).  Universe: the OVERVIEW chats
    # (provenance closure; live log chats stay OUT - mutable copies, token
    # evidence owns dedup).  One record per inference meta in the frozen
    # chat_inferences field shape, tree-wide chronological order (undated
    # last, deterministic chat-then-index tiebreak).  No reasoning content
    # beyond presence/characters.
    def inferences(root, max_gap_seconds: 120)
      gap = check_max_gap!(max_gap_seconds)
      inference_computation(root, gap)[:records]
    end

    # ONE computation serving the cluster index and member lookup:
    # {root:, clusters:, cluster_map: {message_id -> cluster_id},
    #  summary: {inferences:, clusters:, unclustered:}} (+ warnings /
    # unloaded_references when nonempty).  Cluster index records:
    # {cluster_id, first_timestamp, last_timestamp, duration_seconds,
    #  inference_count, chats (canonical chat id list, chronological),
    #  tool_call_count, delegation_count} - NO chat_count (the chats list is
    # the identification; contract 3 decision 2 as amended by C3).
    def activity_clusters(root, max_gap_seconds: 120)
      gap = check_max_gap!(max_gap_seconds)
      computation = inference_computation(root, gap)
      result = {root: computation[:root],
                clusters: computation[:clusters],
                cluster_map: computation[:cluster_map],
                summary: computation[:summary]}
      result[:warnings] = computation[:warnings] if computation[:warnings].any?
      result[:unloaded_references] = computation[:unloaded_references] if computation[:unloaded_references].any?
      result
    end

    # Members of ONE cluster, chronological: validates +cluster_id+ against
    # the same (root, max_gap_seconds) computation.  Unknown/foreign-scope
    # ids raise ArgumentError here; the task layer maps ParameterException.
    def activity_cluster(root, cluster_id, max_gap_seconds: 120)
      gap = check_max_gap!(max_gap_seconds)
      computation = inference_computation(root, gap)
      members = computation[:members][cluster_id.to_s]
      unless members
        raise ArgumentError,
              "Unknown activity cluster #{cluster_id.inspect} for root #{computation[:root][:path]} (max_gap_seconds=#{max_gap_seconds}): cluster ids are the Message ids of clustered inferences"
      end
      members
    end

    private

    def check_max_gap!(max_gap_seconds)
      return max_gap_seconds.to_f if Numeric === max_gap_seconds && max_gap_seconds > 0
      raise ArgumentError, "Invalid max_gap_seconds #{max_gap_seconds.inspect}: must be a positive number of seconds"
    end

    # The shared computation, cached under the same freshness-identity
    # discipline as TIMELINE_CACHE (identity + max_gap_seconds, FIFO cap,
    # deep-copy on hit and store).
    def inference_computation(root, max_gap_seconds)
      root_kind, root_value = resolve_api_root(root, nil)
      identity = timeline_freshness_identity(root_kind, root_value)
      cache_key = [identity, max_gap_seconds]
      if (cached = INFERENCE_CACHE[cache_key])
        Marshal.load(Marshal.dump(cached))
      else
        computation = inference_build(root_kind, root_value, max_gap_seconds)
        INFERENCE_CACHE.shift if INFERENCE_CACHE.length >= INFERENCE_CACHE_MAX_ENTRIES
        INFERENCE_CACHE[cache_key] = Marshal.load(Marshal.dump(computation))
        computation
      end
    end

    # Full computation: traversal identical to timeline_build (same node
    # kinds, same with_provenance_run_cache), building inference records and
    # tool-call ownership per chat, then clustering tree-wide.
    def inference_build(root_kind, root_value, max_gap_seconds)
      records = []
      warnings = []
      unloaded = []
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
              records.concat(inference_records_for_chat(path, chat, graph))
              collect_missing_live(graph[:live], warnings)
              graph[:chats].values.flatten.uniq.each do |job_path|
                enqueue_node(queue, visited, :job, job_path,
                             from_kind: :chat, from_path: path, context: 'job reference')
              end
            else
              step = Step === node ? node : Step.load(node.to_s)
              path = Chat.provenance_path(:job, step)
              graph = Chat.provenance_graph(step, root_type: :job)
              collect_missing_live(graph[:live], warnings)
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

      records = inference_sort_records(records)
      cluster_records, members, cluster_map = inference_cluster_records(records, max_gap_seconds)
      {
        root: {type: root_kind, path: canonical_node_path(root_kind, root_value)},
        records: records,
        clusters: cluster_records,
        members: members,
        cluster_map: cluster_map,
        summary: {
          inferences: records.length,
          clusters: cluster_records.length,
          unclustered: records.count { |record| record[:activity_cluster_id].nil? }
        },
        warnings: warnings.uniq,
        unloaded_references: unloaded
      }
    end

    # Inference records of ONE chat, in file order, with tool-call counts
    # derived from the same ownership map the tool-call index uses (calls the
    # inference EMITTED - the pinned preceding-meta rule).
    def inference_records_for_chat(path, chat, graph)
      chat_id = Ids.chat_id(path)
      meta_indexes = []
      chat.each_with_index do |message, index|
        next unless message[:role].to_s == 'meta'
        meta_indexes << index unless Chat.parse_meta(message[:content].to_s).key?('job')
      end
      return [] if meta_indexes.empty?

      calls = timeline_call_records(chat, graph, path)
      calls_by_owner = Hash.new { |hash, key| hash[key] = [] }
      calls.each do |call|
        calls_by_owner[call[:inference_id]] << call if call[:inference_id]
      end

      previous_meta = -1
      meta_indexes.collect do |meta_index|
        fields = Chat.parse_meta(chat[meta_index][:content].to_s)
        reasoning = fields['reas'].to_s
        reasoning_present = !reasoning.strip.empty?

        # Span: first message after the previous inference's meta (or the
        # chat's first message) through the meta itself.  Consecutive metas
        # collapse to first == last == the meta (empty segment).
        first_index = previous_meta + 1
        # Trigger: nearest PRECEDING non-meta message (user request or the
        # tool output being reacted to); scans past consecutive metas
        # (carry-over); nil when nothing precedes the meta.
        trigger_index = nil
        (meta_index - 1).downto(0) do |index|
          if chat[index][:role].to_s != 'meta'
            trigger_index = index
            break
          end
        end
        # Assistant: the meta's immediate successor when it is an assistant
        # message (pinned: the response text always sits right after its
        # meta; tool-only and reasoning-only inferences have none).
        assistant_index = chat[meta_index + 1] && chat[meta_index + 1][:role].to_s == 'assistant' ? meta_index + 1 : nil
        # Timestamp: the meta's own timestamp, kept only when parseable.
        timestamp = timeline_safe_timestamp(fields['timestamp'])

        owned = calls_by_owner[Ids.message_id(path, meta_index)]
        record = {
          inference_id: Ids.message_id(path, meta_index),
          chat: path,
          chat_id: chat_id,
          meta_index: meta_index,
          timestamp: timestamp,
          reasoning_present: reasoning_present,
          reasoning_characters: reasoning_present ? reasoning.gsub(/\s+/, ' ').strip.length : 0,
          first_message_id: Ids.message_id(path, first_index),
          last_message_id: Ids.message_id(path, meta_index),
          trigger_message_id: trigger_index ? Ids.message_id(path, trigger_index) : nil,
          assistant_message_id: assistant_index ? Ids.message_id(path, assistant_index) : nil,
          activity_cluster_id: nil,
          tool_call_count: owned.length,
          delegated_call_count: owned.count { |call| call[:delegated] }
        }
        previous_meta = meta_index
        record
      end
    end

    # Tree-wide chronological order: parseable timestamp first, then chat
    # path, then meta index.  Undated/missing timestamps sort last,
    # deterministically (same discipline as timeline_sort_bouts).
    def inference_sort_records(records)
      records.sort_by do |record|
        time = timeline_parse_time(record[:timestamp])
        [time ? time.to_f : Float::INFINITY, record[:chat].to_s, record[:meta_index]]
      end
    end

    # C1 clustering: maximal runs of consecutive TIMESTAMPED records with
    # adjacent gaps <= max_gap_seconds; undated records join no run and
    # influence no gap.  Cluster id = first member's inference_id.  Returns
    # [cluster index records, {cluster_id -> members}, {message_id -> id}].
    def inference_cluster_records(records, max_gap_seconds)
      clusters = []
      members = {}
      cluster_map = {}
      current_members = []

      flush = lambda do
        break if current_members.empty?
        cluster_id = current_members.first[:inference_id]
        first_time = timeline_parse_time(current_members.first[:timestamp])
        last_time = timeline_parse_time(current_members.last[:timestamp])
        cluster = {
          cluster_id: cluster_id,
          first_timestamp: current_members.first[:timestamp],
          last_timestamp: current_members.last[:timestamp],
          duration_seconds: first_time && last_time ? (last_time - first_time).round(3) : nil,
          inference_count: current_members.length,
          chats: current_members.map { |record| record[:chat_id] }.uniq,
          tool_call_count: current_members.sum { |record| record[:tool_call_count] },
          delegation_count: current_members.sum { |record| record[:delegated_call_count] }
        }
        clusters << cluster
        members[cluster_id] = current_members
        current_members.each { |record| cluster_map[record[:inference_id]] = cluster_id }
        current_members = []
      end

      previous_time = nil
      records.each do |record|
        time = timeline_parse_time(record[:timestamp])
        if time.nil?
          # C1: undated inference participates in NO cluster and influences
          # no gap computation - it never bridges two distant clusters.
          flush.call
          next
        end
        flush.call if previous_time && (time - previous_time) > max_gap_seconds
        current_members << record
        previous_time = time
      end
      flush.call

      # Attach cluster ids to the member records themselves (records are
      # shared objects with the :records list).
      members.each_value do |cluster_members|
        cluster_members.each { |record| record[:activity_cluster_id] = cluster_members.first[:inference_id] }
      end
      [clusters, members, cluster_map]
    end
  end
end
