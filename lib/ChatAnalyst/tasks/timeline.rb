
# Additive ChatAnalyst implementation of a chronological work timeline.
# Add `require 'time'` near the top of workflow.rb if it is not already present.
#
# Intended to be added inside module ChatAnalyst, before export_exec.
# It deliberately reuses existing ChatAnalyst helpers:
#   provenance_data, short_path_from_path, short_address, chat_tool_calls,
#   target_agent, target_conversation
#
# Design:
#   * work segments = one persisted `meta:` response segment
#   * tool events = calls within those segments
#   * bursts = deterministic runs of similar tool groups
#   * phases = coarse candidate phases inferred from strong/combined
#               breakpoint signals; they are explicitly heuristic
#   * reasoning = compact preview + fingerprint by default; full text is opt-in
#   * delegation = first-class links from parent calls to agent_job children
#   * resources = conservative extraction of path-like tool arguments

module ChatAnalyst
  TIMELINE_REASONING_PREVIEW = 240
  TIMELINE_PHASE_GAP_SECONDS = 300
  TIMELINE_BURST_GAP_SECONDS = 120
  TIMELINE_REASONING_SHIFT_THRESHOLD = 0.12
  TIMELINE_MIN_REASONING_WORDS = 8

  TIMELINE_DEFAULT_GROUPS = {
    'analysis'   => %w[chat_report chat_overview chat_tool_calls message_index message_content
                     meta_evidence chat_reasoning chat_agents chat_accounting provenance_relationships],
                     'search'     => %w[search web_search],
                     'discover'   => %w[list_directory glob find grep locate],
                     'read'       => %w[read cortex_read cat load_file open_file],
                     'write'      => %w[write edit patch cortex_write cortex_edit],
                     'execute'    => %w[bash ruby run execute shell command],
                     'delegate'   => %w[ask cortex_continue cortex_brief hand_off_to_*],
                     'communicate'=> %w[post_inbox_advice],
                     'other'      => []
  }.freeze

  # Parse `search=search;discover=list_directory,find;read=read,cortex_read;write=write,edit`.
  helper :parse_timeline_groups do |value|
    groups = Marshal.load(Marshal.dump(TIMELINE_DEFAULT_GROUPS))
    return groups unless value && !value.to_s.strip.empty?

    explicit = {}
    value.to_s.split(';').each do |definition|
      name, tools = definition.split('=', 2)
      next unless name && tools
      name = name.strip
      explicit[name] = tools.split(',').map(&:strip).reject(&:empty?)
    end

    explicit.each { |name, tools| groups[name] = tools }
    groups
  end

  helper :timeline_tool_match? do |tool, pattern|
    tool = tool.to_s
    pattern = pattern.to_s
    pattern.end_with?('*') ? tool.start_with?(pattern[0...-1]) : tool == pattern
  end

  helper :timeline_tool_groups do |tool, groups|
    matched = groups.select do |_group, patterns|
      patterns.any? { |pattern| timeline_tool_match?(tool, pattern) }
    end.keys
    matched.empty? ? ['other'] : matched
  end

  helper :timeline_primary_group do |groups, preferred_order|
    preferred_order.find { |name| groups.include?(name) } || groups.first || 'other'
  end

  helper :timeline_reasoning_summary do |reasoning, full: false|
    return nil unless String === reasoning && !reasoning.empty?

    normalized = reasoning.to_s.gsub(/\s+/, ' ').strip
    words = normalized.downcase.scan(/[[:alnum:]_'-]+/)
    # A short stable fingerprint is useful for cross-referencing without
    # emitting large reasoning traces into the normal timeline report.
    fingerprint = Digest::SHA256.hexdigest(normalized)[0, 16]
    result = {
      fingerprint: fingerprint,
      characters: normalized.length,
      words: words.length,
      preview: normalized.length > TIMELINE_REASONING_PREVIEW ?
      normalized[0, TIMELINE_REASONING_PREVIEW] + '...' : normalized
    }
    result[:text] = normalized if full
    result
  end

  helper :timeline_reasoning_tokens do |reasoning|
    return [] unless String === reasoning
    reasoning.downcase.scan(/[[:alnum:]_'-]+/)
      .reject { |word| word.length < 3 }
      .uniq
  end

  # Jaccard similarity over reasoning vocabulary. This is deliberately a weak
  # signal: it suggests a breakpoint but never claims semantic understanding.
  helper :timeline_reasoning_similarity do |left, right|
    a = timeline_reasoning_tokens(left)
    b = timeline_reasoning_tokens(right)
    return nil if a.length < TIMELINE_MIN_REASONING_WORDS || b.length < TIMELINE_MIN_REASONING_WORDS
    union = (a | b)
    return 1.0 if union.empty?
    (a & b).length.to_f / union.length
  end

  helper :timeline_parse_arguments do |arguments|
    case arguments
    when Hash
      arguments
    when String
      JSON.parse(arguments)
    else
      {}
    end
  rescue JSON::ParserError
    {}
  end

  # Conservative path/resource extraction from tool arguments. This intentionally
  # avoids pretending to understand arbitrary tool schemas. It catches common
  # path-bearing argument names and obvious path-like values.
  helper :timeline_resource_value? do |value|
    return false unless String === value
    value = value.strip
    return false if value.empty? || value.length > 2048
    return false if value.start_with?('http://', 'https://')
    value.start_with?('/', '~/','./','../','.scout/','.git/') ||
      value.match?(%r{(^|/)[^/]+\.(rb|md|txt|json|yaml|yml|tsv|csv|chat|log|py|sh|r|R|html|pdf|png|jpg|jpeg)$}) ||
      value.match?(%r{^[A-Za-z0-9_.:-]+/[A-Za-z0-9_.:/-]+$})
  end

  # Keep opaque IDs but omit filesystem-like public selectors.
  helper :timeline_public_identifier do |value|
    return nil unless String === value
    candidate = value.strip
    # Selector values are identifiers, not navigation paths. Treat every
    # separator-bearing form as path-like (including relative paths such as
    # "repo/private" and agent selectors such as "repo/Worker"). This is
    # deliberately conservative: opaque, single-component IDs remain intact.
    path_like = candidate.empty? || candidate.match?(%r{[/\\]}) ||
      candidate.start_with?('~') || candidate.match?(%r{^[A-Za-z]:}) ||
      candidate.match?(%r{\A\.{1,2}(?:$|[\\\\/])}) ||
      candidate.match?(%r{\.(rb|md|txt|json|ya?ml|tsv|csv|chat|log|py|sh|r|R|html|pdf|png|jpe?g)$}i)
    path_like ? nil : value
  end

  helper :timeline_resources_from_arguments do |arguments|
    hash = timeline_parse_arguments(arguments)
    results = []
    path_keys = /\A(path|file|files|directory|dir|source|destination|target|input|output)\z/i

    walk = lambda do |value, key=nil|
      case value
      when Hash
        value.each { |k, v| walk.call(v, k.to_s) }
      when Array
        value.each { |v| walk.call(v, key) }
      when String
        if key && key.match?(path_keys) && timeline_resource_value?(value)
          # Keep a useful resource indicator without publishing the private path.
          results << {key: key, kind: :path}
        end
      end
    end

    walk.call(hash)
    results.uniq { |item| [item[:key], item[:kind]] }
  end

  helper :timeline_call_output_size do |chat, call|
    output_index = call[:output_index]
    return nil unless output_index
    message = chat[output_index]
    return nil unless message
    content = message[:content].to_s
    content.empty? ? 0 : content.length
  end

  # Map `call_id` -> agent_job edge details, using provenance only.
  helper :timeline_delegation_map do |edges|
    edges.each_with_object(Hash.new { |h, k| h[k] = [] }) do |edge, result|
      next unless edge[:relation].to_s == 'agent_job'
      detail = edge[:detail]
      next unless Hash === detail && detail[:call_id]
      result[detail[:call_id]] << detail
    end
  end

  helper :timeline_agent_meta_by_call do |chat, path|
    warnings = []
    Chat.agent_meta_evidence(chat, source: path, warnings: warnings)
      .group_by { |record| record[:call_id] }
  end

  # Build the persisted `meta:` response segments of one chat. A segment starts
  # at a meta message and ends at the next meta/user/system message or EOF.
  # Build response/work segments for one chat. Meta records enrich the timeline,
  # but are deliberately NOT required for tool events to exist. Some persisted or
  # legacy chats can have tool calls without a directly recoverable chat_meta
  # segment; those calls become implicit segments and remain visible.
  helper :timeline_segments_for_chat do |path, chat, call_entries, full_reasoning: false|
    meta_records = Chat.meta_evidence(chat, source: path)
    meta_by_index = {}
    meta_records.each do |record|
      next unless record[:origin].to_s == 'chat_meta'
      address = record[:meta_address]
      next unless Array === address
      index = address[1]
      next unless Integer === index
      meta_by_index[index] = record
    end

    explicit_starts = meta_by_index.keys.sort
    boundaries = []
    explicit_starts.each_with_index do |start_index, i|
      ending = i + 1 < explicit_starts.length ? explicit_starts[i + 1] - 1 : chat.length - 1
      boundary = (start_index + 1..ending).find do |idx|
        role = chat[idx][:role].to_s
        %w[user system].include?(role)
      end
      ending = boundary - 1 if boundary
      boundaries << [start_index, ending]
    end

    # Associate each persisted call with the most recent explicit meta segment
    # that actually contains its call message. Calls outside such a segment are
    # still retained in implicit segments keyed by call index.
    explicit = boundaries.each_with_object([]) do |(start_index, ending), arr|
      meta = meta_by_index[start_index]
      reasoning = meta[:meta] && meta[:meta][:reas]
      timestamp = meta[:meta] && meta[:meta][:timestamp]
      trigger = nil
      j = start_index - 1
      while j >= 0
        role = chat[j][:role].to_s
        if %w[user system].include?(role)
          trigger = {
            address: "#{short_path_from_path(path)}##{j}",
            role: role,
            content: chat[j][:content].to_s,
            characters: chat[j][:content].to_s.length
          }
          break
        end
        j -= 1
      end

      assistants = (start_index..ending).select { |idx| chat[idx][:role].to_s == 'assistant' }
      assistant = assistants.last
      calls = call_entries.select do |call|
        idx = call[:call_index]
        Integer === idx && idx >= start_index && idx <= ending
      end

      arr << {
        start_index: start_index,
        end_index: ending,
        explicit: true,
        id: "#{short_path_from_path(path)}##{start_index}",
        chat: short_path_from_path(path),
        timestamp: timestamp || calls.map { |c| c[:timestamp] }.compact.min,
        trigger: trigger,
        reasoning: timeline_reasoning_summary(reasoning, full: full_reasoning),
        reasoning_text_internal: reasoning,
        assistant: assistant ? {
          address: "#{short_path_from_path(path)}##{assistant}",
          preview: chat[assistant][:content].to_s.gsub(/\s+/, ' ')[0, 320],
          characters: chat[assistant][:content].to_s.length
        } : nil,
        calls: calls,
        message_count: ending >= start_index ? ending - start_index + 1 : 0
      }
    end

    assigned_call_indexes = explicit.flat_map { |segment| segment[:calls].map { |call| call[:call_index] } }.to_set

    # Calls not covered by explicit meta segments remain visible in deterministic
    # implicit segments. Use the nearest preceding user/system as their trigger.
    implicit_calls = call_entries.reject { |call| assigned_call_indexes.include?(call[:call_index]) }
    implicit = implicit_calls.group_by do |call|
      idx = call[:call_index].to_i
      trigger_index = nil
      (idx - 1).downto(0) do |j|
        role = chat[j][:role].to_s
        if %w[user system].include?(role)
          trigger_index = j
          break
        end
      end
      trigger_index || :root
    end.map do |trigger_index, calls|
      trigger = if Integer === trigger_index
                  {
                    address: "#{short_path_from_path(path)}##{trigger_index}",
                    role: chat[trigger_index][:role].to_s,
                    content: chat[trigger_index][:content].to_s,
                    characters: chat[trigger_index][:content].to_s.length
                  }
                end
      first_call = calls.min_by { |call| call[:call_index].to_i }
      last_call = calls.max_by { |call| call[:output_index].to_i }
      {
        start_index: first_call[:call_index],
        end_index: last_call[:output_index] || last_call[:call_index],
        explicit: false,
        id: "#{short_path_from_path(path)}#implicit-#{first_call[:call_index]}",
        chat: short_path_from_path(path),
        timestamp: calls.map { |c| c[:timestamp] }.compact.min,
        trigger: trigger,
        reasoning: nil,
        assistant: nil,
        calls: calls,
        message_count: calls.length
      }
    end

    # Preserve reasoning-only explicit segments as well as call-bearing ones.
    (explicit + implicit).sort_by do |segment|
      [segment[:timestamp] ? Time.parse(segment[:timestamp].to_s).to_f : Float::INFINITY,
       segment[:start_index].to_i]
    end
  end

  helper :timeline_parent_delegations do |edges|
    map = Hash.new { |h, k| h[k] = [] }
    edges.each do |edge|
      next unless edge[:relation].to_s == 'agent_job'
      detail = edge[:detail]
      next unless Hash === detail && detail[:call_id]
      job = edge[:to]
      delegated_subtree_chats(edges, job).each do |chat|
        map[File.expand_path(chat.to_s)] << {
          parent_chat: edge[:from],
          call_id: detail[:call_id],
          tool_name: detail[:tool_name],
          output_address: detail[:output_address],
          evidence_address: detail[:evidence_address],
          job: detail[:job] || edge[:to]
        }
      end
    end
    map.each_value { |items| items.uniq! }
    map
  end

  helper :timeline_compact_call do |call|
    {
      tool: call[:tool],
      call_id: call[:call_id],
      call_index: call[:call_index],
      output_index: call[:output_index],
      call_address: call[:call_address],
      output_address: call[:output_address],
      timestamp: call[:timestamp] || call[:start_timestamp],
      end_timestamp: call[:end_timestamp] || call[:timestamp],
      success: call[:success],
      error: call[:error],
      status_reason: call[:status_reason],
      groups: call[:groups],
      primary_group: call[:primary_group],
      output_characters: call[:output_characters],
      resources: call[:resources],
      target_agent: call[:target_agent],
      conversation: call[:conversation],
      delegation: call[:delegation]
    }.reject { |_k, v| v.nil? }
  end


  # Build compact work segments. The fundamental timeline unit is one persisted
  # response segment/inference, not an individual tool call. Tool calls are nested
  # inside the segment, and tool-group changes alone never create a new phase.
  helper :timeline_build_segments do |provenance, groups, full_reasoning: false|
    preferred_order = %w[analysis search discover read write execute delegate communicate other].select { |name| groups.key?(name) }
    delegation_map = timeline_delegation_map(provenance[:edges])
    parent_delegations = timeline_parent_delegations(provenance[:edges])
    segments = []

    provenance[:chats].each do |path, chat|
      raw_calls = Chat.tool_calls(chat, source: path)
      calls = chat_tool_calls(chat, path, events: provenance[:events])
      calls_by_id = calls.each_with_object({}) { |call, h| h[call[:call_id]] = call if call[:call_id] }
      agent_meta_by_call = timeline_agent_meta_by_call(chat, path)

      call_entries = raw_calls.collect do |raw|
        compact = calls_by_id[raw[:call_id]] || {}
        status = Chat.tool_call_status(raw)
        tool = raw[:name].to_s
        matched_groups = timeline_tool_groups(tool, groups)
        primary = timeline_primary_group(matched_groups, preferred_order)
        delegations = delegation_map[raw[:call_id]] || []
        resources = timeline_resources_from_arguments(raw[:arguments])
        output_chars = timeline_call_output_size(chat, raw)

        {
          tool: tool,
          call_id: raw[:call_id],
          call_index: raw[:call_index],
          output_index: raw[:output_index],
          call_address: "#{short_path_from_path(path)}##{raw[:call_index]}",
          output_address: raw[:output_index] && "#{short_path_from_path(path)}##{raw[:output_index]}",
          timestamp: status[:start_timestamp] || status[:timestamp],
          end_timestamp: status[:timestamp],
          success: status[:success],
          error: status[:error],
          status_reason: status[:reason],
          groups: matched_groups,
          primary_group: primary,
          arguments: raw[:arguments],
          resources: resources,
          output_characters: output_chars,
          delegation: delegations,
          target_agent: timeline_public_identifier(compact[:target_agent] || target_agent(raw)),
          conversation: timeline_public_identifier(compact[:conversation] || target_conversation(raw)),
          parent_delegations: parent_delegations[File.expand_path(path.to_s)]
        }.reject { |_k, v| v.nil? }
      end

      raw_segments = timeline_segments_for_chat(path, chat, call_entries, full_reasoning: full_reasoning)

      raw_segments.each_with_index do |segment, segment_index|
        segment_calls = segment[:calls]
        delegations = segment_calls.flat_map { |call| Array(call[:delegation]) }
        failures = segment_calls.select { |call| call[:success] == false }
        resources = segment_calls.flat_map { |call| Array(call[:resources]) }.uniq
        groups_used = segment_calls.flat_map { |call| Array(call[:groups]) }.uniq
        primary_counts = segment_calls.each_with_object(Hash.new(0)) do |call, counts|
          counts[call[:primary_group] || 'other'] += 1
        end
        dominant = primary_counts.max_by { |_group, count| count }&.first || 'analysis'
        output_chars = segment_calls.sum { |call| call[:output_characters].to_i }

        reasoning = segment[:reasoning]
        # Keep raw reasoning available internally for breakpoint computation but
        # never expose it unless full_reasoning was explicitly requested.
        raw_reasoning = segment[:reasoning_text_internal]

        events_for_delegation_reasoning = []
        segment_calls.each do |call|
          receipt_records = agent_meta_by_call[call[:call_id]] || []
          delegation_reasoning = receipt_records.filter_map do |record|
            text_value = record[:meta] && record[:meta][:reas]
            next unless text_value
            timeline_reasoning_summary(text_value, full: full_reasoning).merge(
              origin: :agent_meta,
              tool_name: record[:tool_name],
              evidence_address: short_address(record[:evidence_address])
            )
          end
          call[:delegation_reasoning] = delegation_reasoning unless delegation_reasoning.empty?
          events_for_delegation_reasoning.concat(delegation_reasoning)
        end

        segments << {
          type: :work_segment,
          id: segment[:id],
          index: segment_index,
          timestamp: segment[:timestamp],
          chat: segment[:chat],
          actor: segment[:chat],
          explicit: segment[:explicit],
          start_index: segment[:start_index],
          end_index: segment[:end_index],
          trigger: segment[:trigger],
          reasoning: reasoning,
          reasoning_text_internal: raw_reasoning,
          assistant: segment[:assistant],
          calls: segment_calls.map { |call| timeline_compact_call(call).merge(delegation_reasoning: call[:delegation_reasoning]).reject { |_k, v| v.nil? || (Array === v && v.empty?) } },
          call_count: segment_calls.length,
          failure_count: failures.length,
          output_characters: output_chars,
          resources: resources,
          delegations: delegations,
          groups: groups_used,
          primary_group: dominant,
          primary_group_counts: primary_counts,
          parent_delegations: parent_delegations[File.expand_path(path.to_s)],
          delegation_reasoning: events_for_delegation_reasoning,
          message_count: segment[:message_count]
        }
      end
    end

    segments.sort_by do |segment|
      timestamp = segment[:timestamp]
      [timestamp ? Time.parse(timestamp.to_s).to_f : Float::INFINITY,
       segment[:chat].to_s,
       segment[:start_index].to_i]
    end
  end

  helper :timeline_reasoning_breakpoint do |previous, current|
    return nil unless previous && current
    return nil unless previous[:chat] == current[:chat]

    left = previous[:reasoning_text_internal]
    right = current[:reasoning_text_internal]
    similarity = timeline_reasoning_similarity(left, right)
    return nil unless similarity
    return nil unless similarity < TIMELINE_REASONING_SHIFT_THRESHOLD
    {
      type: :reasoning_shift,
      similarity: similarity.round(4),
      strength: :suggestive
    }
  end

  helper :timeline_segment_breakpoint_signals do |previous, current, phase_gap: TIMELINE_PHASE_GAP_SECONDS|
    signals = []
    return signals unless previous

    previous_time = previous[:timestamp] && Time.parse(previous[:timestamp].to_s).to_f
    current_time = current[:timestamp] && Time.parse(current[:timestamp].to_s).to_f
    gap = previous_time && current_time ? current_time - previous_time : nil
    signals << {type: :long_gap, strength: :strong, seconds: gap.round(3)} if gap && gap > phase_gap.to_f
    # `actor` is always set from the chat file (see timeline_build_segments), so
    # a chat change and an actor change are the same event; only chat_change is
    # reported. The segment `actor` field itself stays: bursts aggregate it.
    if previous[:chat] != current[:chat]
      signals << {type: :chat_change, strength: :weak}
    end

    previous_delegations = Array(previous[:delegations])
    current_delegations = Array(current[:delegations])
    if previous_delegations.any? || current_delegations.any?
      signals << {
        type: :delegation,
        strength: :strong,
        direction: current_delegations.any? ? :out : :resume_or_child
      }
    end

    if previous[:failure_count].to_i > 0 && current[:failure_count].to_i == 0
      signals << {type: :failure_recovery, strength: :strong}
    end
    if current[:failure_count].to_i > 0 && previous[:failure_count].to_i == 0
      signals << {type: :failure, strength: :moderate}
    end

    reasoning = timeline_reasoning_breakpoint(previous, current)
    signals << reasoning if reasoning

    if previous[:primary_group] != current[:primary_group]
      signals << {
        type: :tool_group_change,
        strength: :weak,
        from: previous[:primary_group],
        to: current[:primary_group]
      }
    end
    signals
  end

  # Session-level bursts are temporal activity windows.  Chat/actor changes do
  # NOT split a burst: delegated workers commonly operate concurrently with the
  # manager, and a useful timeline should show that activity together.  Only a
  # sufficiently long idle gap starts a new burst.
  helper :timeline_make_bursts_v6 do |segments, burst_gap: TIMELINE_BURST_GAP_SECONDS|
    return [] if segments.empty?

    bursts = []
    current_segments = []
    burst_id = 0

    segments.each do |segment|
      if current_segments.empty?
        current_segments << segment
        next
      end

      previous = current_segments.last
      previous_time = previous[:timestamp] && Time.parse(previous[:timestamp].to_s).to_f
      current_time = segment[:timestamp] && Time.parse(segment[:timestamp].to_s).to_f
      gap = previous_time && current_time ? current_time - previous_time : 0

      if gap > burst_gap.to_f
        burst_id += 1
        bursts << timeline_finalize_burst_v6(burst_id, current_segments)
        current_segments = [segment]
      else
        current_segments << segment
      end
    end

    burst_id += 1
    bursts << timeline_finalize_burst_v6(burst_id, current_segments)
    bursts
  end

  helper :timeline_finalize_burst_v6 do |id, segments|
    calls = segments.flat_map { |segment| segment[:calls] }
    group_counts = calls.each_with_object(Hash.new(0)) do |call, counts|
      counts[call[:primary_group] || 'other'] += 1
    end
    dominant = group_counts.max_by { |_group, count| count }&.first || 'other'

    {
      id: id,
      start: segments.first[:timestamp],
      end: segments.last[:timestamp],
      chats: segments.map { |segment| segment[:chat] }.uniq,
      actors: segments.map { |segment| segment[:actor] }.uniq,
      primary_group: dominant,
      group_counts: group_counts,
      groups: calls.flat_map { |call| Array(call[:groups]) }.uniq,
      segments: segments.map { |segment| segment[:id] },
      call_count: calls.length,
      failure_count: segments.sum { |segment| segment[:failure_count].to_i },
      output_characters: segments.sum { |segment| segment[:output_characters].to_i },
      delegations: segments.flat_map { |segment| segment[:delegations] }.uniq,
      resources: segments.flat_map { |segment| segment[:resources] }.uniq,
      reasoning_fingerprints: segments.filter_map { |segment| segment[:reasoning] && segment[:reasoning][:fingerprint] }.uniq,
      reasoning_shifts: segments.sum { |segment| Array(segment[:breakpoint_signals]).count { |signal| signal[:type].to_s == 'reasoning_shift' } },
      event_indices: (segments.first[:index]..segments.last[:index]).to_a,
      duration_seconds: begin
                          first = segments.first[:timestamp] && Time.parse(segments.first[:timestamp].to_s).to_f
                          last = segments.last[:timestamp] && Time.parse(segments.last[:timestamp].to_s).to_f
                          first && last ? (last - first).round(3) : nil
      end
    }
  end


  # Compute identity immediately before the public workflow job is created. It is
  # deliberately scoped to the provenance-reachable closure: typed edges, each
  # reachable chat's bytes, and each reachable job's result/info bytes. That
  # makes unrelated workspace changes irrelevant while edits or new relations
  # change the ordinary Scout task input digest.
  helper :timeline_closure_identity do |file|
    root_kind, root = resolve_root(file)
    edges = Chat.provenance_edges(root, root_type: root_kind)
    chat_paths = Chat.provenance_chat_files(root, root_type: root_kind).map { |path| File.expand_path(path.to_s) }.uniq.sort
    jobs = Chat.provenance_jobs(root, root_type: root_kind)
    job_paths = jobs.map { |job| File.expand_path(Chat.provenance_path(:job, job).to_s) }.uniq.sort

    edge_rows = edges.map do |edge|
      detail = edge[:detail]
      detail_data = if Hash === detail
                      detail.keys.sort_by(&:to_s).map { |key| [key.to_s, detail[key].to_s] }
                    end
      [edge[:from_kind].to_s, Chat.provenance_path(edge[:from_kind], edge[:from]).to_s,
       edge[:relation].to_s, edge[:to_kind].to_s,
       Chat.provenance_path(edge[:to_kind], edge[:to]).to_s, detail_data]
    end.sort_by { |row| JSON.generate(row) }

    file_rows = (chat_paths.map { |path| [:chat, path] } +
                 job_paths.flat_map { |path| [[:job_result, path], [:job_info, path + '.info']] }).map do |kind, path|
                   digest = if File.file?(path)
                              Digest::SHA256.file(path).hexdigest
                            else
                              'missing'
                            end
                   [kind.to_s, path, digest]
                 end

    Digest::SHA256.hexdigest(JSON.generate([
      root_kind.to_s, Chat.provenance_path(root_kind, root).to_s,
      edge_rows, file_rows
    ]))
  end

  # The index is intentionally not exported as a tool. Its closure key is an
  # internal Scout input, and its result contains only compact metadata required
  # for overview/detail projection (never raw chat bodies or tool outputs).
  input :file, :path, 'Root chat file or chat-producing job', nil, required: true, jobname: true, nofile: true
  input :closure_identity, :string, 'Internal identity of the reachable provenance closure', nil, required: true, nofile: true
  input :groups, :string, 'Optional tool-group profile', nil, nofile: true
  input :burst_gap, :float, 'Elapsed seconds between segments that starts a new burst', TIMELINE_BURST_GAP_SECONDS, nofile: true
  task :timeline_index => :json do |file, closure_identity, groups, burst_gap|
    provenance = provenance_data(file)
    tool_groups = parse_timeline_groups(groups)
    segments = timeline_build_segments(provenance, tool_groups, full_reasoning: false)

    # Signals annotate changes but only elapsed time creates burst boundaries.
    # Attach them before building bursts so burst finalization can aggregate
    # them (e.g. reasoning_shifts); segment mutation is in-place and harmless
    # to burst construction itself.
    previous = nil
    segments.each do |segment|
      segment[:breakpoint_signals] = timeline_segment_breakpoint_signals(previous, segment)
      previous = segment
    end
    bursts = timeline_make_bursts_v6(segments, burst_gap: burst_gap.to_f)

    delegations = provenance[:edges].filter_map do |edge|
      next unless edge[:relation].to_s == 'agent_job'
      detail = edge[:detail]
      next unless Hash === detail
      {
        parent_chat: short_path_from_path(edge[:from]),
        call_id: detail[:call_id],
        tool_name: detail[:tool_name],
        output_address: detail[:output_address] && short_address(detail[:output_address]),
        evidence_address: detail[:evidence_address] && short_address(detail[:evidence_address])
      }.reject { |_key, value| value.nil? }
    end.uniq

    total_calls = segments.sum { |segment| segment[:call_count].to_i }
    summary = {
      segments: segments.length,
      tool_events: total_calls,
      bursts: bursts.length,
      chats: provenance[:chats].length,
      failures: segments.sum { |segment| segment[:failure_count].to_i },
      delegations: delegations.length,
      resources: segments.sum { |segment| Array(segment[:resources]).length }
    }
    signals_by_burst = bursts.to_h do |burst|
      burst_segments = segments.select { |segment| Array(burst[:segments]).include?(segment[:id]) }
      [burst[:id], burst_segments.flat_map { |segment| Array(segment[:breakpoint_signals]) }.uniq]
    end

    # Keep the persisted shared index free of message bodies, reasoning previews,
    # arbitrary tool arguments and outputs. Those are not timeline evidence.
    compact_segments = segments.map do |segment|
      segment.reject { |key, _| %i[reasoning_text_internal trigger assistant].include?(key) }
        .merge(reasoning: segment[:reasoning]&.slice(:fingerprint, :characters, :words))
        .merge(calls: Array(segment[:calls]).map do |call|
          call.reject { |key, _| key == :output_characters }
        end)
    end

    {
      root_kind: provenance[:root_kind], summary: summary, segments: compact_segments,
      bursts: bursts, signals_by_burst: signals_by_burst, delegations: delegations
    }
  end

  # Public schema: no closure key, no internal index task, and one `bursts` array
  # for either an overview (empty/omitted) or a batched detail request.
  input :file, :path, 'Root chat file or chat-producing job', nil, required: true, nofile: true
  input :groups, :string, 'Optional tool-group profile', nil, nofile: true
  input :burst_gap, :float, 'Elapsed seconds between segments that starts a new burst', TIMELINE_BURST_GAP_SECONDS, nofile: true
  input :bursts, :array, 'Optional burst IDs for a batched detail request; omitted or empty returns overview', [], nofile: true
  desc 'Return a compact chronological timeline overview, or details for selected bursts. Evidence and provenance remain in their dedicated tasks.'
  dep compute: :produce do |_inputname, inputs|
    file = inputs[:file]
    raise ParameterException, "Input 'file' is required but was not provided or is nil" if file.nil?
    identity = helper(:timeline_closure_identity, file)
    ChatAnalyst.job(:timeline_index,
                    file: file,
                    closure_identity: identity,
                    groups: inputs[:groups],
                    burst_gap: inputs[:burst_gap] || TIMELINE_BURST_GAP_SECONDS)
  end
  task :chat_timeline => :json do |_file, _groups, _burst_gap, selected_bursts|
    index = IndiferentHash.setup(step(:timeline_index).load)
    selected_ids = Array(selected_bursts).flatten.compact.map(&:to_s).reject(&:empty?).uniq

    overview_bursts = Array(index[:bursts]).map do |burst|
      burst = IndiferentHash.setup(burst)
      {
        id: burst[:id], start: burst[:start], end: burst[:end],
        chats: burst[:chats], actors: burst[:actors],
        primary_group: burst[:primary_group], groups: burst[:groups],
        segments: Array(burst[:segments]).length, calls: burst[:call_count],
        failures: burst[:failure_count], resources: burst[:resources],
        reasoning_fingerprints: burst[:reasoning_fingerprints],
        breakpoint_signals: index[:signals_by_burst][burst[:id].to_s] || index[:signals_by_burst][burst[:id]]
      }
    end
    summary = IndiferentHash.setup(index[:summary] || {})
    result = {mode: selected_ids.empty? ? :overview : :detail,
              root: {kind: index[:root_kind]}, summary: summary,
              bursts: overview_bursts, delegations: index[:delegations]}

    unless selected_ids.empty?
      selected = selected_ids.map do |id|
        burst = Array(index[:bursts]).map { |candidate| IndiferentHash.setup(candidate) }.find { |candidate| candidate[:id].to_s == id }
        next unless burst
        burst_segments = Array(index[:segments]).map { |segment| IndiferentHash.setup(segment) }.select { |segment| Array(burst[:segments]).include?(segment[:id]) }
        {
          id: burst[:id], start: burst[:start], end: burst[:end],
          breakpoint_signals: index[:signals_by_burst][burst[:id].to_s] || index[:signals_by_burst][burst[:id]],
          segments: burst_segments.map do |segment|
            {
              id: segment[:id], chat: segment[:chat], timestamp: segment[:timestamp],
              start_index: segment[:start_index], end_index: segment[:end_index],
              reasoning: if segment[:reasoning]
                           reasoning = IndiferentHash.setup(segment[:reasoning])
                           {fingerprint: reasoning[:fingerprint], characters: reasoning[:characters], words: reasoning[:words]}.reject { |_key, value| value.nil? }
              end,
              resources: segment[:resources],
              calls: Array(segment[:calls]).map do |call|
                call = IndiferentHash.setup(call).to_hash
                call.slice(:tool, :call_id, :call_index, :output_index, :call_address,
                           :output_address, :timestamp, :end_timestamp, :success,
                           :error, :status_reason, :groups, :primary_group, :resources,
                           :target_agent, :conversation).merge(
                             delegation: Array(call[:delegation]).map do |link|
                               {call_id: link[:call_id], tool_name: link[:tool_name],
                                output_address: link[:output_address] && short_address(link[:output_address]),
                                evidence_address: link[:evidence_address] && short_address(link[:evidence_address]),
                                job: link[:job] && short_path_from_path(link[:job])}.reject { |_key, value| value.nil? }
                             end
                           )
              end
            }
          end
        }
      end.compact
      result[:selected_burst_ids] = selected_ids
      result[:bursts] = selected
    end
    result
  end

  export_exec :chat_timeline
end
