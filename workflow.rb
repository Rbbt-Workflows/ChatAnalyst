require 'scout-ai'
require 'json'
require 'set'
require 'digest'

module ChatAnalyst
  extend Workflow
  self.name = 'ChatAnalyst'

  TOKEN_KEYS = Chat::TOKEN_KEYS.map(&:to_sym).freeze

  # Delegation tools whose calls are agent interactions.  Any other tool
  # whose call carries agent_meta receipt records is still classified as a
  # delegation by the generic fallback in chat_tool_calls, so other suites'
  # delegation tools are never silently missed.
  DELEGATION_TOOLS = %w[ask cortex_continue cortex_brief].freeze

  # Relations followed when attributing delegated spend to a linked job: its
  # logs, results, further delegations, and nested jobs, but never
  # :dependency, which would attribute upstream jobs to the delegation.
  DELEGATION_SUBTREE_RELATIONS = %i[log result agent_job job].freeze

  helper :short_path do |path|
    path = File.expand_path(path.to_s)
    home = File.expand_path('~')
    path.start_with?(home + '/') ? "~#{path[home.length..]}" : path
  end

  # Addresses are [path, *rest] arrays (or [path, index, :agent_meta, i] for
  # receipt evidence). Shorten only the path element so reports stay readable
  # while remaining unique.
  helper :short_address do |address|
    return address unless Array === address && address.any?
    first = address.first
    rest = address[1..]
    first.nil? ? rest : [short_path(first.to_s), *rest]
  end

  # Fine-grained provenance: parse `follow:` inputs ("all", "job,log", ...) into
  # the core relation Array. Invalid values raise ParameterException before any
  # work starts, so a typo never produces a silently empty closure.
  helper :parse_follow do |value, what: 'follow'|
    return :all if value.nil? || value.to_s == 'all' || value.to_s.strip.empty?

    relations = value.to_s.split(/[,\s]+/).reject(&:empty?).collect(&:to_sym)
    raise ParameterException, "No valid relations in #{what}: #{value.inspect}" if relations.empty?

    unknown = relations - Chat::PROVENANCE_RELATIONS
    raise ParameterException, "Unknown #{what} relations: #{unknown * ', '}" if unknown.any?

    relations
  end

  # Fine-grained provenance, step 1: the chat-level reference *events* that
  # core provenance traversal deliberately ignores. Reading chats with
  # `Chat.load` (never compiled) keeps `import:`/`continue:`/`last:` messages
  # with their raw reference text, so the relationships can be recovered from
  # any persisted chat. Resolution reuses the same core helper
  # (`Chat.find_file`) used by `Chat.imports`, so an unresolved reference is
  # reported instead of raised.
  helper :chat_relationship_references do |path|
    chat = Chat.load(path)
    chat.each_with_index.filter_map do |message, index|
      type = message[:role].to_s
      next unless %w[import continue last].include?(type)

      reference = message[:content].to_s.strip
      found = Chat.find_file(reference, path)
      if found && !Open.remote?(found.to_s) && Open.exist?(found.to_s)
        {
          type: type.to_sym,
          reference: reference,
          message_index: index,
          resolved: true,
          target_kind: :chat,
          target: File.expand_path(found.to_s)
        }
      else
        # Remote references are kept with their text; local missing files are
        # reported as unresolved so accounting stays possible on damaged
        # sessions.
        {
          type: type.to_sym,
          reference: reference,
          message_index: index,
          resolved: false,
          target_kind: :chat,
          target: nil,
          unresolved_reason: Open.remote?(found.to_s) ? :remote : :missing
        }
      end
    end
  end

  # Import closure of one chat: post-order walk over resolved `import:`
  # references only (deepest/oldest first, root last). `continue:` and `last:`
  # are message-level references, not conversation boundaries, so they are
  # excluded from accounting attribution. Cycle-safe by keying on the expanded
  # path.
  helper :import_closure do |path|
    order = []
    seen = Set.new
    walk = lambda do |current|
      current = File.expand_path(current.to_s)
      return if seen.include?(current)
      seen << current
      chat_relationship_references(current).each do |relationship|
        next unless relationship[:type] == :import && relationship[:resolved]
        walk.call(relationship[:target])
      end
      order << current
    end
    walk.call(path)
    order
  end
  helper :resolve_root do |input|
    candidates = [input, "#{input}.chat", File.expand_path(input), File.expand_path("#{input}.chat")]
    begin
      candidates << Scout.chats[input].find
      candidates << Scout.chats[input].find_with_extension(:chat).find
    rescue
    end
    candidate = candidates.compact.find { |path| File.file?(path.to_s) }
    raise ParameterException, "Chat or job not found: #{input}" unless candidate

    path = File.expand_path(candidate.to_s)
    # A persisted Step always has an .info sidecar. A .files directory alone is
    # NOT evidence: saved agent chats carry one too. Only the .info test decides,
    # and the chat branch then relies on scout-ai provenance to scan the sidecar
    # for society conversations (relation :log).
    File.exist?(path + '.info') ? [:job, Step.load(path)] : [:chat, Path.setup(path)]
  end

  # Normalize one provenance problem into a compact, serializable warning
  # Hash. Accepts either the on_error callback arguments (error/kind/object/
  # relation/reference) or an already-shaped Hash pushed by the Scout-AI
  # collectors (receipt problems, identity conflicts).
  helper :normalize_provenance_warning do |entry, kind: nil, relation: nil, path: nil, error: nil|
    reference = entry[:reference] if Hash === entry
    source = entry[:source] if Hash === entry
    output_address = entry[:output_address] if Hash === entry
    evidence_address = entry[:evidence_address] if Hash === entry

    if Hash === reference
      output_address ||= reference[:output_address]
      evidence_address ||= reference[:evidence_address]
    end

    warning = {
      kind: entry[:kind] || kind,
      relation: entry[:relation] || relation,
      path: short_path(path || source || (Hash === reference && reference[:source])),
      reason: entry[:reason] || (Hash === reference && reference[:reason]),
      call_id: entry[:call_id] || (Hash === reference && reference[:call_id]),
      tool_name: entry[:tool_name] || (Hash === reference && reference[:tool_name]),
      output_address: output_address && short_address(output_address),
      evidence_address: evidence_address && short_address(evidence_address),
      reference: (String === entry[:reference] || String === reference) ? (entry[:reference] || reference).to_s : nil,
      error: error || entry[:message] || entry[:error]
    }
    # N1 rev3: an unresolved_job_reference without a String reference is a
    # reference-less failure (e.g. a traversal-stage on_error callback for an
    # agent_job edge whose reference Hash carries only structural facts).
    # Mark it instead of letting the nil reference flow downstream.
    if warning[:reason].to_s == 'unresolved_job_reference' && warning[:reference].nil?
      warning[:malformed] = true
    end
    warning[:identity] = entry[:identity] if entry[:identity]
    warning[:fields] = entry[:fields] if entry[:fields]
    warning[:values] = entry[:values] if entry[:values]
    warning.reject { |_key, value| value.nil? }
  end

  # Deduplication key for warnings: the same receipt problem is reported once
  # by the traversal stage and once by the token collector; keep one copy.
  helper :warning_key do |warning|
    [warning[:reason], warning[:relation], warning[:path], warning[:call_id],
     warning[:evidence_address], warning[:identity]]
  end

  # Collect the shared core traversal into plain task-local data. This is
  # report state for one task execution, not a Session/Graph domain object:
  # only Arrays and Hashes are returned, and every provenance, receipt, and
  # identity decision is delegated to the Scout-AI Chat APIs.
  #
  #   root_kind/root - resolved root (:chat path or :job Step)
  #   chats          - {absolute chat path => Chat}
  #   jobs           - {absolute job path => Step}
  #   edges          - normalized edges {from_kind, from, relation, to_kind, to, detail}
  #   events         - Chat.provenance_token_events output
  #   warnings       - deduplicated normalized provenance warnings
  helper :provenance_data do |file, follow = nil|
    @provenance_data ||= {}
    follow_relations = parse_follow(follow)
    memo_key = [file, follow_relations]
    @provenance_data[memo_key] ||= begin
      root_kind, root = resolve_root(file)
      traversal_options = follow_relations == :all ? {} : {follow: Array(follow_relations)}

      # Token events: source of truth for all accounting. Receipt problems and
      # identity conflicts are pushed into `warnings`; everything else goes
      # through on_error so analysis tasks keep working on damaged sessions.
      collector_warnings = []
      event_warnings = []
      on_error = lambda do |error, kind, object, relation, reference|
        collector_warnings << normalize_provenance_warning(
          {reference: reference, message: error.message},
          kind: kind, relation: relation,
          path: (Chat.provenance_path(kind, object) rescue object.to_s)
        )
      end
      events = Chat.provenance_token_events(root, root_type: root_kind, **traversal_options,
                                            warnings: event_warnings, on_error: on_error)

      edges = Chat.provenance_edges(root, root_type: root_kind, on_error: on_error,
                                    **traversal_options).collect do |edge|
        detail = edge[:detail]
        sanitized = nil
        if Hash === detail
          sanitized = {
            relation: :agent_job,
            from: short_path(Chat.provenance_path(edge[:from_kind], edge[:from])),
            to: short_path(Chat.provenance_path(edge[:to_kind], edge[:to])),
            call_id: detail[:call_id],
            tool_name: detail[:tool_name],
            output_address: detail[:output_address] && short_address(detail[:output_address]),
            evidence_address: detail[:evidence_address] && short_address(detail[:evidence_address]),
            job: detail[:job] && short_path(detail[:job])
          }.reject { |_key, value| value.nil? }
        end
        {
          from_kind: edge[:from_kind],
          from: short_path(Chat.provenance_path(edge[:from_kind], edge[:from])),
          relation: edge[:relation],
          to_kind: edge[:to_kind],
          to: short_path(Chat.provenance_path(edge[:to_kind], edge[:to])),
          detail: sanitized
        }
      end

      chat_files = Chat.provenance_chat_files(root, root_type: root_kind, on_error: on_error,
                                              **traversal_options)
      chats = chat_files.to_h { |path| [path, Chat.load(path)] }
      jobs = Chat.provenance_jobs(root, root_type: root_kind, on_error: on_error,
                                  **traversal_options)
                     .to_h { |job| [Chat.provenance_path(:job, job), job] }

      warnings = (event_warnings.collect { |entry| normalize_provenance_warning(entry) } + collector_warnings)
      seen = Set.new
      warnings = warnings.select { |warning| seen.add?(warning_key(warning)) }

      {
        root_kind: root_kind,
        root: short_path(Chat.provenance_path(root_kind, root)),
        chats: chats,
        jobs: jobs,
        edges: edges,
        events: events,
        warnings: warnings
      }
    end
  end

  helper :roles do |chat|
    chat.each_with_object(Hash.new(0)) do |message, counts|
      counts[message[:role].to_s] += 1
    end
  end

  # Sum already-deduplicated token events. This is plain arithmetic over the
  # collector output; no inference identity is recomputed here.
  helper :sum_events do |events|
    TOKEN_KEYS.each_with_object({}) do |key, totals|
      totals[key] = events.sum { |event| event[:tokens][key].to_i }
    end
  end

  # Evidence-coverage scopes, matching Chat.provenance_token_totals scopes:
  # chat_evidence and receipt_evidence overlap, receipt_only is the disjoint
  # delegated contribution with no saved child chat/log, and the
  # deduplicated_total is the only authoritative cost total.
  helper :scope_totals do |events|
    chat_side = events.select { |event| event[:evidence].any? { |item| item[:origin] == :chat_meta } }
    receipt_side = events.select { |event| event[:evidence].any? { |item| item[:origin] == :agent_meta } }
    receipt_only = events.select { |event| event[:evidence].all? { |item| item[:origin] == :agent_meta } }
    {
      deduplicated_total: sum_events(events),
      chat_evidence: sum_events(chat_side),
      receipt_evidence: sum_events(receipt_side),
      receipt_only: sum_events(receipt_only)
    }
  end

  # Events whose receipt evidence belongs to one tool call of one chat.
  # Matching uses only facts carried by the collector evidence records:
  # source path and call id (output/evidence addresses are retained in the
  # matched events for auditing).
  helper :events_for_call do |events, path, call_id|
    return [] unless call_id
    expanded = File.expand_path(path.to_s)
    events.select do |event|
      event[:evidence].any? do |item|
        item[:origin] == :agent_meta && item[:call_id] == call_id &&
          item[:source] && File.expand_path(item[:source].to_s) == expanded
      end
    end
  end

  helper :receipt_only_event? do |event|
    event[:evidence].all? { |item| item[:origin] == :agent_meta }
  end

  # Canonical evidence source path of an event (first evidence record's
  # source, or its meta address path), as an expanded filesystem path so it
  # can be compared with subtree chat sets.
  helper :canonical_event_source do |event|
    canonical = event[:evidence].first
    return nil unless canonical
    source = canonical[:source] || canonical[:meta_address]&.first
    source && File.expand_path(source.to_s)
  end

  # Collect the chat files reachable from a job through the delegation
  # subtree relations (logs, results, nested delegations, nested jobs), never
  # through :dependency: upstream jobs are not this delegation's cost.  The
  # edges are the normalized provenance edges; job nodes are matched by their
  # short_path form.  Returns expanded chat paths as a Set.
  helper :delegated_subtree_chats do |edges, job_path|
    target = short_path(job_path.to_s)
    subtree_chats = Set.new
    visited = Set.new
    queue = [target]
    until queue.empty?
      node = queue.shift
      next unless visited.add?(node)
      edges.each do |edge|
        next unless DELEGATION_SUBTREE_RELATIONS.include?(edge[:relation])
        next unless edge[:from] == node
        if edge[:to_kind] == :chat
          subtree_chats << File.expand_path(edge[:to].to_s)
        elsif edge[:to_kind] == :job
          queue << edge[:to]
        end
      end
    end
    subtree_chats
  end

  # Delegated spend attributed to a set of subtree chats: the
  # already-deduplicated events whose canonical evidence lives in those
  # chats.  Never re-sums raw evidence; returns [token totals, event count].
  helper :delegated_events do |events, subtree_chats|
    matched = events.select { |event| subtree_chats.include?(canonical_event_source(event)) }
    [sum_events(matched), matched.length]
  end

  # Shared pagination envelope, following the message_index shape: setting
  # page bounds only the main list of a report, never its totals, so any
  # paginated response doubles as a bounded summary. Returns nil when page is
  # nil so tasks keep their historical unpaginated shape.
  helper :paginate_items do |items, page, per_page|
    next nil unless page

    per_page = (per_page || 50).to_i
    per_page = 1 if per_page < 1
    page = page.to_i
    total = items.length
    total_pages = (total.to_f / per_page).ceil
    total_pages = 1 if total_pages < 1
    page = 1 if page < 1

    offset = (page - 1) * per_page
    {
      page: page,
      per_page: per_page,
      total: total,
      total_pages: total_pages,
      next_page: page < total_pages ? page + 1 : nil,
      prev_page: page > 1 ? page - 1 : nil,
      items: items[offset, per_page] || []
    }
  end

  # Identity of one logical tool call: tool name, provider call id, and the
  # exact arguments. Socialized projections, result chats, and log copies of
  # one chat replay identical ids and arguments, so a repeated identity is a
  # persisted copy of the same call, never two independent calls. Provider
  # call ids are unique per conversation, which keeps distinct calls apart.
  helper :tool_call_identity do |call|
    Digest::MD5.hexdigest([call[:tool], call[:call_id], call[:arguments]].to_json)
  end

  # Mark repeated tool-call identities as copies of their first occurrence in
  # traversal order. Returns [marked calls, unique count]; marked copies carry
  # copy_of with the address of the first occurrence, retrievable through
  # message_content. The first occurrence itself is never marked.
  helper :mark_call_copies do |calls|
    canonical = {}
    unique = 0
    marked = calls.collect do |call|
      identity = tool_call_identity(call)
      first = canonical[identity]
      if first
        call.merge(copy_of: first)
      else
        unique += 1
        canonical[identity] = call[:call_address]
        call
      end
    end
    [marked, unique]
  end

  helper :target_agent do |call|
    name = call[:name].to_s
    return name.sub(/^hand_off_to_/, '') if name.start_with?('hand_off_to_')
    return nil unless DELEGATION_TOOLS.include?(name)

    arguments = call[:arguments]
    arguments = JSON.parse(arguments) if String === arguments
    return nil unless Hash === arguments
    # Raw value on purpose: 'Worker/brief-name' stays intact for consumers.
    arguments['agent'] || arguments[:agent] || arguments['agent_name'] || arguments[:agent_name] ||
      arguments['target'] || arguments[:target]
  rescue JSON::ParserError
    nil
  end

  helper :target_conversation do |call|
    arguments = call[:arguments]
    arguments = JSON.parse(arguments) if String === arguments
    return nil unless Hash === arguments
    arguments['chat'] || arguments[:chat] || arguments['conversation'] || arguments[:conversation]
  rescue JSON::ParserError
    nil
  end

  # Compact tool-call entries with retrievable addresses, plus the delegated
  # receipt summary taken from the core evidence APIs. The output JSON is
  # never re-parsed here: receipts come from Chat.agent_meta_evidence and
  # event attribution from the provenance token events.
  # Generic delegation fallback: a call whose function_call_output carries
  # agent_meta receipt records is a delegation even when the tool is not in
  # DELEGATION_TOOLS, so other suites' delegation tools are never missed.
  helper :agent_meta_receipt_call? do |chat, path, call|
    receipts = Chat.agent_meta_evidence(chat, source: path)
    receipts.any? { |record| record[:call_id] == call[:call_id] }
  end

  helper :chat_tool_calls do |chat, path, events: []|
    short = short_path(path)
    receipt_warnings = []
    receipts = Chat.agent_meta_evidence(chat, source: path, warnings: receipt_warnings)
                    .group_by { |record| record[:call_id] }
    warning_by_call = receipt_warnings.group_by { |warning| warning[:call_id] }

    Chat.tool_calls(chat, source: path).collect do |call|
      status = Chat.tool_call_status(call)
      entry = {
        tool: call[:name],
        call_id: call[:call_id],
        call_address: "#{short}##{call[:call_index]}",
        output_address: call[:output_index] && "#{short}##{call[:output_index]}",
        success: status[:success],
        error: status[:error],
        start_timestamp: status[:start_timestamp],
        timestamp: status[:timestamp],
        status_reason: status[:reason],
        agent_interaction: DELEGATION_TOOLS.include?(call[:name].to_s) ||
                            call[:name].to_s.start_with?('hand_off_to_') ||
                            agent_meta_receipt_call?(chat, path, call),
        target_agent: target_agent(call),
        conversation: target_conversation(call)
      }.reject { |_key, value| value.nil? }

      records = receipts[call[:call_id]]
      if records && records.any?
        direct = records.select { |record| TOKEN_KEYS.any? { |key| record[:meta].include?(key) } && !record[:meta][:job] }
        matched = events_for_call(events, path, call[:call_id])
        summary = {
          receipt_meta_count: records.length,
          direct_event_ids: matched.collect { |event| event[:inference_id] }.compact.uniq,
          receipt_only_event_ids: matched.select { |event| receipt_only_event?(event) }
                                         .collect { |event| event[:inference_id] }.compact.uniq,
          direct_token_total: sum_events(matched).slice(:pt, :ct, :tt),
          agent_job_references: records.select { |record| record[:meta][:job] }
                                       .collect { |record| short_path(record[:meta][:job].to_s) }.uniq,
          unresolved_receipts: direct.count { |record| !record[:meta][:inference_id] },
          warnings: (warning_by_call[call[:call_id]] || []).collect do |warning|
            {
              reason: warning[:reason],
              tool_name: warning[:tool_name],
              output_address: warning[:output_address] && short_address(warning[:output_address]),
              evidence_address: warning[:evidence_address] && short_address(warning[:evidence_address])
            }.reject { |_key, value| value.nil? }
          end
        }
        entry[:agent_meta] = summary.reject { |_key, value| value.nil? || (Array === value && value.empty?) }
      end
      entry
    end
  end

  # Compact event representation for reports: canonical origin/address plus
  # every evidence location, so any amount can be traced back to where it was
  # persisted.
  helper :compact_event do |event|
    canonical = event[:evidence].first
    {
      inference_id: event[:inference_id],
      identity: event[:identity],
      deduplication: event[:deduplication],
      tokens: event[:tokens],
      conflict: !!event[:conflict],
      incomplete_evidence: !!event[:incomplete_evidence],
      canonical_origin: canonical && canonical[:origin],
      canonical_address: canonical && short_address(canonical[:meta_address] || canonical[:evidence_address]),
      evidence: event[:evidence].collect do |item|
        record = {
          origin: item[:origin],
          source: item[:source] && short_path(item[:source]),
          call_id: item[:call_id],
          tool_name: item[:tool_name]
        }
        if item[:origin] == :chat_meta
          record[:meta_address] = short_address(item[:meta_address])
        else
          record[:evidence_address] = short_address(item[:evidence_address])
          record[:output_address] = short_address(item[:output_address])
        end
        record.reject { |_key, value| value.nil? }
      end
    }
  end

  input :file, :string, 'Root chat file or chat-producing job', nil, required: true, jobname: true, nofile: true
  input :role, :string, 'Optional role filter', nil, nofile: true
  input :page, :integer, 'Page number (1-based); enables pagination when set', nil, nofile: true
  input :per_page, :integer, 'Items per page (default 50 when page is set)', nil, nofile: true
  input :follow, :string, 'Provenance relations to follow: "all" or comma/space separated subset of job, dependency, log, result, agent_job', 'all', nofile: true
  desc 'Compact message index across every chat discovered by core provenance traversal.'
  task :message_index => :json do |file, role, page, per_page, follow|
    provenance = provenance_data(file, follow)
    messages = provenance[:chats].flat_map do |path, chat|
      chat.message_index(source: path).filter_map do |info|
        next if role && !role.empty? && info[:role].to_s != role
        path_str = short_path(path); index = info[:address].last
        meta = info[:meta]
        if Hash === meta
          truncated_meta = {}
          meta.each do |k,v|
            truncated_meta[k] = String === v ? Log.truncate_string(v.to_s) : v
          end
          meta = truncated_meta
        end
        {
          address: "#{path_str}##{index}",
          id: "#{path_str}##{index}",
          lineage_id: info[:id],
          previous_lineage_id: info[:prev],
          role: info[:role],
          fingerprint: info[:fingerprint],
          meta: meta
        }
      end
    end

    envelope = paginate_items(messages, page, per_page)
    next envelope.merge(messages: envelope.delete(:items)) if envelope
    messages
  end

  input :file, :string, 'Root chat file or chat-producing job', nil, required: true, jobname: true, nofile: true
  input :ids, :array, 'Flat string IDs ("path#index") from message_index or chat_tool_calls', nil, required: true
  input :follow, :string, 'Provenance relations to follow: "all" or comma/space separated subset of job, dependency, log, result, agent_job', 'all', nofile: true
  desc 'Retrieve full message content by flat string ID ("path#index").'
  task :message_content => :json do |file, ids, follow|
    wanted = ids.collect do |id|
      if Array === id
        "#{id.first}##{id.last}"
      else
        id.to_s
      end
    end

    provenance_data(file, follow)[:chats].flat_map do |path, chat|
      short = short_path(path)
      chat.each_with_index.filter_map do |message, index|
        id = "#{short}##{index}"
        next unless wanted.include?(id) || wanted.include?("#{path}##{index}")
        message.merge(id: id)
      end
    end
  end

  input :file, :string, 'Root chat file or chat-producing job', nil, required: true, jobname: true, nofile: true
  input :follow, :string, 'Provenance relations to follow: "all" or comma/space separated subset of job, dependency, log, result, agent_job', 'all', nofile: true
  desc 'Structural chats, jobs, and typed provenance relations, including delegated agent_job edges.'
  task :chat_overview => :json do |file, follow|
    provenance = provenance_data(file, follow)
    events = provenance[:events]

    chats = provenance[:chats].collect do |path, chat|
      receipts = Chat.agent_meta_evidence(chat, source: path)
      {
        path: short_path(path),
        messages: chat.length,
        roles: roles(chat),
        direct_jobs: chat.jobs.collect { |job| short_path(job.to_s) },
        tool_calls: Chat.tool_calls(chat, source: path).length,
        receipt_records: receipts.length,
        receipt_job_references: receipts.select { |record| record[:meta][:job] }
                                        .collect { |record| short_path(record[:meta][:job].to_s) }.uniq
      }
    end
    jobs = provenance[:jobs].collect do |path, job|
      {
        path: short_path(path),
        workflow: job.info[:workflow],
        task: job.info[:task_name],
        status: job.info[:status],
        dependencies: job.dependencies.length,
        direct_logs: provenance[:edges].count do |edge|
          edge[:from_kind] == :job && edge[:from] == short_path(path) && edge[:relation] == :log
        end
      }
    end

    agent_job_edges = provenance[:edges].select { |edge| edge[:relation] == :agent_job }

    {
      root: { kind: provenance[:root_kind], path: provenance[:root] },
      chats: chats,
      jobs: jobs,
      edges: provenance[:edges],
      totals: {
        chats: chats.length,
        jobs: jobs.length,
        messages: chats.sum { |chat| chat[:messages] },
        tool_calls: chats.sum { |chat| chat[:tool_calls] },
        job_edges: provenance[:edges].count { |edge| edge[:relation] == :job },
        dependency_edges: provenance[:edges].count { |edge| edge[:relation] == :dependency },
        log_edges: provenance[:edges].count { |edge| edge[:relation] == :log },
        agent_job_edges: agent_job_edges.length,
        receipt_records: chats.sum { |chat| chat[:receipt_records] },
        receipt_only_events: events.count { |event| receipt_only_event?(event) },
        conflicts: events.count { |event| event[:conflict] },
        incomplete_evidence: events.count { |event| event[:incomplete_evidence] }
      },
      warnings: provenance[:warnings]
    }
  end

  input :file, :string, 'Root chat file or chat-producing job', nil, required: true, jobname: true, nofile: true
  input :follow, :string, 'Provenance relations to follow: "all" or comma/space separated subset of job, dependency, log, result, agent_job', 'all', nofile: true
  input :page, :integer, 'Page number (1-based); enables pagination when set', nil, nofile: true
  input :per_page, :integer, 'Items per page (default 50 when page is set)', nil, nofile: true
  input :dedupe, :boolean, 'Mark socialized/log copies of the same logical call; summary counts stay raw', false, nofile: true
  desc 'Compact tool-call index with addresses and delegated receipt summaries.'
  task :chat_tool_calls => :json do |file, follow, page, per_page, dedupe|
    provenance = provenance_data(file, follow)
    calls = provenance[:chats].flat_map do |path, chat|
      chat_tool_calls(chat, path, events: provenance[:events])
    end
    calls, unique_calls = dedupe ? mark_call_copies(calls) : [calls, nil]

    result = {
      total: calls.length,
      successes: calls.count { |call| call[:success] == true },
      failures: calls.count { |call| call[:success] == false },
      incomplete: calls.count { |call| call[:success].nil? },
      copies: calls.count { |call| call[:copy_of] },
      by_tool: calls.group_by { |call| call[:tool] || '(unknown)' }.transform_values(&:length),
      calls: calls
    }
    result[:unique_calls] = unique_calls if unique_calls

    envelope = paginate_items(calls, page, per_page)
    next envelope.merge(calls: envelope.delete(:items), **result.except(:calls)) if envelope
    result
  end

  input :file, :string, 'Root chat file or chat-producing job', nil, required: true, jobname: true, nofile: true
  input :follow, :string, 'Provenance relations to follow: "all" or comma/space separated subset of job, dependency, log, result, agent_job', 'all', nofile: true
  input :page, :integer, 'Page number (1-based); enables pagination when set', nil, nofile: true
  input :per_page, :integer, 'Items per page (default 50 when page is set)', nil, nofile: true
  desc 'Deduplicated direct inference token usage with evidence locations and receipt coverage.'
  task :chat_tokens => :json do |file, follow, page, per_page|
    provenance = provenance_data(file, follow)
    events = provenance[:events]
    totals = scope_totals(events)
    compact_events = events.collect { |event| compact_event(event) }

    result = {
      **totals,
      events: compact_events,
      conflicts: events.select { |event| event[:conflict] }.collect do |event|
        {
          inference_id: event[:inference_id],
          identity: event[:identity],
          tokens: event[:tokens],
          evidence: event[:evidence].collect { |item| short_address(item[:meta_address] || item[:evidence_address]) }
        }
      end,
      incomplete_evidence: events.select { |event| event[:incomplete_evidence] }.collect do |event|
        {
          inference_id: event[:inference_id],
          identity: event[:identity],
          evidence: event[:evidence].collect { |item| {origin: item[:origin], provider_response_id: item[:meta][:provider_response_id]} }
        }
      end,
      warnings: provenance[:warnings],
      notes: [
        'deduplicated_total is the authoritative cost total; chat_evidence and receipt_evidence overlap and must not be summed.',
        'receipt_only is the disjoint delegated contribution with no saved child chat/log.',
        'Conflicting events are counted once from canonical evidence; totals containing conflicts are best-effort, not authoritative.'
      ]
    }

    envelope = paginate_items(compact_events, page, per_page)
    next envelope.merge(events: envelope.delete(:items), **result.except(:events)) if envelope
    result
  end

  input :file, :string, 'Root chat file or chat-producing job', nil, required: true, jobname: true, nofile: true
  input :follow, :string, 'Provenance relations to follow: "all" or comma/space separated subset of job, dependency, log, result, agent_job', 'all', nofile: true
  input :page, :integer, 'Page number (1-based); enables pagination when set', nil, nofile: true
  input :per_page, :integer, 'Items per page (default 50 when page is set)', nil, nofile: true
  desc 'Agent interactions (ask, cortex_continue, cortex_brief, hand_off_to_*, and any call with agent_meta receipts) with receipt evidence, agent_job links, and delegated token totals.'
  task :chat_agents => :json do |file, follow, page, per_page|
    provenance = provenance_data(file, follow)
    events = provenance[:events]
    edges = provenance[:edges]
    log_edges_by_job = edges.select { |edge| edge[:relation] == :log && edge[:from_kind] == :job }
                            .group_by { |edge| edge[:from] }

    interactions = provenance[:chats].flat_map do |path, chat|
      calls = chat_tool_calls(chat, path, events: events)
      calls.select { |call| call[:agent_interaction] }.collect do |call|
        call_path = short_path(path)
        receipt = call[:agent_meta]

        # Association comes exclusively from agent_job edge details; paths and
        # agent names are never matched heuristically.
        agent_job_edges = edges.select do |edge|
          edge[:relation] == :agent_job && edge[:from] == call_path &&
            edge[:detail] && edge[:detail][:call_id] == call[:call_id]
        end
        linked_jobs = agent_job_edges.collect { |edge| edge[:to] }.uniq
        linked_logs = linked_jobs.any? { |job| (log_edges_by_job[job] || []).any? }

        # Delegated spend: the union of every linked job's subtree chats
        # (logs, results, nested delegations; never dependencies) holding the
        # canonical evidence of an event.  Sums already-deduplicated events
        # only, so a chat shared by several delegations is counted once here
        # even though each linked job reports its own subtree.
        subtree_chats = linked_jobs.each_with_object(Set.new) do |job, union|
          union.merge(delegated_subtree_chats(edges, job))
        end
        delegated_tokens, delegated_count = delegated_events(events, subtree_chats)

        matched_events = events_for_call(events, path, call[:call_id])
        receipt_direct = matched_events.any? { |event| event[:evidence].any? { |item| item[:origin] == :agent_meta } }
        log_direct = matched_events.any? { |event| event[:evidence].any? { |item| item[:origin] == :chat_meta } }

        unresolved = receipt && receipt[:unresolved_receipts].to_i > 0 && matched_events.empty?

        child_evidence = if receipt_direct && (log_direct || linked_logs)
                           :both
                         elsif receipt_direct
                           :receipt_only
                         elsif log_direct || linked_logs
                           :log_only
                         elsif unresolved
                           :receipt_unresolved
                         else
                           :none
                         end

        {
          source: call_path,
          call_id: call[:call_id] || (call[:call_address].split('#').last),
          tool: call[:tool],
          target_agent: call[:target_agent],
          conversation: call[:conversation],
          success: call[:success],
          receipt: receipt && {
            event_ids: receipt[:direct_event_ids],
            receipt_only_event_ids: receipt[:receipt_only_event_ids],
            token_total: receipt[:direct_token_total],
            job_references: receipt[:agent_job_references]
          },
          agent_job_edges: agent_job_edges.collect { |edge| edge[:detail] },
          linked_job: linked_jobs.first,
          child_evidence: child_evidence,
          log_link: linked_jobs.empty? ? :none : :agent_job_edge,
          delegated_token_total: delegated_tokens,
          delegated_event_count: delegated_count
        }.reject { |_key, value| value.nil? }
      end
    end

    result = {
      interactions: interactions,
      failed: interactions.count { |interaction| interaction[:success] == false },
      warnings: provenance[:warnings],
      note: 'Agent associations come from agent_job provenance edges recorded in the delegated receipt, never from path or agent-name conventions. delegated_token_total sums the already-deduplicated events whose canonical evidence lies in the linked jobs\' subtrees; it may overlap across interactions that link the same job.'
    }

    envelope = paginate_items(interactions, page, per_page)
    next envelope.merge(interactions: envelope.delete(:items), **result.except(:interactions)) if envelope
    result
  end

  input :file, :string, 'Root chat file or chat-producing job', nil, required: true, jobname: true, nofile: true
  input :origin, :string, 'Optional origin filter (chat_meta or agent_meta)', nil, nofile: true
  input :full, :boolean, 'Return untruncated meta values and raw receipt messages', false, nofile: true
  input :follow, :string, 'Provenance relations to follow: "all" or comma/space separated subset of job, dependency, log, result, agent_job', 'all', nofile: true
  desc 'Unified meta evidence: ordinary persisted meta messages plus agent_meta receipts.'
  task :meta_evidence => :json do |file, origin, full, follow|
    provenance = provenance_data(file, follow)
    warnings = []

    records = provenance[:chats].flat_map do |path, chat|
      Chat.meta_evidence(chat, source: path, warnings: warnings).collect do |evidence|
        next if origin && !origin.empty? && evidence[:origin].to_s != origin

        meta = evidence[:meta]
        rendered = {}
        meta.each do |key, value|
          rendered[key] = String === value && !full ? Log.truncate_string(value) : value
        end

        receipt = evidence[:origin] == :agent_meta
        classification = if meta[:job]
                           :job_projection
                         elsif TOKEN_KEYS.any? { |key| meta.include?(key) }
                           :direct
                         else
                           :other
                         end

        record = {
          origin: evidence[:origin],
          meta: rendered,
          source: short_path(path),
          classification: classification,
          job: meta[:job] && short_path(meta[:job].to_s),
          inference_id: meta[:inference_id],
          provider_response_id: meta[:provider_response_id]
        }
        if receipt
          record[:call_id] = evidence[:call_id]
          record[:tool_name] = evidence[:tool_name]
          record[:output_address] = short_address(evidence[:output_address])
          record[:evidence_address] = short_address(evidence[:evidence_address])
          record[:raw_message] = evidence[:raw_message] if full
        else
          record[:meta_address] = short_address(evidence[:meta_address])
        end
        record.reject { |_key, value| value.nil? }
      end.compact
    end

    {
      total: records.length,
      by_origin: records.group_by { |record| record[:origin] }.transform_values(&:length),
      by_classification: records.group_by { |record| record[:classification] }.transform_values(&:length),
      records: records,
      warnings: warnings.collect { |warning| normalize_provenance_warning(warning) }
    }
  end

  input :file, :string, 'Root chat file or chat-producing job', nil, required: true, jobname: true, nofile: true
  input :addresses, :array, 'Optional evidence addresses; returns full reasoning for exactly those items', nil, nofile: true
  input :full, :boolean, 'Return full reasoning text instead of fingerprints', false, nofile: true
  input :follow, :string, 'Provenance relations to follow: "all" or comma/space separated subset of job, dependency, log, result, agent_job', 'all', nofile: true
  desc 'Reasoning fields from ordinary meta messages and delegated receipts, compact by default.'
  task :chat_reasoning => :json do |file, addresses, full, follow|
    provenance = provenance_data(file, follow)
    events = provenance[:events]
    receipt_only_by_id = {}
    events.each do |event|
      id = event[:inference_id]
      next unless id
      receipt_only_by_id[id] = event[:evidence].all? { |item| item[:origin] == :agent_meta }
    end
    agent_job_by_call = {}
    provenance[:edges].each do |edge|
      next unless edge[:relation] == :agent_job && edge[:detail] && edge[:detail][:call_id]
      (agent_job_by_call[edge[:detail][:call_id]] ||= []) << edge[:detail][:job]
    end

    wanted = addresses && !addresses.empty? ? addresses.collect(&:to_s) : nil

    items = provenance[:chats].flat_map do |path, chat|
      short = short_path(path)
      Chat.meta_evidence(chat, source: path).filter_map do |evidence|
        reasoning = evidence[:meta][:reas]
        next unless String === reasoning && !reasoning.empty?

        receipt = evidence[:origin] == :agent_meta
        address = receipt ?
          "#{short}##{evidence[:evidence_address][1]}[agent_meta,#{evidence[:evidence_address][3]}]" :
          "#{short}##{evidence[:meta_address][1]}"
        next if wanted && !wanted.include?(address)

        meta = evidence[:meta]
        item = {
          origin: evidence[:origin],
          address: address,
          inference_id: meta[:inference_id],
          provider_response_id: meta[:provider_response_id],
          timestamp: meta[:timestamp],
          source: short,
          call_id: receipt ? evidence[:call_id] : nil,
          tool_name: receipt ? evidence[:tool_name] : nil,
          linked_job: receipt ? agent_job_by_call[evidence[:call_id]]&.first : nil,
          receipt_only: receipt && meta[:inference_id] ?
            receipt_only_by_id[meta[:inference_id]] : nil
        }.reject { |_key, value| value.nil? }

        if full || wanted
          item[:reasoning] = reasoning
          item[:characters] = reasoning.length
        else
          item.merge!(
            fingerprint: Digest::MD5.hexdigest(reasoning)[0, 12],
            prefix: reasoning.length > 80 ? reasoning[0, 80] + '...' : reasoning,
            suffix: reasoning.length > 110 ? '...' + reasoning[-80, 80] : nil,
            characters: reasoning.length
          )
        end
        item.reject { |_key, value| value.nil? }
      end
    end

    {
      total: items.length,
      by_origin: items.group_by { |item| item[:origin] }.transform_values(&:length),
      receipt_only: items.count { |item| item[:receipt_only] },
      items: items
    }
  end

  input :file, :string, 'Root chat file or chat-producing job', nil, required: true, jobname: true, nofile: true
  input :follow, :string, 'Provenance relations to follow: "all" or comma/space separated subset of job, dependency, log, result, agent_job', 'all', nofile: true
  desc 'Concise combined provenance, token, and delegation snapshot.'
  task :chat_report => :json do |file, follow|
    provenance = provenance_data(file, follow)
    events = provenance[:events]
    totals = scope_totals(events)
    calls = provenance[:chats].flat_map do |path, chat|
      chat_tool_calls(chat, path, events: events)
    end

    marked_calls, _unique = mark_call_copies(calls)
    receipt_summaries = marked_calls.select { |call| call[:agent_meta] && !call[:copy_of] }.first(3).collect do |call|
      {
        source: call[:call_address].split('#').first,
        call_id: call[:call_id] || call[:call_address],
        tool: call[:tool],
        output_address: call[:output_address],
        **call[:agent_meta].slice(:receipt_meta_count, :direct_event_ids, :direct_token_total, :agent_job_references)
      }
    end

    failures = calls.select { |call| call[:success] == false }

    # Delegation rollup: spend located in the root chat's own file versus
    # spend located in agent_job subtrees.  Both come from the one
    # already-deduplicated event list, so root + delegated + unattributed
    # reconciles with deduplicated_total and nothing is double counted.
    edges = provenance[:edges]
    # N2 rev3: on a job root, root_chat_tokens must cover the job's own chats
    # (agent chat through :log, result chat through :result), per the README.
    # provenance[:jobs] is a Hash path => job; iterating it yields [key, value]
    # pairs, so the previous select/flat_map never matched a job node and every
    # event fell into unattributed_tokens.  Walk the root job's OWN chats only
    # (:log/:result, not agent_job/dependency) so root_chat_tokens stays
    # disjoint from delegated_tokens and the three-way split still reconciles.
    root_chat_paths = Set[File.expand_path(provenance[:root].to_s)]
    if provenance[:root_kind] == :job
      root_job = provenance[:jobs].keys.find { |key| short_path(key) == provenance[:root].to_s }
      root_job ||= provenance[:jobs].keys.first
      if root_job
        root_chat_paths += provenance[:edges].select do |edge|
          edge[:from] == short_path(root_job) && %i[log result].include?(edge[:relation]) &&
            edge[:to_kind] == :chat
        end.collect { |edge| File.expand_path(edge[:to].to_s) }
      end
    end
    root_tokens, root_count = delegated_events(events, root_chat_paths)
    linked_jobs = edges.select { |edge| edge[:relation] == :agent_job }
                       .map { |edge| edge[:to] }.uniq
    subtree_rows = linked_jobs.collect do |job|
      chats = delegated_subtree_chats(edges, job)
      tokens, count = delegated_events(events, chats)
      { job: job, tokens: tokens, events: count, chats: chats.collect { |c| short_path(c) } }
    end
    delegated_union = linked_jobs.each_with_object(Set.new) { |job, union| union.merge(delegated_subtree_chats(edges, job)) }
    delegated_tokens, delegated_count = delegated_events(events, delegated_union)
    unattributed = sum_events(events.select { |event| !root_chat_paths.include?(canonical_event_source(event)) &&
                                                !delegated_union.include?(canonical_event_source(event)) })
    unresolved_warnings = provenance[:warnings].select { |warning| warning[:reason].to_s == 'unresolved_job_reference' }
    # N1 rev3: only genuinely-reference-bearing failures belong in the list;
    # reference-less malformed edges are counted, not serialized as nil.
    unresolved_jobs = unresolved_warnings.collect { |warning| warning[:reference] }
                                        .compact.uniq
    malformed_edges = unresolved_warnings.count { |warning| warning[:reference].nil? }

    delegation = {
      linked_jobs: linked_jobs.length,
      malformed_edges: malformed_edges,
      subtrees: subtree_rows,
      root_chat_tokens: root_tokens,
      root_chat_events: root_count,
      delegated_tokens: delegated_tokens,
      delegated_events: delegated_count,
      unattributed_tokens: unattributed,
      unresolved_jobs: unresolved_jobs
    }

    {
      root: { kind: provenance[:root_kind], path: provenance[:root] },
      chats: provenance[:chats].length,
      jobs: provenance[:jobs].length,
      edges: provenance[:edges].length,
      agent_job_edges: provenance[:edges].count { |edge| edge[:relation] == :agent_job },
      tokens: {
        deduplicated_total: totals[:deduplicated_total],
        receipt_only: totals[:receipt_only],
        direct_events: events.length,
        multi_evidence_events: events.count { |event| event[:evidence].length > 1 },
        conflicts: events.count { |event| event[:conflict] },
        incomplete_evidence: events.count { |event| event[:incomplete_evidence] }
      },
      tool_calls: calls.length,
      unique_tool_calls: calls.length - marked_calls.count { |call| call[:copy_of] },
      failed_tool_calls: failures.length,
      failures: failures.first(10),
      receipt_summaries: receipt_summaries,
      delegation: delegation,
      warnings: provenance[:warnings],
      notes: [
        'deduplicated_total already includes the tokens of resolved delegated subtrees (agent_job children); delegated_tokens is a view of that total, not an addition to it.',
        'Per-subtree values may overlap when one job is linked by several interactions: they are coverage views of the same deduplicated event set, never a partition.',
        'unattributed_tokens is spend whose canonical evidence lies in no root or delegated subtree chat, e.g. events imported from other chats.',
        'unresolved_jobs are referenced delegation jobs whose cost is missing from this accounting because the job could not be resolved.'
      ]
    }
  end


  input :file, :string, 'Root chat file or chat-producing job', nil, required: true, jobname: true, nofile: true
  desc 'Chat-level import/continue/last reference events and their import closure, reported separately from core provenance.'
  task :provenance_relationships => :json do |file|
    root_kind, root = resolve_root(file)
    raise ParameterException, 'provenance_relationships requires a chat file root; pass the chat path directly' unless root_kind == :chat

    path = File.expand_path(root.to_s)
    references = chat_relationship_references(path).collect do |relationship|
      relationship[:target] &&= short_path(relationship[:target])
      relationship
    end

    # Collapsed per-target summary: how many reference events and of which
    # types point at each resolved target, plus unresolved targets.
    by_target = references.group_by { |relationship| relationship[:target] || relationship[:reference] }
    targets = by_target.collect do |target, group|
      {
        target: target,
        resolved: group.first[:resolved],
        types: group.collect { |relationship| relationship[:type] }.tally,
        references: group.length,
        imported_by: short_path(path)
      }
    end

    {
      source: short_path(path),
      references: references,
      targets: targets,
      import_closure: import_closure(path).collect { |chat| short_path(chat) },
      note: 'import/continue/last references are not part of core provenance traversal; they are recovered from the uncompiled chat text and resolved with Chat.find_file'
    }
  end

  input :file, :string, 'Root chat file or chat-producing job', nil, required: true, jobname: true, nofile: true
  input :follow, :string, 'Provenance relations to follow: "all" or comma/space separated subset of job, dependency, log, result, agent_job', 'all', nofile: true
  input :scope, :string, "Accounting scope: 'own' (default) accounts each chat in the import closure separately from its own file; 'closure' merges the whole closure into one root entry", 'own', nofile: true
  desc 'Separate accounting for a chat and every chat it imports, without merging imported costs into the root. Each own-scope entry also splits its tokens into direct_tokens (canonical evidence in the chat file itself) and delegated_tokens (canonical evidence in agent_job subtrees); the tokens field keeps its full subtree-inclusive meaning when follow includes agent_job.'
  task :chat_accounting => :json do |file, follow, scope|
    root_kind, root = resolve_root(file)
    raise ParameterException, 'chat_accounting requires a chat file root; pass the chat path directly' unless root_kind == :chat

    scope = (scope || 'own').to_s
    raise ParameterException, "Unknown scope: #{scope}" unless %w[own closure].include?(scope)

    path = File.expand_path(root.to_s)
    closure = import_closure(path)

    entries = closure.collect do |chat|
      own = provenance_data(chat, follow)
      events = own[:events]
      totals = scope_totals(events)
      calls = own[:chats].flat_map { |chat_path, chat_obj| chat_tool_calls(chat_obj, chat_path, events: events) }

      # Direct/delegated split for this chat: direct spend has its canonical
      # evidence in the chat file itself; delegated spend lives in the
      # agent_job subtrees reachable from it.  Both are views of the entry's
      # own deduplicated event list.
      own_edges = own[:edges]
      own_direct_chats = Set[File.expand_path(chat)]
      own_linked_jobs = own_edges.select { |edge| edge[:relation] == :agent_job }
                                 .map { |edge| edge[:to] }.uniq
      own_subtrees = own_linked_jobs.each_with_object(Set.new) do |job, union|
        union.merge(delegated_subtree_chats(own_edges, job))
      end
      direct_tokens, direct_count = delegated_events(events, own_direct_chats)
      delegated_tokens, delegated_count = delegated_events(events, own_subtrees)

      imports = chat_relationship_references(chat).select { |relationship| relationship[:type] == :import }
      {
        scope: :own,
        chat: short_path(chat),
        imports: imports.collect { |relationship|
          target = relationship[:target] || relationship[:reference]
          target && short_path(target)
        }.compact,
        unresolved_imports: imports.reject { |relationship| relationship[:resolved] }
                                   .collect { |relationship| relationship[:reference] },
        messages: own[:chats].any? ? own[:chats].values.first.length : Chat.load(chat).length,
        tokens: totals[:deduplicated_total],
        token_events: events.length,
        conflicts: events.count { |event| event[:conflict] },
        incomplete_evidence: events.count { |event| event[:incomplete_evidence] },
        tool_calls: calls.length,
        direct_jobs: own[:chats].length,
        direct_tokens: direct_tokens,
        direct_events: direct_count,
        delegated_tokens: delegated_tokens,
        delegated_events: delegated_count,
        delegated_subtrees: own_linked_jobs.collect { |job| short_path(job) },
        warnings: own[:warnings].length
      }
    end

    # Closure scope: one root entry merging every entry's events with
    # inference_id deduplication, so shared work is never double counted.
    if scope == 'closure'
      events = closure.flat_map { |chat| provenance_data(chat, follow)[:events] }
      merged = {}
      events.each do |event|
        key = event[:identity] || event[:inference_id]
        merged[key] ||= event
      end
      deduplicated = merged.values
      totals = scope_totals(deduplicated)

      entries = [{
        scope: :closure,
        chat: short_path(path),
        chats: closure.collect { |chat| short_path(chat) },
        tokens: totals[:deduplicated_total],
        token_events: deduplicated.length,
        conflicts: deduplicated.count { |event| event[:conflict] },
        incomplete_evidence: deduplicated.count { |event| event[:incomplete_evidence] },
        token_events_per_chat: closure.to_h { |chat| [short_path(chat), provenance_data(chat, follow)[:events].length] }
      }]
    end

    {
      source: short_path(path),
      scope: scope.to_sym,
      closure: closure.collect { |chat| short_path(chat) },
      entries: entries,
      note: 'own scope: each chat is accounted from its own file with its own job/log provenance; imported chats never contribute to another entry. closure scope merges all events with inference_id deduplication. tokens includes delegated subtrees when follow includes agent_job; direct_tokens + delegated_tokens may overlap it only via shared chats, otherwise they partition it.'
    }
  end

  # --- inbox access (live advice injection) ---

  # One chat log as a compact live-chat entry. Files are reported with path,
  # mtime, age, size and a likely_active flag for the newest log, so the task
  # answers "which chat is being written right now" without reading content.
  helper :live_chat_entry do |path, reference_time, likely_active: false|
    mtime = File.mtime(path)
    {
      path: short_path(path),
      mtime: mtime.iso8601,
      age: (reference_time - mtime).round(3),
      size: File.size(path),
      likely_active: likely_active
    }
  end

  # Live-chat discovery. Provenance traversal is the primary source: it
  # enumerates exactly the chat logs of the session tree (job logs, society
  # conversations, result chats) using the same relation rules as every other
  # task. When traversal yields nothing - a running chat that has not saved a
  # job yet, a damaged session - a bounded recursive glob of
  # Chat::DIRECT_LOG_CHAT_GLOBS under `<root>.files/` recovers the logs
  # physically present on disk, and the entry says which mode was used.
  helper :live_chat_files do |root_kind, root|
    found = []
    on_error = lambda do |_error, _kind, _object, _relation, _reference|
      # Discovery never raises on damaged sessions: warnings are dropped here
      # because chat_report/chat_overview already surface provenance problems.
    end
    begin
      found = Chat.provenance_chat_files(root, root_type: root_kind, on_error: on_error)
    rescue StandardError
      found = []
    end
    source = :provenance

    if found.empty?
      files_dir = root_kind == :job ? root.files_dir.to_s : (root.to_s + '.files')
      if File.directory?(files_dir)
        found = Chat::DIRECT_LOG_CHAT_GLOBS
                .flat_map { |pattern| Dir.glob(File.join(files_dir, '**', pattern)) }
                .collect { |file| File.expand_path(file) }
                .select { |file| File.file?(file) }
                .uniq
      end
      source = :glob
    end

    [found.sort, source]
  end

  input :file, :string, 'Chat file or chat-producing job root', nil, required: true, jobname: true, nofile: true
  desc 'Discover the live chat logs of a session, newest first, flagging the one most likely to be receiving writes.'
  task :live_chats => :json do |file|
    root_kind, root = resolve_root(file)
    files, source = live_chat_files(root_kind, root)

    reference = Time.now
    entries = files.collect { |path| live_chat_entry(path, reference) }
                    .sort_by { |entry| [-Time.parse(entry[:mtime]).to_i, entry[:path]] }
    entries.first[:likely_active] = true unless entries.empty?

    {
      root: short_path(Chat.provenance_path(root_kind, root)),
      root_kind: root_kind,
      chats: entries,
      total: entries.length,
      source: source,
      job: root_kind == :job ? {
        status: root.status,
        running: root.running?,
        done: root.done?,
        error: root.error?,
        aborted: root.aborted?,
        started: root.started?
      } : nil
    }
  end

  # Inbox file description: full content included, because inbox notes are
  # short by design and the whole point of the state task is to read them.
  helper :inbox_entry do |path|
    mtime = File.mtime(path)
    {
      name: File.basename(path),
      mtime: mtime.iso8601,
      size: File.size(path),
      content: Open.read(path)
    }
  end

  input :file, :string, 'Chat file (the save_file whose inbox is inspected)', nil, required: true, jobname: true, nofile: true
  desc 'Pending and delivered inbox messages of a chat, with full content; missing directories are empty lists, never errors.'
  task :inbox_state => :json do |file|
    root_kind, root = resolve_root(file)
    raise ParameterException, 'inbox_state requires a chat file root; pass the chat path directly' unless root_kind == :chat

    save_file = File.expand_path(root.to_s)
    files_dir = save_file + '.files'
    inbox_dir = File.join(files_dir, Chat::INBOX_DIR)
    removed_dir = File.join(files_dir, Chat::INBOX_REMOVED_DIR)

    pending = File.directory?(inbox_dir) ? Dir.glob(File.join(inbox_dir, '*')).select { |f| File.file?(f) }.sort : []
    delivered = File.directory?(removed_dir) ? Dir.glob(File.join(removed_dir, '*')).select { |f| File.file?(f) }.sort_by { |f| File.basename(f) } : []

    {
      save_file: short_path(save_file),
      files_dir: short_path(files_dir),
      inbox_dir: short_path(inbox_dir),
      inbox_removed_dir: short_path(removed_dir),
      pending: pending.collect { |path| inbox_entry(path) },
      delivered: delivered.collect { |path| inbox_entry(path) }
    }
  end

  input :file, :string, 'Chat file (the save_file whose inbox receives the advice)', nil, required: true, jobname: true, nofile: true
  input :message, :string, 'Advice text to deliver on the next real inference', nil, required: true, nofile: true
  input :name, :string, 'Inbox file name (default: timestamped advice note)', nil, nofile: true
  desc 'Post advice into a live chat inbox; it is delivered as a user message on the next real inference and never persisted in the transcript.'
  task :post_inbox_advice => :json do |file, message, name|
    root_kind, root = resolve_root(file)
    raise ParameterException, 'post_inbox_advice requires a chat file root; pass the chat path directly' unless root_kind == :chat

    name = name.to_s.strip
    name = nil if name.empty?
    raise ParameterException, 'Inbox note name must be a plain file name, not a path' if name && name.include?('/')
    raise ParameterException, 'Advice message must not be empty' if message.to_s.strip.empty?

    name ||= Time.now.strftime('%Y%m%d-%H%M%S') + '-advice.md'
    save_file = File.expand_path(root.to_s)
    inbox_dir = File.join(save_file + '.files', Chat::INBOX_DIR)
    FileUtils.mkdir_p(inbox_dir)

    target = File.join(inbox_dir, name)
    raise ParameterException, "Inbox note already exists: #{name}" if File.exist?(target)
    Open.write(target, message)

    {
      posted: short_path(target),
      name: name,
      save_file: short_path(save_file),
      inbox_dir: short_path(inbox_dir),
      size: File.size(target),
      note: 'delivered as a user message on the next real inference; consume-once; the moved file in inbox_removed/ is the delivery record'
    }
  end


  export_exec :message_index, :message_content, :chat_overview,
              :chat_tool_calls, :chat_tokens, :chat_agents, :meta_evidence,
              :chat_reasoning, :chat_report, :provenance_relationships,
              :chat_accounting, :live_chats, :inbox_state, :post_inbox_advice
end
