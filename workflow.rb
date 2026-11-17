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








  # Contract 2F accounting columns (phase 3): all counts are int-strings in
  # the mixed all-String table; imports/unresolved_imports/delegated_subtrees
  # are multi-value cells (|-joined, |-free enforced by TSVBase.multi).
  ACCOUNTING_FIELDS = %w[imports unresolved_imports messages pt ct tt cct cwt rt
                         token_events conflicts incomplete_evidence tool_calls direct_jobs
                         direct_pt direct_ct direct_tt direct_cct direct_cwt direct_rt direct_events
                         delegated_pt delegated_ct delegated_tt delegated_cct delegated_cwt delegated_rt
                         delegated_events delegated_subtrees warnings].freeze

  # One encoded accounting row: the direct/delegated token columns are summed
  # from the GIVEN event arrays (the same partition the caller computed), so
  # the own and closure scopes share one row spelling.
  helper :accounting_row do |chat:, imports:, unresolved_imports:, messages:, tokens:, token_events:,
                             conflicts:, incomplete_evidence:, tool_calls:, direct_jobs:,
                             direct_events:, delegated_events:, delegated_subtrees:, warnings:|
    token_sum = lambda do |events, key|
      events.sum { |event| (event[:tokens] || {})[key] || 0 }
    end
    count_fields = %i[pt ct tt cct cwt rt]
    [ChatAnalyst::Ids.chat_id(chat),
     [ChatAnalyst::TSVBase.multi(imports, encoder: :path),
      ChatAnalyst::TSVBase.multi(unresolved_imports, encoder: :text),
      ChatAnalyst::TSVBase.integer(messages)] +
       count_fields.collect { |key| ChatAnalyst::TSVBase.integer(tokens[key]) } +
       [ChatAnalyst::TSVBase.integer(token_events.length),
        ChatAnalyst::TSVBase.integer(conflicts),
        ChatAnalyst::TSVBase.integer(incomplete_evidence),
        ChatAnalyst::TSVBase.integer(tool_calls),
        ChatAnalyst::TSVBase.integer(direct_jobs)] +
       count_fields.collect { |key| ChatAnalyst::TSVBase.integer(token_sum.call(direct_events, key)) } +
       [ChatAnalyst::TSVBase.integer(direct_events.length)] +
       count_fields.collect { |key| ChatAnalyst::TSVBase.integer(token_sum.call(delegated_events, key)) } +
       [ChatAnalyst::TSVBase.integer(delegated_events.length),
        ChatAnalyst::TSVBase.multi(delegated_subtrees, encoder: :path),
        ChatAnalyst::TSVBase.integer(warnings)]]
  end

  input :file, :path, 'Root chat file or chat-producing job', nil, required: true, jobname: true, nofile: true
  input :scope, :string, "Accounting scope: 'own' (default) accounts each chat in the import closure separately from its own file; 'closure' merges the whole closure into one root entry", 'own', nofile: true
  desc 'Accounting TSV for a chat and every chat it imports (contract 2F): own scope = one row per closure chat, closure scope = ONE merged row keyed by the root (the scope annotation carries which). Columns: imports/unresolved_imports/delegated_subtrees (multi, |-joined, |-free enforced), messages, pt..rt, token_events, conflicts, incomplete_evidence, tool_calls, direct_jobs, direct_pt..rt, direct_events, delegated_pt..rt, delegated_events, warnings - all int-strings (mixed table, no cast). Chat-root-only guard and the once-per-chat single-pass composition are unchanged.'
  task :chat_accounting => :tsv do |file, scope|
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

    count_fields = %i[pt ct tt cct cwt rt]
    # Direct/delegated partition (phase-2 semantics, unchanged): canonical
    # evidence (evidence.first) whose source is the chat file itself is
    # direct; anything else is delegated spend.
    partition = lambda do |chat|
      events = fetch.call(chat)[:report][:events]
      events.partition do |event|
        evidence = event[:evidence].first
        evidence && evidence[:source] == chat
      end
    end

    token_sum = lambda do |events|
      count_fields.each_with_object({}) do |key, sum| sum[key] = 0 end.tap do |sum|
        events.each do |event|
          (event[:tokens] || {}).each { |key, value| sum[key] += value if sum.key?(key) }
        end
      end
    end

    rows = closure.collect do |chat|
      data = fetch.call(chat)
      report = data[:report]
      direct_events, delegated_events = partition.call(chat)
      overview = data[:overview]
      imports = data[:relationships][:references].select { |reference| reference[:type] == :import }
      accounting_row(
        chat: chat,
        imports: imports.collect { |relationship| relationship[:target] }.compact,
        unresolved_imports: imports.reject { |relationship| relationship[:resolved] }
                                   .collect { |relationship| relationship[:reference] },
        messages: overview[:chats].sum { |record| record[:messages] },
        tokens: report[:scopes][:deduplicated_total],
        token_events: report[:events],
        conflicts: report[:conflicts][:events],
        incomplete_evidence: report[:conflicts][:incomplete_evidence_events],
        tool_calls: overview[:chats].sum { |record| ChatAnalyst.tool_calls(record[:path])[:calls].length },
        direct_jobs: overview[:jobs].length,
        direct_events: direct_events,
        delegated_events: delegated_events,
        delegated_subtrees: overview[:chats].flat_map { |record| record[:job_references].values.flatten }.uniq,
        warnings: report[:warnings].length
      )
    end

    # Closure scope: ONE merged row keyed by the root, every chat's events
    # deduplicated by identity so shared work is never double counted.  The
    # merge reads the SAME memoized per-chat event lists the own-scope rows
    # were built from; tokens is never re-called.
    if scope == 'closure'
      merged = {}
      closure.each do |chat|
        fetch.call(chat)[:report][:events].each do |event|
          key = event[:identity] || event[:inference_id]
          merged[key] ||= event
        end
      end
      deduplicated = merged.values
      own_direct = closure.flat_map { |chat| partition.call(chat).first }
      own_delegated = closure.flat_map { |chat| partition.call(chat).last }
      rows = [accounting_row(
        chat: path,
        imports: closure.reject { |chat| chat == path },
        unresolved_imports: [],
        messages: closure.sum { |chat| fetch.call(chat)[:overview][:chats].sum { |record| record[:messages] } },
        tokens: token_sum.call(deduplicated),
        token_events: deduplicated,
        conflicts: deduplicated.count { |event| event[:conflict] },
        incomplete_evidence: deduplicated.count { |event| event[:incomplete_evidence] },
        tool_calls: closure.sum { |chat| fetch.call(chat)[:overview][:chats].sum { |record| ChatAnalyst.tool_calls(record[:path])[:calls].length } },
        direct_jobs: closure.sum { |chat| fetch.call(chat)[:overview][:jobs].length },
        direct_events: own_direct,
        delegated_events: own_delegated,
        delegated_subtrees: closure.flat_map { |chat| fetch.call(chat)[:overview][:chats].flat_map { |record| record[:job_references].values.flatten } }.uniq,
        warnings: closure.sum { |chat| fetch.call(chat)[:report][:warnings].length }
      )]
    end

    ChatAnalyst::TSVBase.build_table(
      key_field: 'Chat', fields: ACCOUNTING_FIELDS, rows: rows,
      annotations: {
        root_path: ChatAnalyst::Ids.escape_path(path),
        total: rows.length,
        scope: scope
      }
    )
  end

  # --- inbox access (live advice injection) ---

  # One chat log as one LIVE-CHATS TSV row (contract 2F): the CANONICAL chat
  # path is the key (Ids.chat_id -> Chat.provenance_path(:chat, ...), the
  # realpathed absolute spelling; the JSON task's ~/ shortening is dropped so
  # the live output matches every other chat key in the phase-3 surface).
  helper :live_chat_row do |path, reference_time, source, jobs_file: nil, likely_active: false|
    mtime = File.mtime(path)
    [ChatAnalyst::Ids.chat_id(path),
     [ChatAnalyst::TSVBase.timestamp(mtime),
      ChatAnalyst::TSVBase.float((reference_time - mtime).round(3)),
      ChatAnalyst::TSVBase.integer(File.size(path)),
      ChatAnalyst::TSVBase.boolean(likely_active),
      ChatAnalyst::TSVBase.text(source.to_s),
      ChatAnalyst::TSVBase.path(jobs_file)]]
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
  desc 'Live-chat discovery TSV (contract 2F): newest-first rows keyed by the CANONICAL chat path, fields mtime (iso8601(3)), age_seconds (decimal string), size (int-str), likely_active (bool-string), source (provenance|glob|jobs) and jobs_file (escaped path or \\N, :jobs rows only). The three discovery sources keep their precedence and fail-soft behavior (vanishing chats skipped). Recorded simplification: the JSON job-root status block is dropped (it described the root, not a row; the root is addressable through chat_overview/job_overview).'
  task :live_chats => :tsv do |file|
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

    # The discovery mode that produced the rows is recorded in the comment
    # above; the per-row source cells say provenance/glob/jobs themselves.
    _table_source = files.any? ? primary_source : (in_flight.any? ? :jobs : primary_source)

    reference = Time.now
    rows = files.collect do |path|
      begin
        live_chat_row(path, reference, primary_source)
      rescue StandardError
        nil
      end
    end.compact
    rows.concat(in_flight.filter_map do |entry|
                  begin
                    live_chat_row(entry[:path], reference, :jobs,
                                  jobs_file: File.expand_path(entry[:jobs_file].to_s))
                  rescue StandardError
                    # the chat vanished while being read: the delegated
                    # job finished and cleaned up; report nothing for it
                    nil
                  end
                end)
    # Newest-first flag: the first surviving row (newest mtime) is the one
    # most likely to be receiving writes.
    rows.sort_by! { |row| [-Time.parse(row[1][0]).to_i, row[0]] }
    rows.first && rows.first[1][3] = 'true' unless rows.empty?

    ChatAnalyst::TSVBase.build_table(
      key_field: 'Chat',
      fields: %w[mtime age_seconds size likely_active source jobs_file],
      rows: rows,
      annotations: {
        root_path: ChatAnalyst::Ids.escape_path(Chat.provenance_path(root_kind, root)),
        total: rows.length
      }
    )
  end

  # One inbox note as one INDEX row (contract 2F): NO note body.  The body
  # surface is inbox_note (point read); pinning the index-only behavior is
  # the recorded phase-3 behavior change for inbox_state.
  helper :inbox_note_row do |path, state|
    mtime = File.mtime(path) rescue nil
    return nil unless mtime
    [ChatAnalyst::Ids.escape_path(File.expand_path(path)),
     [ChatAnalyst::TSVBase.text(state.to_s),
      ChatAnalyst::TSVBase.text(File.basename(path)),
      ChatAnalyst::TSVBase.timestamp(mtime),
      ChatAnalyst::TSVBase.integer((File.size(path) rescue nil))]]
  end

  input :file, :path, 'Chat file (the save_file whose inbox is inspected)', nil, required: true, jobname: true, nofile: true
  desc 'Inbox INDEX TSV (contract 2F): one row per pending/delivered note keyed by the absolute escaped note path, fields state (pending|delivered), name, mtime, size. Recorded behavior change: note bodies are NO LONGER embedded (read them with inbox_note). Missing directories are an empty table, never an error; the per-entry race tolerance is unchanged (a note consumed between listing and stat is skipped).'
  task :inbox_state => :tsv do |file|
    root_kind, root = resolve_root(file)
    raise ParameterException, 'inbox_state requires a chat file root; pass the chat path directly' unless root_kind == :chat

    save_file = File.expand_path(root.to_s)
    # scout-ai owns the inbox location (per-save-file sibling of the save
    # file, not a subdir of <save_file>.files); the helpers are the only
    # sanctioned way to derive it.
    inbox_dir = Chat.inbox_dir(save_file)
    removed_dir = Chat.inbox_removed_dir(save_file)

    # The inbox is read while a live inference may be consuming it: a note
    # that moves between listing and reading is a race that resolves by
    # skipping the entry, never by failing the whole report.
    describe_inbox_files = lambda do |dir, state|
      (File.directory?(dir) ? Dir.glob(File.join(dir, '*')).select { |f| File.file?(f) } : [])
        .collect { |path| (inbox_note_row(path, state) rescue nil) }
        .compact
        .sort_by { |row| row[1][1] }
    end

    rows = describe_inbox_files.call(inbox_dir, :pending)
    rows.concat(describe_inbox_files.call(removed_dir, :delivered))

    ChatAnalyst::TSVBase.build_table(
      key_field: 'Note', fields: %w[state name mtime size], rows: rows,
      annotations: {
        root_path: ChatAnalyst::Ids.escape_path(save_file),
        total: rows.length
      }
    )
  end

  input :file, :path, 'Chat file (the save_file whose inbox holds the note)', nil, required: true, jobname: true, nofile: true
  input :name, :string, 'Inbox note file name (plain name, no path)', nil, required: true, nofile: true
  desc 'Read ONE inbox note (:text output; the note\'s exact contents). A point read, not discovery: the note name must be a plain file name and the note must exist in the pending or delivered inbox of the save file, else ParameterException. Together with the index-only inbox_state this replaces the old full-content embedding.'
  task :inbox_note => :text do |file, name|
    root_kind, root = resolve_root(file)
    raise ParameterException, 'inbox_note requires a chat file root; pass the chat path directly' unless root_kind == :chat
    name = name.to_s
    raise ParameterException, 'Inbox note name must be a plain file name, not a path' if name.include?('/')
    raise ParameterException, 'Inbox note name must not be empty' if name.strip.empty?

    save_file = File.expand_path(root.to_s)
    candidates = [File.join(Chat.inbox_dir(save_file), name),
                  File.join(Chat.inbox_removed_dir(save_file), name)]
    note = candidates.find { |path| File.file?(path) }
    raise ParameterException,
          "Inbox note not found: #{name} (looked in the pending and delivered inboxes of #{save_file})" unless note
    Open.read(note)
  end

  input :file, :path, 'Chat file (the save_file whose inbox receives the advice)', nil, required: true, jobname: true, nofile: true
  input :message, :string, 'Advice text to deliver on the next real inference', nil, required: true, nofile: true
  input :name, :string, 'Inbox file name (default: timestamped advice note)', nil, nofile: true
  desc 'Post advice into a live chat inbox (contract 2F): ONE-row TSV result (name, save_file, inbox_dir, size) keyed by the escaped posted path; the posting itself is the side effect. Every safeguard is kept: chat-root guard, plain-file-name validation, non-empty message, reserved abort name rejected BEFORE any write, no-overwrite on an existing note, default timestamped name. The note is delivered as a user message on the next real inference and never persisted in the transcript (delivery semantics: consume-once; the moved file in inbox_removed/ is the delivery record).'
  task :post_inbox_advice => :tsv do |file, message, name|
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

    ChatAnalyst::TSVBase.build_table(
      key_field: 'Posted', fields: %w[name save_file inbox_dir size],
      rows: [[ChatAnalyst::Ids.escape_path(File.expand_path(target)),
              [ChatAnalyst::TSVBase.text(name),
               ChatAnalyst::TSVBase.path(save_file),
               ChatAnalyst::TSVBase.path(inbox_dir),
               ChatAnalyst::TSVBase.integer(File.size(target))]]],
      annotations: {
        root_path: ChatAnalyst::Ids.escape_path(save_file),
        total: 1
      }
    )
  end

  # One live-report entry as one TSV row (contract 2F): serializes
  # ChatAnalyst.live (the fail-soft wrapper over Chat.live_report) - the
  # entry shapes are the core's, never re-derived here.
  helper :chat_live_report_row do |entry|
    reference = entry[:reference].to_s
    path = entry[:path] || entry[:agent_file] || entry[:job]
    key = reference.empty? ? ChatAnalyst::Ids.escape_path(path.to_s) : reference
    sources = [entry[:source]].flatten.compact.uniq.collect(&:to_s)
    [key,
     [ChatAnalyst::TSVBase.text(entry[:kind].to_s),
      ChatAnalyst::TSVBase.path(path),
      ChatAnalyst::TSVBase.text(entry[:state] && entry[:state].to_s),
      ChatAnalyst::TSVBase.text(entry[:status]),
      ChatAnalyst::TSVBase.boolean(entry[:chat_task].nil? ? nil : entry[:chat_task]),
      ChatAnalyst::TSVBase.text(entry[:agent]),
      ChatAnalyst::TSVBase.text(entry[:conversation]),
      ChatAnalyst::TSVBase.multi(sources, encoder: :text)]]
  end

  input :file, :path, 'Chat file or job root', nil, required: true, jobname: true, nofile: true
  desc 'Core LIVE report TSV (contract 2F): one row per live entry of ChatAnalyst.live (the fail-soft wrapper over Chat.live_report - no reimplementation). Key Entry = the job reference when non-empty else the escaped path; fields kind (inference|workload_context|agent_activity|dangling_job), path, state, status, chat_task, agent, conversation, source (multi, |-joined subset of sidecar|agent_view|society). KEPT SEPARATE from live_chats file discovery (never merged into provenance traversal).'
  task :chat_live_report => :tsv do |file|
    result = ChatAnalyst.live(file)
    rows = result[:entries].collect { |entry| chat_live_report_row(entry) }
    # Key uniqueness: the core report is folded/deduplicated by job id, but a
    # defensive positional suffix keeps the key grammar intact if two entries
    # ever arrive with the same reference AND path.
    seen = {}
    rows.each_with_index do |row, index|
      if seen[row[0]]
        rows[index] = [[row[0], seen[row[0]].to_s] * '#'] + row.drop(1)
        seen[row[0]] += 1
      else
        seen[row[0]] = 1
      end
    end
    ChatAnalyst::TSVBase.build_table(
      key_field: 'Entry',
      fields: %w[kind path state status chat_task agent conversation source],
      rows: rows,
      annotations: {
        root_path: ChatAnalyst::Ids.escape_path(result[:root][:path]),
        total: rows.length
      }
    )
  end


  export_exec :chat_overview, :job_overview, :chat_references, :job_dependencies,
              :job_dependencies_recursive, :chat_role_counts, :chat_messages,
              :chat_message, :chat_range, :chat_inferences,
              :chat_activity_clusters, :chat_activity_cluster,
              :chat_tool_call, :chat_tool_calls, :chat_tool_call_jobs,
              :chat_tokens, :chat_token_events, :chat_token_evidence,
              :chat_attribution, :chat_accounting,
              :live_chats, :chat_live_report, :inbox_state, :inbox_note,
              :post_inbox_advice
end

require 'ChatAnalyst/api'
# Phase 3 base layer (research/phase3-contract.md): the entity-ID grammar
# and the TSV serializer conventions, including the process-global
# TSV.annotation registration every task run and test must see.  Loaded
# after the API module (Ids wraps its canonical behaviors) and before any
# task file that builds tables.
require 'ChatAnalyst/ids'
require 'ChatAnalyst/tsv_base'
# Phase 3 plan step 3: inference entities and activity clusters (spec; contract
# 1h/2B/2C as amended C1-C3).  After api.rb: uses its timeline internals and
# canonical helpers; Ids must be loaded because it is addressed inside.
require 'ChatAnalyst/inferences'
require 'ChatAnalyst/tasks/api_tasks'



