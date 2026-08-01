require 'scout-ai'
require 'json'
require 'set'

module ChatAnalyst
  extend Workflow
  self.name = 'ChatAnalyst'

  # A small reader over persisted chats and Scout jobs. Chat itself provides
  # lineage IDs and metadata traces; this class only discovers the files to
  # inspect and keeps enough structure for analyst reports.
  class Session
    attr_reader :root, :chats, :jobs, :edges, :warnings

    def initialize(input)
      @root = resolve_chat(input)
      @chats, @jobs, @edges, @warnings = {}, {}, [], []
      discover_chat(@root)
    end

    def trace(list = @chats.values)
      Chat.trace_chats(list)
    end

    def token_entries(list = @chats.values)
      trace(list).select do |entry|
        meta = entry[:meta]
        !meta[:job] && %w[pt ct tt].any? { |name| meta.include?(name) }
      end
    end

    def token_totals(list = @chats.values)
      token_entries(list).each_with_object({ prompt: 0, completion: 0, total: 0 }) do |entry, totals|
        meta = entry[:meta]
        totals[:prompt] += meta[:pt].to_i
        totals[:completion] += meta[:ct].to_i
        totals[:total] += meta[:tt].to_i
      end
    end

    private

    def resolve_chat(input)
      candidates = [input, "#{input}.chat", File.expand_path(input), File.expand_path("#{input}.chat")]
      begin
        candidates << Scout.chats[input].find
        candidates << Scout.chats[input].find_with_extension(:chat).find
      rescue
      end
      candidates.compact.find { |path| File.file?(path.to_s) } ||
        raise(ParameterException, "Chat not found: #{input}")
    end

    def discover_chat(path)
      path = File.expand_path(path.to_s)
      return if @chats.include?(path)
      chat = Chat.load(path)
      @chats[path] = chat

      %w[import continue last].each do |role|
        chat.role_messages(role).each do |message|
          imported = Chat.find_file(message[:content].to_s.strip, path)
          next unless imported && File.file?(imported.to_s)
          imported = File.expand_path(imported.to_s)
          @edges << { from: imported, to: path, type: :import }
          discover_chat(imported)
        end
      end

      chat.jobs.each do |reference|
        job = discover_job(reference)
        @edges << { from: job.path.to_s, to: path, type: :result } if job
      end
    rescue => e
      @warnings << "Could not read chat #{path}: #{e.message}"
    end

    def discover_job(reference)
      job = Step === reference ? reference : Step.load(reference)
      path = File.expand_path(job.path.to_s)
      return @jobs[path] if @jobs.include?(path)
      @jobs[path] = job

      job.dependencies.each do |dependency|
        child = discover_job(dependency)
        @edges << { from: child.path.to_s, to: path, type: :dependency } if child
      end

      discover_chat(path) if job.done? && job.type.to_s == 'chat'
      log = job.file('log')
      if log.directory?
        log.glob('**/*.chat').sort.each do |file|
          file = File.expand_path(file.to_s)
          @edges << { from: path, to: file, type: :log }
          discover_chat(file)
        end
      end
      job
    rescue => e
      @warnings << "Could not load job #{reference}: #{e.message}"
      nil
    end
  end

  helper :short_path do |path|
    path = File.expand_path(path.to_s)
    home = File.expand_path('~')
    path.start_with?(home + '/') ? "~#{path[home.length..]}" : path
  end

  helper :roles do |chat|
    chat.each_with_object(Hash.new(0)) { |message, counts| counts[message[:role].to_s] += 1 }
  end

  helper :safe_json do |value|
    JSON.parse(value.to_s)
  rescue JSON::ParserError
    nil
  end

  helper :tool_calls do |chat, path|
    calls, outputs = {}, {}
    chat.each_with_index do |message, index|
      info = safe_json(message[:content])
      next unless info.is_a?(Hash)
      case message[:role].to_s
      when 'function_call', 'mcp_call'
        calls[info['id'] || info['call_id'] || "#{index}"] = { tool: info['name'] || info.dig('function', 'name'), index: index }
      when 'function_call_output'
        outputs[info['id'] || info['call_id']] = { index: index, content: info['content'] }
      end
    end
    calls.map do |id, call|
      output = outputs[id]
      raw = safe_json(output && output[:content])
      failed = raw.is_a?(Hash) && (raw['exception'] || raw['exit_status'].to_i != 0 && raw.key?('exit_status'))
      call.merge(file: short_path(path), call_id: id, output_index: output && output[:index], success: output ? !failed : nil)
    end
  end

  input :file, :string, 'Root chat file', nil, required: true, jobname: true, nofile: true
  input :role, :string, 'Optional role filter', nil, nofile: true
  task :message_index => :json do |file, role|
    session = Session.new(file)
    session.chats.flat_map do |path, chat|
      chat.message_index.each_with_index.filter_map do |info, index|
        next if role && !role.empty? && info[:role].to_s != role
        { id: "#{short_path(path)}##{index}", lineage_id: info[:id], previous: info[:prev], file: short_path(path),
          index: index, role: info[:role], fingerprint: info[:fingerprint], meta: info[:meta] }
      end
    end
  end

  input :file, :string, 'Root chat file', nil, required: true, jobname: true, nofile: true
  input :ids, :array, 'Message IDs from message_index', nil, required: true
  task :message_content => :json do |file, ids|
    wanted = ids.to_set
    Session.new(file).chats.flat_map do |path, chat|
      chat.each_with_index.filter_map do |message, index|
        id = "#{short_path(path)}##{index}"
        { id: id, file: short_path(path), index: index, role: message[:role].to_s, content: message[:content].to_s } if wanted.include?(id)
      end
    end
  end

  input :file, :string, 'Root chat file', nil, required: true, jobname: true, nofile: true
  task :chat_overview => :json do |file|
    session = Session.new(file)
    chats = session.chats.map do |path, chat|
      { path: short_path(path), messages: chat.length, roles: roles(chat), jobs: chat.jobs, tool_calls: tool_calls(chat, path).length }
    end
    jobs = session.jobs.map do |path, job|
      { path: short_path(path), workflow: job.info[:workflow], task: job.info[:task_name], dependencies: job.dependencies.length,
        logs: session.edges.count { |edge| edge[:type] == :log && edge[:from] == path } }
    end
    { root: short_path(session.root), chats: chats, jobs: jobs,
      edges: session.edges.map { |edge| edge.merge(from: short_path(edge[:from]), to: short_path(edge[:to])) },
      totals: { chats: chats.length, jobs: jobs.length, messages: chats.sum { |chat| chat[:messages] }, tool_calls: chats.sum { |chat| chat[:tool_calls] } },
      warnings: session.warnings }
  end

  input :file, :string, 'Root chat file', nil, required: true, jobname: true, nofile: true
  task :chat_tool_calls => :json do |file|
    session = Session.new(file)
    calls = session.chats.flat_map { |path, chat| tool_calls(chat, path) }
    { total: calls.length, successes: calls.count { |call| call[:success] }, failures: calls.count { |call| call[:success] == false },
      by_tool: calls.group_by { |call| call[:tool] || '(unknown)' }.transform_values(&:length), calls: calls }
  end

  input :file, :string, 'Root chat file', nil, required: true, jobname: true, nofile: true
  task :chat_tokens => :json do |file|
    session = Session.new(file)
    per_file = session.chats.map do |path, chat|
      totals = session.token_totals([chat])
      { path: short_path(path), inferences: session.token_entries([chat]).length, **totals }
    end
    { per_file: per_file, aggregate: session.token_totals,
      trace_records: session.trace.length,
      note: 'Counts direct pt/ct/tt metadata only. meta job=... is a projection marker; its cost is found recursively in agent logs and dependencies. *_c and *_s are checkpoints and are not summed.' }
  end

  input :file, :string, 'Root chat file', nil, required: true, jobname: true, nofile: true
  task :chat_agents => :json do |file|
    session = Session.new(file)
    calls = session.chats.flat_map { |path, chat| tool_calls(chat, path) }
    interactions = calls.select { |call| call[:tool].to_s == 'ask' || call[:tool].to_s.start_with?('hand_off_to_') }
    { interactions: interactions, failed: interactions.count { |call| call[:success] == false } }
  end

  input :file, :string, 'Root chat file', nil, required: true, jobname: true, nofile: true
  task :chat_report => :json do |file|
    session = Session.new(file)
    calls = session.chats.flat_map { |path, chat| tool_calls(chat, path) }
    { root: short_path(session.root), chats: session.chats.length, jobs: session.jobs.length,
      tokens: session.token_totals, trace_records: session.trace.length,
      tool_calls: calls.first(20), failures: calls.select { |call| call[:success] == false }, warnings: session.warnings }
  end

  export_exec :message_index, :message_content, :chat_overview, :chat_tool_calls, :chat_tokens, :chat_agents, :chat_report
end
