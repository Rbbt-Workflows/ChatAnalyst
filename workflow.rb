require 'scout-ai'
require 'json'
require 'set'
require 'digest'

Misc.add_libdir if __FILE__ == $PROGRAM_NAME

module ChatAnalyst
  extend Workflow
  self.name = 'ChatAnalyst'

  # A message longer than this (in characters) is reported as `large: true` by
  # chat_messages: retrieving its full inline content is usually wasteful at
  # this size, so the flag marks candidates for ranged inspection
  # (chat_range) instead of full retrieval. The motivating incident was a
  # 582k-character message, so the threshold sits an order of magnitude
  # below it.
  LARGE_MESSAGE_CHARACTERS = 100_000

  # Task-layer cap for chat_range (minimal revision, plan step 3): one ranged
  # retrieval request may not exceed this many messages; callers requesting
  # longer spans must split them.  The Ruby API (ChatAnalyst.range) stays
  # uncapped — the cap protects the task/agent surface only.
  MAX_RANGE_MESSAGES = 200

  helper :short_path_from_path do |path|
    path = File.expand_path(path.to_s)
    home = File.expand_path('~')
    path.start_with?(home + '/') ? "~#{path[home.length..]}" : path
  end

  # Phase C: plain String spelling for a job path that may have arrived as a
  # Path-extended String from the compact graph; ChatAnalyst results must
  # never carry Path instances (Path extends String, so #to_s returns the
  # same extended object — String.new makes a plain copy).
  helper :plain_job_path do |job_path|
    String.new(job_path.to_s)
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

  # Shared pagination envelope, following the chat_messages shape: setting
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
  # Phase B/5.3 fix: a call with a MISSING call id carries no identity
  # evidence strong enough to collapse two independent calls that happen to
  # share tool name and arguments, so such a call falls back to its own
  # address (chat path + index, unique per occurrence) as the identity
  # component and never marks an independent occurrence as a copy.  A call
  # WITH an id is identity evidence: provider ids are unique per
  # conversation, so the same id with the same tool recurring anywhere in
  # one session — a different chat (socialized projection copy) or a replay
  # within one chat — is a persisted copy.  Arguments are no longer carried
  # in the compact record; tool + provider id is the identity evidence.
  helper :tool_call_identity do |call|
    identity_call_id = call[:call_id] || "#{call[:chat]}##{call[:call_index]}"
    Digest::MD5.hexdigest([call[:tool], identity_call_id].to_json)
  end

  # Mark repeated tool-call identities as copies of their first occurrence in
  # traversal order. Returns [marked calls, unique count]; marked copies carry
  # copy_of with the {chat, call_index} address of the first occurrence,
  # retrievable through chat_tool_call / chat_range. The first occurrence
  # itself is never marked.
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
        canonical[identity] = {chat: call[:chat], call_index: call[:call_index]}
        call
      end
    end
    [marked, unique]
  end








  input :file, :path, 'Root chat file or chat-producing job', nil, required: true, jobname: true, nofile: true
  input :scope, :string, "Accounting scope: 'own' (default) accounts each chat in the import closure separately from its own file; 'closure' merges the whole closure into one root entry", 'own', nofile: true
  desc 'Separate accounting for a chat and every chat it imports, without merging imported costs into the root. Each own-scope entry also splits its tokens into direct_tokens (canonical evidence in the chat file itself) and delegated_tokens (canonical evidence in delegation subtrees).'
  task :chat_accounting => :json do |file, scope|
    root_kind, root = resolve_root(file)
    raise ParameterException, 'chat_accounting requires a chat file root; pass the chat path directly' unless root_kind == :chat

    scope = (scope || 'own').to_s
    raise ParameterException, "Unknown scope: #{scope}" unless %w[own closure].include?(scope)

    path = File.expand_path(root.to_s)

    # LEGACY ADAPTER (Phase C): import closure via ChatAnalyst.relationships,
    # token events via ChatAnalyst.tokens per chat.  No prohibited collectors,
    # no loaded Chat/Step objects in the result.  direct/delegated split:
    # canonical evidence (evidence.first) whose source is the chat file
    # itself is direct; anything else is delegated spend.
    # Single pass (minimal revision phase 2, plan step 6, claim-4 fix): each
    # of tokens / overview / relationships is computed EXACTLY ONCE per chat
    # of the closure and memoized in a local Hash for this one response (no
    # persistent caching abstraction); the closure scope reuses the own-scope
    # events instead of re-calling tokens.  direct/delegated split: canonical
    # evidence (evidence.first) whose source is the chat file itself is
    # direct; anything else is delegated spend.
    per_chat = {}
    fetch = lambda do |chat|
      per_chat[chat] ||= begin
        relationships = ChatAnalyst.relationships(chat)
        report = ChatAnalyst.tokens(chat)
        overview = ChatAnalyst.overview(chat)
        {relationships: relationships, report: report, overview: overview}
      end
    end

    closure = fetch.call(path)[:relationships][:import_closure].map(&:to_s)
    closure = [path] if closure.empty?

    tokens_sum = lambda do |subset|
      subset.each_with_object({pt: 0, ct: 0, tt: 0, cct: 0, cwt: 0, rt: 0}) do |event, sum|
        event[:tokens].each { |key, value| sum[key] += value if sum.key?(key) }
      end
    end

    entries = closure.collect do |chat|
      data = fetch.call(chat)
      report = data[:report]
      events = report[:events]
      direct, delegated = events.partition do |event|
        evidence = event[:evidence].first
        evidence && evidence[:source] == chat
      end

      overview = data[:overview]
      imports = data[:relationships][:references].select { |reference| reference[:type] == :import }
      {
        scope: :own,
        chat: chat,
        imports: imports.collect { |relationship| relationship[:target] }.compact,
        unresolved_imports: imports.reject { |relationship| relationship[:resolved] }
                                   .collect { |relationship| relationship[:reference] },
        messages: overview[:chats].sum { |record| record[:messages] },
        tokens: report[:scopes][:deduplicated_total],
        token_events: events.length,
        conflicts: report[:conflicts][:events],
        incomplete_evidence: report[:conflicts][:incomplete_evidence_events],
        tool_calls: overview[:chats].sum { |record| ChatAnalyst.tool_calls(record[:path])[:calls].length },
        direct_jobs: overview[:jobs].length,
        direct_tokens: tokens_sum.call(direct),
        direct_events: direct.length,
        delegated_tokens: tokens_sum.call(delegated),
        delegated_events: delegated.length,
        delegated_subtrees: overview[:chats].flat_map { |record| record[:job_references].values.flatten }.uniq,
        warnings: report[:warnings].length
      }
    end

    # Closure scope: one root entry merging every entry's events with
    # identity deduplication, so shared work is never double counted.  The
    # merge reads the SAME memoized per-chat event lists the own-scope
    # entries were built from; tokens is never re-called.
    if scope == 'closure'
      merged = {}
      closure.each do |chat|
        fetch.call(chat)[:report][:events].each do |event|
          key = event[:identity] || event[:inference_id]
          merged[key] ||= event
        end
      end
      deduplicated = merged.values
      totals = deduplicated.each_with_object({pt: 0, ct: 0, tt: 0, cct: 0, cwt: 0, rt: 0}) do |event, sum|
        event[:tokens].each { |key, value| sum[key] += value if sum.key?(key) }
      end

      entries = [{
        scope: :closure,
        chat: path,
        chats: closure,
        tokens: totals,
        token_events: deduplicated.length,
        conflicts: deduplicated.count { |event| event[:conflict] },
        incomplete_evidence: deduplicated.count { |event| event[:incomplete_evidence] },
        token_events_per_chat: closure.to_h { |chat| [chat, fetch.call(chat)[:report][:events].length] }
      }]
    end

    {
      source: path,
      scope: scope.to_sym,
      closure: closure,
      entries: entries,
      note: 'own scope: each chat is accounted from its own file with its own provenance; imported chats never contribute to another entry. closure scope merges all events with identity deduplication. direct_tokens + delegated_tokens partition the deduplicated events by canonical-evidence source.'
    }
  end

  # --- inbox access (live advice injection) ---

  # One chat log as a compact live-chat entry. Files are reported with path,
  # mtime, age, size and a likely_active flag for the newest log, so the task
  # answers "which chat is being written right now" without reading content.
  helper :live_chat_entry do |path, reference_time, likely_active: false|
    mtime = File.mtime(path)
    {
      path: short_path_from_path(path),
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
  helper :enqueue_live_node do |queue, visited, kind, value|
    key = begin
            path = value.respond_to?(:path) ? value.path.to_s : value.to_s
            File.expand_path(path)
          rescue StandardError
            value.to_s
          end
    pair = [kind, key]
    return if visited[pair]
    visited[pair] = true
    queue << [kind, value]
  end

  helper :live_chat_files do |root_kind, root|
    found = []
    on_error = lambda do |_error, _kind, _object, _relation, _reference|
      # Discovery never raises on damaged sessions: warnings are dropped here
      # because chat_overview already surfaces provenance problems.
    end
    # Phase C: the compact one-node graph (Chat.provenance_graph) is the
    # primary source now.  One node per call, exactly as the core intends;
    # live_chats walks the closure itself (queue-based), collecting: every
    # chat node itself, every node's own sidecar log chats (graph[:live]),
    # every referenced job's generated transcript and every direct
    # dependency.  This mirrors the old provenance_chat_files closure
    # (chats via job/agent_job/dependency/log/result relations) without
    # rebuilding the materialized graph.
    queue = [[root_kind, root]]
    visited = {}
    visited[[root_kind, root.respond_to?(:path) ? root.path.to_s : root.to_s]] = true
    until queue.empty?
      node_kind, node_value = queue.shift
      begin
        graph = Chat.provenance_graph(node_value, root_type: node_kind)
        if node_kind == :chat
          found << Chat.provenance_path(:chat, node_value).to_s
          graph[:live].each do |sidecar|
            enqueue_live_node(queue, visited, :chat, sidecar.to_s)
          end
          graph[:chats].values.flatten.uniq.each do |job_path|
            enqueue_live_node(queue, visited, :job, job_path)
          end
        else
          step = Step === node_value ? node_value : Step.load(node_value.to_s)
          graph[:live].each do |log|
            enqueue_live_node(queue, visited, :chat, log.to_s)
          end
          transcript = Chat.job_result_chat_file(step)
          enqueue_live_node(queue, visited, :chat, transcript.to_s) if transcript
          graph[:dependencies].each do |dependency_path|
            enqueue_live_node(queue, visited, :job, dependency_path)
          end
        end
      rescue StandardError
        # Discovery never raises on damaged sessions: warnings are dropped
        # here because chat_overview already surfaces problems.
      end
    end
    found = found.to_a
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

  # --- in-flight delegations, discovered through transient `.jobs` files ---

  # Depth cap when following `.jobs` files: the file that seeded the walk
  # plus one jobs-of-jobs level, i.e. a chat discovered in flight that is
  # itself delegating. Chains deeper than that are better served by settled
  # provenance, which records the whole delegation tree once the jobs finish
  # and their receipts are saved; each extra level costs one directory scan
  # per live chat for a situation that is rare while it is still unfolding.
  JOBS_FILE_MAX_DEPTH = 2

  # The `.jobs` file of a save_file, reproducing the writer byte for byte
  # (scout-ai `Chat.jobs_file(save_file)`:
  # `save_file.sub(/\.chat\z/,'') + '.jobs'`). The sub is anchored at the
  # extension, so a sidecar save_file 'parent.chat.files/agent.chat' derives
  # 'parent.chat.files/agent.jobs', the sibling of the chat file itself.
  # (The pre-2.0.0 writer matched the FIRST '.chat' in the string and
  # produced 'parent.files/agent.chat.jobs'; that misfire was corrected in
  # scout-ai and is matched here by the anchored form.)
  helper :jobs_file_for_save_file do |save_file|
    save_file.to_s.sub(/\.chat\z/, '') + '.jobs'
  end

  # Job references listed in one `.jobs` file: bare `Step#short_path` lines.
  # The file exists only while its jobs are in flight (removed in the ensure
  # after Workflow.produce), so existence is re-checked and a mid-read
  # disappearance degrades to no references instead of an error.
  helper :jobs_file_references do |jobs_file|
    return [] unless Open.exists?(jobs_file) && File.file?(jobs_file)
    Open.read(jobs_file).split("\n").collect(&:strip).reject(&:empty?)
  rescue StandardError
    []
  end

  # Chat logs of every job referenced by one `.jobs` file. Each reference is
  # guarded: the job directory may disappear before loading, or a short_path
  # may not resolve at all - a broken reference is skipped, never raised.
  helper :jobs_file_chats do |jobs_file|
    jobs_file_references(jobs_file)
           .filter_map do |reference|
             step = (Chat.load_job_reference(reference) rescue nil)
             next nil unless step && Chat.job_reference_candidate?(step.path.to_s)
             Chat.direct_job_chat_files(step)
                  .collect { |path| {path: File.expand_path(path.to_s), jobs_file: jobs_file} }
           end
           .flatten
  end

  # Live chats that only the transient `.jobs` files can see: workflow-
  # delegated inferences (a Cortex cortex_continue child, a Worker job) with
  # no settled provenance yet. Seeds come from every save_file already in
  # scope (the discovered chats, plus a chat root itself) and from a `*.jobs`
  # glob over the session files-dir; each discovered chat may be delegating
  # in turn, so its own `.jobs` file is followed while the depth cap allows,
  # with a visited set on both files and chats so the walk cannot loop.
  helper :jobs_chats_in_flight do |files_dir, save_files|
    seeds = save_files.collect { |save_file| jobs_file_for_save_file(save_file) }
    seeds.concat(Dir.glob(File.join(files_dir, '**', '*.jobs'))) if files_dir && File.directory?(files_dir)
    seeds = seeds.collect { |path| File.expand_path(path.to_s) }
                  .select { |path| Open.exists?(path) && File.file?(path) }
                  .uniq

    found = []
    seen_files, seen_chats = {}, {}
    frontier = seeds.collect { |path| [path, 1] }
    until frontier.empty?
      jobs_file, depth = frontier.shift
      next if seen_files[jobs_file]
      seen_files[jobs_file] = true

      jobs_file_chats(jobs_file).each do |entry|
        next if seen_chats[entry[:path]]
        seen_chats[entry[:path]] = true
        found << entry
        frontier << [jobs_file_for_save_file(entry[:path]), depth + 1] if depth < JOBS_FILE_MAX_DEPTH
      end
    end
    found
  end

  input :file, :path, 'Chat file or chat-producing job root', nil, required: true, jobname: true, nofile: true
  desc 'Discover the live chat logs of a session, newest first, flagging the one most likely to be receiving writes.'
  task :live_chats => :json do |file|
    root_kind, root = resolve_root(file)
    files, primary_source = live_chat_files(root_kind, root)

    # In-flight delegations are invisible to settled provenance: the receipts
    # that would connect parent and child only land once the parent inference
    # finishes, so a live delegated child has no provenance edge yet. The
    # transient `.jobs` files add those children as a third source.
    files_dir = root_kind == :job ? root.files_dir.to_s : (root.to_s + '.files')
    save_files = files.dup
    save_files << root.to_s if root_kind == :chat
    in_flight = jobs_chats_in_flight(files_dir, save_files)

    # Settled provenance or the glob fallback win over `.jobs` for the same
    # file: an entry found that way carries a durable explanation, while the
    # `.jobs` route only says "referenced while running".
    known = files.collect { |path| File.expand_path(path.to_s) }
    in_flight.reject! { |entry| known.include?(entry[:path]) }

    reference = Time.now
    entries = files.collect { |path| live_chat_entry(path, reference).merge(source: primary_source) }
    entries.concat(in_flight.filter_map do |entry|
                     begin
                       live_chat_entry(entry[:path], reference)
                         .merge(source: :jobs, jobs_file: short_path_from_path(entry[:jobs_file]))
                     rescue StandardError
                       # the chat vanished while being read: the delegated
                       # job finished and cleaned up; report nothing for it
                       nil
                     end
                   end)
    entries = entries.sort_by { |entry| [-Time.parse(entry[:mtime]).to_i, entry[:path]] }
    entries.first[:likely_active] = true unless entries.empty?

    {
      root: short_path_from_path(Chat.provenance_path(root_kind, root)),
      root_kind: root_kind,
      chats: entries,
      total: entries.length,
      # The mode that produced the reported chats: the traversal mode when
      # it found anything, :jobs when only in-flight discovery did; when
      # nothing was found the fallback mode is kept, as before.
      source: files.any? ? primary_source : (in_flight.any? ? :jobs : primary_source),
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

  input :file, :path, 'Chat file (the save_file whose inbox is inspected)', nil, required: true, jobname: true, nofile: true
  desc 'Pending and delivered inbox messages of a chat, with full content; missing directories are empty lists, never errors.'
  task :inbox_state => :json do |file|
    root_kind, root = resolve_root(file)
    raise ParameterException, 'inbox_state requires a chat file root; pass the chat path directly' unless root_kind == :chat

    save_file = File.expand_path(root.to_s)
    files_dir = save_file + '.files'
    # scout-ai owns the inbox location (per-save-file sibling of the save
    # file, not a subdir of <save_file>.files); the helpers are the only
    # sanctioned way to derive it.
    inbox_dir = Chat.inbox_dir(save_file)
    removed_dir = Chat.inbox_removed_dir(save_file)

    # The inbox is read while a live inference may be consuming it: a note
    # that moves between listing and reading is a race that resolves by
    # skipping the entry, never by failing the whole report.
    describe_inbox_files = lambda do |dir|
      (File.directory?(dir) ? Dir.glob(File.join(dir, '*')).select { |f| File.file?(f) } : [])
        .collect { |path| (inbox_entry(path) rescue nil) }
        .compact
        .sort_by { |entry| entry[:name] }
    end

    pending = describe_inbox_files.call(inbox_dir)
    delivered = describe_inbox_files.call(removed_dir)

    {
      save_file: short_path_from_path(save_file),
      files_dir: short_path_from_path(files_dir),
      inbox_dir: short_path_from_path(inbox_dir),
      inbox_removed_dir: short_path_from_path(removed_dir),
      pending: pending,
      delivered: delivered
    }
  end

  input :file, :path, 'Chat file (the save_file whose inbox receives the advice)', nil, required: true, jobname: true, nofile: true
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

    # An inbox file named 'abort' is a reserved control signal, not a note:
    # scout-ai consumes it once and aborts the live inference without ever
    # showing its content to the model. Advice must never be able to kill an
    # inference, so the reserved name is rejected before anything is written.
    if name == Chat::INBOX_ABORT_FILE
      raise ParameterException,
            "Inbox note name '#{name}' is reserved: it would abort the live inference instead of delivering advice; pick another name"
    end

    name ||= Time.now.strftime('%Y%m%d-%H%M%S') + '-advice.md'
    save_file = File.expand_path(root.to_s)
    inbox_dir = Chat.inbox_dir(save_file)
    FileUtils.mkdir_p(inbox_dir)

    target = File.join(inbox_dir, name)
    raise ParameterException, "Inbox note already exists: #{name}" if File.exist?(target)
    Open.write(target, message)

    {
      posted: short_path_from_path(target),
      name: name,
      save_file: short_path_from_path(save_file),
      inbox_dir: short_path_from_path(inbox_dir),
      size: File.size(target),
      note: 'delivered as a user message on the next real inference; consume-once; the moved file in inbox_removed/ is the delivery record'
    }
  end


  export_exec :chat_overview, :chat_timeline, :chat_messages, :chat_range,
              :chat_tool_call, :chat_tool_calls, :chat_tokens, :chat_accounting,
              :live_chats, :inbox_state, :post_inbox_advice
end

require 'ChatAnalyst/api'
require 'ChatAnalyst/tasks/api_tasks'



