require 'scout-ai'
require 'json'
require 'set'

module ChatAnalyst
  extend Workflow
  self.name = 'ChatAnalyst'

  helper :short_path do |path|
    path = File.expand_path(path.to_s)
    home = File.expand_path('~')
    path.start_with?(home + '/') ? "~#{path[home.length..]}" : path
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
    (File.exist?(path + '.info') || File.directory?(path + '.files')) ? [:job, Step.load(path)] : [:chat, Path.setup(path)]
  end

  # Collect the shared core traversal into plain task-local data. This is
  # report state, not a Session/Graph domain object.
  helper :provenance_records do |file|
    @provenance_records ||= {}
    @provenance_records[file] ||= begin
      root_kind, root = resolve_root(file)
      warnings = []
      records = Chat.traverse_provenance(
        root,
        root_type: root_kind,
        on_error: lambda do |error, kind, object, relation, reference|
          warnings << {
            kind: kind,
            path: short_path(Chat.provenance_path(kind, object)),
            relation: relation,
            reference: reference.to_s,
            error: error.message
          }
        end
      ).to_a

      chats = {}
      jobs = {}
      edges = []
      records.each do |kind, object, parent_kind, parent, relation, first_visit|
        path = Chat.provenance_path(kind, object)
        if first_visit
          kind == :chat ? chats[path] = Chat.load(path) : jobs[path] = object
        end
        next unless parent
        edge = {
          from_kind: parent_kind,
          from: Chat.provenance_path(parent_kind, parent),
          relation: relation,
          to_kind: kind,
          to: path
        }
        edges << edge unless edges.include?(edge)
      end

      {
        root_kind: root_kind,
        root: Chat.provenance_path(root_kind, root),
        records: records,
        chats: chats,
        jobs: jobs,
        edges: edges,
        warnings: warnings
      }
    end
  end

  helper :roles do |chat|
    chat.each_with_object(Hash.new(0)) do |message, counts|
      counts[message[:role].to_s] += 1
    end
  end

  helper :target_agent do |call|
    name = call[:name].to_s
    return name.sub(/^hand_off_to_/, '') if name.start_with?('hand_off_to_')
    return nil unless name == 'ask'

    arguments = call[:arguments]
    arguments = JSON.parse(arguments) if String === arguments
    return nil unless Hash === arguments
    arguments['agent'] || arguments[:agent] || arguments['target'] || arguments[:target]
  rescue JSON::ParserError
    nil
  end

  # Return compact tool-call entries: tool name and retrievable addresses for
  # the call and output messages. Full content can be fetched via
  # message_content using the addresses. Status and agent fields are retained
  # because they are small and useful for filtering and reporting.
  helper :chat_tool_calls do |chat, path|
    short = short_path(path)
    Chat.tool_calls(chat, source: path).collect do |call|
      status = Chat.tool_call_status(call)
      {
        tool: call[:name],
        call_address: "#{short}##{call[:call_index]}",
        output_address: call[:output_index] && "#{short}##{call[:output_index]}",
        success: status[:success],
        error: status[:error],
        start_timestamp: status[:start_timestamp],
        timestamp: status[:timestamp],
        status_reason: status[:reason],
        agent_interaction: call[:name].to_s == 'ask' || call[:name].to_s.start_with?('hand_off_to_'),
        target_agent: target_agent(call)
      }.reject { |_key, value| value.nil? }
    end
  end

  input :file, :string, 'Root chat file or chat-producing job', nil, required: true, jobname: true, nofile: true
  input :role, :string, 'Optional role filter', nil, nofile: true
  desc 'Compact message index across every chat discovered by core provenance traversal.'
  task :message_index => :json do |file, role|
    provenance = provenance_records(file)
    provenance[:chats].flat_map do |path, chat|
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
  end

  input :file, :string, 'Root chat file or chat-producing job', nil, required: true, jobname: true, nofile: true
  input :ids, :array, 'Flat string IDs ("path#index") from message_index or chat_tool_calls', nil, required: true
  desc 'Retrieve full message content by flat string ID ("path#index").'
  task :message_content => :json do |file, ids|
    wanted = ids.collect do |id|
      if Array === id
        "#{id.first}##{id.last}"
      else
        id.to_s
      end
    end

    provenance_records(file)[:chats].flat_map do |path, chat|
      short = short_path(path)
      chat.each_with_index.filter_map do |message, index|
        id = "#{short}##{index}"
        next unless wanted.include?(id) || wanted.include?("#{path}##{index}")
        message.merge(id: id)
      end
    end
  end

  input :file, :string, 'Root chat file or chat-producing job', nil, required: true, jobname: true, nofile: true
  desc 'Structural chats, jobs, and typed provenance relations.'
  task :chat_overview => :json do |file|
    provenance = provenance_records(file)
    chats = provenance[:chats].collect do |path, chat|
      {
        path: short_path(path),
        messages: chat.length,
        roles: roles(chat),
        direct_jobs: chat.jobs.collect(&:to_s),
        tool_calls: Chat.tool_calls(chat).length
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
          edge[:from_kind] == :job && edge[:from] == path && edge[:relation] == :log
        end
      }
    end
    edges = provenance[:edges].collect do |edge|
      edge.merge(from: short_path(edge[:from]), to: short_path(edge[:to]))
    end
    {
      root: { kind: provenance[:root_kind], path: short_path(provenance[:root]) },
      chats: chats,
      jobs: jobs,
      edges: edges,
      totals: {
        chats: chats.length,
        jobs: jobs.length,
        messages: chats.sum { |chat| chat[:messages] },
        tool_calls: chats.sum { |chat| chat[:tool_calls] }
      },
      warnings: provenance[:warnings]
    }
  end

  input :file, :string, 'Root chat file or chat-producing job', nil, required: true, jobname: true, nofile: true
  desc 'Compact tool-call index with retrievable addresses. Use message_content with call_address or output_address to fetch full content.'
  task :chat_tool_calls => :json do |file|
    calls = provenance_records(file)[:chats].flat_map do |path, chat|
      chat_tool_calls(chat, path)
    end

    {
      total: calls.length,
      successes: calls.count { |call| call[:success] == true },
      failures: calls.count { |call| call[:success] == false },
      incomplete: calls.count { |call| call[:success].nil? },
      by_tool: calls.group_by { |call| call[:tool] || '(unknown)' }.transform_values(&:length),
      calls: calls
    }
  end

  input :file, :string, 'Root chat file or chat-producing job', nil, required: true, jobname: true, nofile: true
  desc 'Direct inference token usage, deduplicated by inference ID with lineage fallback for legacy chats.'
  task :chat_tokens => :json do |file|
    provenance = provenance_records(file)
    per_file = provenance[:chats].collect do |path, chat|
      entries = Chat.direct_entries([chat])
      {
        path: short_path(path),
        inferences: entries.length,
        deduplication: entries.group_by { |entry| entry[:deduplication] }.transform_values(&:length),
        **Chat.token_totals([chat])
      }
    end
    trace = Chat.trace_chat_sources(provenance[:chats])
    direct = trace.select do |entry|
      !entry[:meta][:job] && Chat::TOKEN_KEYS.any? { |name| entry[:meta].include?(name) }
    end
    totals = Chat::TOKEN_KEYS.each_with_object({}) { |name, hash| hash[name.to_sym] = 0 }
    direct.each do |entry|
      Chat::TOKEN_KEYS.each { |name| totals[name.to_sym] += entry[:meta][name].to_i }
    end
    {
      per_file: per_file,
      aggregate: totals,
      direct_inferences: direct.length,
      trace_records: trace.length,
      deduplication: direct.group_by { |entry| entry[:deduplication] }.transform_values(&:length),
      note: 'Direct inference IDs are authoritative. Legacy records fall back to conversational lineage. Job projections and cumulative/session snapshots are not summed.'
    }
  end

  input :file, :string, 'Root chat file or chat-producing job', nil, required: true, jobname: true, nofile: true
  desc 'Semantic ask and hand-off interactions found in persisted tool calls.'
  task :chat_agents => :json do |file|
    calls = provenance_records(file)[:chats].flat_map do |path, chat|
      chat_tool_calls(chat, path)
    end
    interactions = calls.select { |call| call[:agent_interaction] }
    interactions.each { |interaction| interaction[:log_link] = :inferred_by_convention }
    {
      interactions: interactions,
      failed: interactions.count { |call| call[:success] == false },
      note: 'Tool calls are authoritative; links from socialized calls to society log files remain convention-based unless an explicit durable link is recorded.'
    }
  end

  input :file, :string, 'Root chat file or chat-producing job', nil, required: true, jobname: true, nofile: true
  desc 'Combined provenance, token, tool-call, and agent-interaction snapshot.'
  task :chat_report => :json do |file|
    provenance = provenance_records(file)
    chats = provenance[:chats]
    calls = chats.flat_map { |path, chat| chat_tool_calls(chat, path) }
    interactions = calls.select { |call| call[:agent_interaction] }
    {
      root: { kind: provenance[:root_kind], path: short_path(provenance[:root]) },
      chats: chats.length,
      jobs: provenance[:jobs].length,
      edges: provenance[:edges].length,
      tokens: Chat.token_totals(chats.values),
      trace_records: Chat.trace_chat_sources(chats).length,
      tool_calls: calls.first(20),
      failures: calls.select { |call| call[:success] == false },
      agent_interactions: interactions,
      warnings: provenance[:warnings]
    }
  end

  export_exec :message_index, :message_content, :chat_overview,
              :chat_tool_calls, :chat_tokens, :chat_agents, :chat_report
end
