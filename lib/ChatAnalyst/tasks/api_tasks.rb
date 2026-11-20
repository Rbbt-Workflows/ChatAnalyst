# Stage 7: thin task adapters over the ChatAnalyst public API module
# (lib/ChatAnalyst/api.rb).  Every block here is argument validation +
# serialization ONLY: the analysis logic lives in the module methods, so the
# tasks cannot drift into re-implementing provenance semantics.  No call in
# this file builds the old materialized graph (provenance_closure /
# provenance_edges / provenance_chat_files / provenance_jobs are never used).
#
# The OLD tasks with the same names lived inline in workflow.rb and were
# retired in Phase C (see var/baselines/phase-c-removed/).  The Phase C
# legacy adapters that once shadowed some of these names were retired in the
# phase-2 minimal revision (snapshots: var/baselines/rev-phase2-removed/);
# the exported surface is exactly the task family declared in this file plus
# the operational tasks in workflow.rb.
#
# PHASE 3 (plan steps 4-6, contract research/phase3-contract.md as amended
# C1-C3): the provenance/message/inference/tool-call/token surface is
# NATIVE TSV (and :chat for chat_range/chat_message), built exclusively
# from the base layer (ChatAnalyst::TSVBase encoders / build_table /
# paginate_rows and ChatAnalyst::Ids).  Pre-conversion JSON sources are
# snapshotted in var/baselines/phase3-removed/.  chat_timeline is RETIRED
# (the only vanishing phase-3 name); chat_activity_clusters +
# chat_inferences + chat_message supersede it.  Bout 5 converts the
# tool-call and token tables (contract 2D/2E): chat_tool_call (metadata
# only - pinned reduction), chat_tool_calls, chat_tool_call_jobs,
# chat_tokens (summary; attribution input retired), chat_token_events,
# chat_token_evidence, chat_attribution.  The ONLY remaining JSON tasks
# are the operational family in workflow.rb (chat_accounting, live_chats,
# inbox_state, post_inbox_advice) - the next phase-3 bout.

module ChatAnalyst
  TS = ChatAnalyst::TSVBase
  IDS = ChatAnalyst::Ids

  # -- helpers shared by the TSV adapters ---------------------------------

  # The escaped-canonical-path annotation value (contract 1f): a raw '#'
  # inside an annotation value corrupts the '#:'-line grammar, so every
  # path-valued annotation carries the ESCAPED path.
  helper :root_path_annotation do |path|
    IDS.escape_path(path.to_s)
  end

  # Message id for one chat/index (the 1a grammar), via the canonical path.
  helper :message_id_for do |chat_path, index|
    IDS.message_id(chat_path, index)
  end

  # Convert an ArgumentError from the module layer into the task layer's
  # ParameterException (the contract's error convention: malformed ids,
  # unknown cluster ids, invalid max_gap_seconds surface as
  # ParameterException at the task layer).  Helpers are blocks evaluated as
  # methods on the Step, so `yield` inside a helper body is the helper's
  # own block, not the task's: pass the guarded code as a lambda.
  helper :parameterize do |&block|
    begin
      block.call
    rescue ArgumentError => error
      raise ParameterException, error.message
    end
  end

  # -- A. Overview and relationship tables --------------------------------

  input :file, :path, 'Root chat file or job root (job detected via .info sidecar)', nil, required: true, jobname: true, nofile: true
  input :root_type, :string, 'Force root type: "chat" or "job" (default: detect)', nil, nofile: true
  desc 'TSV overview of the provenance tree: one row per chat (messages, references = job references + delegations, warnings). Annotations carry root_path plus the chats/jobs/delegations summary counts. Import/continue/last relationship references live in chat_references.'
  task :chat_overview => :tsv do |file, root_type|
    result = ChatAnalyst.overview(file, root_type: root_type ? root_type.to_sym : nil)
    delegations = result[:chats].sum { |record| Array(record[:delegation_references].to_a).length }
    rows = result[:chats].collect do |record|
      references = Array(record[:job_references].to_a).sum { |_index, paths| Array(paths).length } +
                   Array(record[:delegation_references].to_a).length
      [IDS.chat_id(record[:path]),
       [record[:messages].to_s,
        references.to_s,
        Array(record[:warnings]).length.to_s]]
    end
    ChatAnalyst::TSVBase.build_table(
      key_field: 'Chat', fields: %w[messages references warnings], rows: rows,
      annotations: {
        root_path: root_path_annotation(result[:root][:path]),
        total: rows.length,
        chats: rows.length,
        jobs: result[:jobs].length,
        delegations: delegations
      }
    )
  end

  input :file, :path, 'Root chat file or job root', nil, required: true, jobname: true, nofile: true
  desc 'TSV overview of the job nodes of the provenance tree (the job root included when the root is a job): result chat path when the job result is chat-typed, direct dependency count, live log count. root_path/total annotations.'
  task :job_overview => :tsv do |file|
    result = ChatAnalyst.overview(file)
    rows = result[:jobs].collect do |job|
      job_path = job[:path].to_s
      # chat-typed result only (the core rule: job type == chat AND the
      # result file exists); any other result carries \N
      result_chat = File.file?(job_path) && File.file?(job_path + '.info') &&
                    Step.load(job_path).type.to_s == 'chat' ? job_path : nil
      [IDS.job_id(job_path),
       [TS.path(result_chat),
        job[:dependencies].length.to_s,
        job[:live].length.to_s]]
    end
    ChatAnalyst::TSVBase.build_table(
      key_field: 'Job', fields: %w[result_chat dependency_count live_log_count],
      rows: rows,
      annotations: {root_path: root_path_annotation(result[:root][:path]), total: rows.length}
    )
  end

  input :file, :path, 'Chat file whose references are listed', nil, required: true, jobname: true, nofile: true
  desc 'TSV reference index of ONE chat: job references (from receipts/meta), delegations (raw agent#conversation, target_kind=agent), and import/continue/last relationship references. Key = message id#reference type#occurrence; target_kind job|chat|agent; resolution flags and short controlled reasons only.'
  task :chat_references => :tsv do |file|
    path = parameterize { ChatAnalyst.canonical_chat_path(file) }
    graph = Chat.provenance_graph(path, root_type: :chat)
    root_path = root_path_annotation(path)

    # occurrence counters per (message, reference_type), source order.
    # source_message_id/row key reuse the ESCAPED id (Ids.composite_key only
    # joins; a message id's own '#' is grammar, not a join separator).
    occurrences = Hash.new(0)
    rows = []
    reference_row = lambda do |message_id, type, target_kind, target_cell, resolved, reason|
      occurrences[[message_id, type]] += 1
      occurrence = occurrences[[message_id, type]]
      [[message_id, type, occurrence] * '#',
       [message_id, type, target_kind, target_cell,
        TS.boolean(resolved), reason]]
    end

    # job references: graph array order, keyed by the OUTPUT message index
    # the compact graph anchors them to (the values are the RESOLVED jobs'
    # canonical paths - a listed reference is resolved, but a job whose
    # result disappeared stays listed with resolved: false, reason missing)
    graph[:chats].to_a.sort_by { |index, _paths| index }.each do |index, paths|
      Array(paths).each do |job_path|
        canonical = ChatAnalyst.canonical_plain_path(job_path)
        resolved = File.exist?(canonical) || File.exist?(canonical.to_s + '.info')
        rows << reference_row.call(
          IDS.message_id(path, index), 'job_reference', 'job', TS.path(canonical),
          resolved, resolved ? TS.text(nil) : TS.text('missing')
        )
      end
    end

    # delegation references: the graph maps the ASK CALL index -> raw
    # agent#conversation (scout-ai anchors the delegation at call[:call_index])
    graph[:delegation].to_a.sort_by { |index, _target| index }.each do |index, target|
      # target_id is the RAW agent#conversation, never escaped (it is not a
      # path); a delegation is always a recorded reference (resolved: true)
      rows << reference_row.call(
        IDS.message_id(path, index), 'delegation', 'agent', TS.text(target),
        true, TS.text(nil)
      )
    end

    # relationship references: message order
    ChatAnalyst.relationship_references(path).each do |reference|
      rows << reference_row.call(
        IDS.message_id(path, reference[:message_index]), reference[:type].to_s,
        'chat', TS.path(reference[:target]), reference[:resolved],
        reference[:resolved] ? TS.text(nil) : TS.text(reference[:unresolved_reason].to_s)
      )
    end

    rows.sort_by! { |row| row[0] }
    ChatAnalyst::TSVBase.build_table(
      key_field: 'Reference', fields: %w[source_message_id reference_type target_kind target_id resolved unresolved_reason],
      rows: rows,
      annotations: {root_path: root_path, total: rows.length}
    )
  end

  input :file, :path, 'Root chat file or job root', nil, required: true, jobname: true, nofile: true
  desc 'TSV direct job dependencies of the provenance tree: one row per declared edge, key = owner job#dependency#position (1-based declared order). Ownership lives in job_overview; the recursive closure lives in job_dependencies_recursive.'
  task :job_dependencies => :tsv do |file|
    result = ChatAnalyst.overview(file)
    rows = []
    result[:jobs].each do |job|
      owner = IDS.job_id(job[:path])
      job[:dependencies].each_with_index do |dependency, position|
        rows << [IDS.composite_key(owner, IDS.job_id(dependency), position + 1),
                 [owner, TS.path(dependency), (position + 1).to_s]]
      end
    end
    ChatAnalyst::TSVBase.build_table(
      key_field: 'Dependency', fields: %w[owner_job dependency position],
      rows: rows,
      annotations: {root_path: root_path_annotation(result[:root][:path]), total: rows.length}
    )
  end

  input :file, :path, 'Root chat file or job root', nil, required: true, jobname: true, nofile: true
  input :max_depth, :integer, 'Depth cap: dependencies at depth == max_depth are not expanded further (default 10)', 10, nofile: true
  desc 'TSV recursive dependency closure of the provenance tree: BFS over direct job dependencies, key = dependency#depth, via_owner = the owner that declared the edge (first in traversal order when several do at equal depth). Smallest-depth wins, cycle-safe, stops at max_depth.'
  task :job_dependencies_recursive => :tsv do |file, max_depth|
    max_depth = Integer(max_depth)
    raise ParameterException, "Invalid max_depth #{max_depth.inspect}: must be a positive integer" unless max_depth >= 1
    result = ChatAnalyst.overview(file)
    direct = {}
    result[:jobs].each do |job|
      owner = ChatAnalyst.canonical_plain_path(job[:path])
      direct[owner] = job[:dependencies].collect { |dependency| ChatAnalyst.canonical_plain_path(dependency) }
    end
    # Seed: the ROOT-OWNED jobs only (contract 2A: depth 1 = direct
    # dependency of a root-owned job) — the root job itself, or (chat
    # root) the jobs the root chat references.  Seeding every overview
    # job would flatten the closure to all-depth-1 rows.
    root_path = ChatAnalyst.canonical_plain_path(result[:root][:path])
    seeds = if result[:root][:type] == :job
              [root_path]
            else
              root_chat = result[:chats].find { |chat| ChatAnalyst.canonical_plain_path(chat[:path]) == root_path }
              references = root_chat && root_chat[:job_references]
              Array(references && references.values).flatten.compact.uniq
                .collect { |job_path| ChatAnalyst.canonical_plain_path(job_path) }
            end
    rows = []
    seen = {}
    # Seed nodes never become rows (a cycle re-entering the root/seed is
    # closed by the visited set, not by reporting the root again).
    seeds.each { |owner| seen[ChatAnalyst.canonical_plain_path(owner)] = 0 }
    queue = seeds.collect { |owner| [ChatAnalyst.canonical_plain_path(owner), 0] }
    until queue.empty?
      owner, depth = queue.shift
      next if depth >= max_depth
      Array(direct[owner]).each do |dependency|
        reported = seen[dependency]
        # smallest-depth wins: a dependency already reported at a smaller or
        # equal depth is not repeated (equal-depth duplicates collapse to
        # the first via_owner; owners are visited in BFS order)
        next if reported && reported <= depth + 1
        seen[dependency] = depth + 1
        rows << [IDS.composite_key(TS.path(dependency), (depth + 1).to_s),
                 [TS.path(dependency), (depth + 1).to_s, TS.path(owner)]]
        queue << [dependency, depth + 1]
      end
    end

    rows.sort_by! { |row| row[0] }
    ChatAnalyst::TSVBase.build_table(
      key_field: 'Dependency', fields: %w[dependency depth via_owner],
      rows: rows,
      annotations: {root_path: root_path_annotation(result[:root][:path]), total: rows.length}
    )
  end

  input :file, :path, 'Root chat file or job root', nil, required: true, jobname: true, nofile: true
  desc 'TSV role counts of the chats of the provenance tree: key = chat#role composite, native Integer count (table casts :to_i). root_path/total annotations.'
  task :chat_role_counts => :tsv do |file|
    result = ChatAnalyst.overview(file)
    rows = []
    result[:chats].each do |record|
      chat_id = IDS.chat_id(record[:path])
      record[:roles].each do |role, count|
        rows << [IDS.composite_key(chat_id, role), [count]]
      end
    end
    rows.sort_by! { |row| row[0] }
    ChatAnalyst::TSVBase.build_table(
      key_field: 'ChatRole', fields: %w[count], rows: rows, cast: :to_i,
      annotations: {root_path: root_path_annotation(result[:root][:path]), total: rows.length}
    )
  end

  # -- B. Message and inference tables -------------------------------------

  input :file, :path, 'Chat file', nil, required: true, jobname: true
  input :role, :string, 'Optional role filter (e.g. user, assistant, meta); narrows the list only, counts stay raw', nil, nofile: true
  input :page, :integer, 'Page number (1-based); enables pagination when set', nil, nofile: true
  input :per_page, :integer, 'Items per page (default 50 when page is set)', nil, nofile: true
  desc 'TSV index of every message in one chat: role, character count, normalized timestamp or \\N, large flag (bool-string; threshold constant unchanged). Never bodies. Role filter and pagination narrow the list only.'
  task :chat_messages => :tsv do |file, role, page, per_page|
    threshold = defined?(LARGE_MESSAGE_CHARACTERS) ? LARGE_MESSAGE_CHARACTERS : 100_000
    chat_path = parameterize { ChatAnalyst.canonical_chat_path(file) }
    entries = parameterize { ChatAnalyst.message_index(chat_path) }
    rows = entries.collect do |entry|
      next if role && !role.to_s.empty? && entry[:role] != role.to_s
      [IDS.message_id(chat_path, entry[:index]),
       [TS.text(entry[:role]),
        TS.integer(entry[:characters]),
        TS.timestamp(entry[:timestamp]),
        TS.boolean(entry[:characters] > threshold)]]
    end.compact
    annotations = {root_path: root_path_annotation(chat_path)}
    page_rows, pagination = ChatAnalyst::TSVBase.paginate_rows(rows, page, per_page)
    annotations.merge!(pagination) if pagination
    # total ALWAYS counts the raw universe (contract 1f/C2 filter rule): a
    # page bounds the main list only, and the role filter narrows the list
    # without changing what total counts.
    annotations[:total] = entries.length
    rows = page_rows if page_rows
    ChatAnalyst::TSVBase.build_table(
      key_field: 'Message', fields: %w[role characters timestamp large],
      rows: rows, annotations: annotations
    )
  end

  input :message_id, :string, 'Message id: the escaped chat path, then #, then the zero-based index (the chat is recovered by parsing it)', nil, required: true, jobname: true, nofile: true
  desc "Byte-exact retrieval of exactly ONE message as a :chat output (the message's Chat.print text). The chat path and index live in the persisted job inputs (file == the chat path, first == last == the index) because a :chat output carries no metadata envelope. Malformed ids and out-of-range indices raise ParameterException."
  task :chat_message => :chat do |message_id|
    begin
      chat_path, index = IDS.parse_message_id(message_id)
    rescue ArgumentError => error
      raise ParameterException, error.message
    end
    chat = parameterize { Chat.load(chat_path) }
    valid = "0..#{chat.length - 1}"
    unless Integer === index && index >= 0 && index < chat.length
      raise ParameterException,
            "Message index #{index} out of range for #{chat_path}: valid range #{valid} (#{chat.length} messages)"
    end
    Chat.print([chat[index]])
  end

  input :file, :path, 'Chat file', nil, required: true, jobname: true
  input :first, :integer, 'Zero-based first message (inclusive)', 0
  input :last, :integer, 'Zero-based last message (inclusive)', nil, required: true
  desc "Byte-exact persisted slice of one chat as a :chat output (the exact Chat.print text; the old raw:true behavior is now THE output, the raw input is retired - pinned behavior change). Task-level cap #{MAX_RANGE_MESSAGES} messages per request; use sub-ranges for longer spans. The addressing (file/first/last) lives in the persisted job inputs because a :chat output carries no metadata envelope."
  task :chat_range => :chat do |file, first, last|
    # Chat files only (ported pin from the retired raw-range adapter): a
    # persisted Step root (.info sidecar) is a JOB root - job trees enter
    # through chat_overview/job_overview paths, never range addressing.
    raise ParameterException,
          'chat_range requires a chat file root; pass the chat path directly' if File.exist?(File.expand_path(file.to_s) + '.info')
    raise ParameterException,
          "chat_range retrieves at most #{MAX_RANGE_MESSAGES} messages per request (asked #{last - first + 1} for #{first}..#{last}); request sub-ranges (e.g. #{first}..#{[last, first + MAX_RANGE_MESSAGES - 1].min}) instead" if last - first + 1 > MAX_RANGE_MESSAGES
    # Phase 3 (contract 2B): the byte-exact persisted slice is THE output
    # (the old raw:true behavior inherent); the raw INPUT is retired; the
    # envelope fields chat/first/last live in the persisted job INPUTS
    # because a :chat output carries no '#:' annotation line.  ArgumentError
    # from the loader maps to ParameterException (task-layer contract).
    begin
      result = parameterize { ChatAnalyst.range(file, first, last) }
    rescue ArgumentError => error
      raise ParameterException, error.message
    end
    Chat.print(Chat.load(result[:chat])[first..last])
  end

  input :file, :path, 'Root chat file or job root', nil, required: true, jobname: true, nofile: true
  input :max_gap_seconds, :integer, 'Seconds between inference timestamps above which a new activity cluster starts (default 120)', 120, nofile: true
  input :page, :integer, 'Page number (1-based); enables pagination when set', nil, nofile: true
  input :per_page, :integer, 'Items per page (default 50 when page is set)', nil, nofile: true
  input :chat, :string, 'Exact chat path filter; narrows the listed rows only, counts stay raw', nil, nofile: true
  desc 'TSV tree-wide inference index (root-scoped, chronological): one row per inference meta with reasoning presence/characters, span/trigger/assistant message ids, activity cluster id and tool-call count. Serializes ChatAnalyst.inferences - no reimplementation. Paginated when page is given.'
  task :chat_inferences => :tsv do |file, max_gap_seconds, page, per_page, chat|
    records = parameterize { ChatAnalyst.inferences(file, max_gap_seconds: max_gap_seconds) }
    root_path = parameterize { ChatAnalyst.canonical_chat_path(file) }
    annotations = {root_path: root_path_annotation(root_path), max_gap_seconds: max_gap_seconds}
    all = records.collect do |record|
      [record[:inference_id],
       [TS.timestamp(record[:timestamp]),
        TS.boolean(record[:reasoning_present]),
        TS.integer(record[:reasoning_characters]),
        TS.text(record[:first_message_id]),
        TS.text(record[:last_message_id]),
        TS.text(record[:trigger_message_id]),
        TS.text(record[:assistant_message_id]),
        TS.text(record[:activity_cluster_id]),
        TS.integer(record[:tool_call_count])]]
    end
    rows = chat && !chat.to_s.empty? ? all.select { |row, _values| IDS.parse_message_id(row)[0] == ChatAnalyst.canonical_chat_path(chat) } : all
    page_rows, pagination = ChatAnalyst::TSVBase.paginate_rows(rows, page, per_page)
    annotations.merge!(pagination) if pagination
    # total counts the RAW tree-wide universe (contract 2B/C2: the chat
    # filter narrows the listed rows only, counts stay raw; pagination
    # never changes total).
    annotations[:total] = all.length
    rows = page_rows if page_rows
    ChatAnalyst::TSVBase.build_table(
      key_field: 'Inference',
      fields: %w[timestamp reasoning_present reasoning_characters first_message_id last_message_id trigger_message_id assistant_message_id activity_cluster_id tool_call_count],
      rows: rows, annotations: annotations
    )
  end

  # -- C. Activity clusters --------------------------------------------------

  input :file, :path, 'Root chat file or job root', nil, required: true, jobname: true, nofile: true
  input :max_gap_seconds, :integer, 'Seconds between inference timestamps above which a new activity cluster starts (default 120)', 120, nofile: true
  desc 'TSV COMPACT INDEX of activity clusters (replaces chat_timeline temporal grouping): key = the cluster id (Message id of the first inference), first/last timestamps, duration, member inference count, chats (multi-value), tool-call and delegation counts. No member lists; members live in chat_activity_cluster.'
  task :chat_activity_clusters => :tsv do |file, max_gap_seconds|
    computation = parameterize { ChatAnalyst.activity_clusters(file, max_gap_seconds: max_gap_seconds) }
    rows = computation[:clusters].collect do |cluster|
      [cluster[:cluster_id],
       [TS.timestamp(cluster[:first_timestamp]),
        TS.timestamp(cluster[:last_timestamp]),
        TS.float(cluster[:duration_seconds]),
        TS.integer(cluster[:inference_count]),
        TS.multi(cluster[:chats], encoder: :text),
        TS.integer(cluster[:tool_call_count]),
        TS.integer(cluster[:delegation_count])]]
    end
    summary = computation[:summary]
    ChatAnalyst::TSVBase.build_table(
      key_field: 'Cluster',
      fields: %w[first_timestamp last_timestamp duration_seconds inference_count chats tool_call_count delegation_count],
      rows: rows,
      annotations: {
        root_path: root_path_annotation(computation[:root][:path]),
        max_gap_seconds: max_gap_seconds,
        total: rows.length,
        clusters: summary[:clusters],
        inferences: summary[:inferences],
        unclustered: summary[:unclustered]
      }
    )
  end

  # The cluster-detail task REUSES the cluster index computation through a
  # Scout task dependency (the contract 1h/2C pinned pattern): the dep
  # forwards file/max_gap_seconds, so the SAME (root, max_gap_seconds)
  # cluster job produces index and members - probe evidence
  # share/probes/b4_probe_dep_pattern.rb (dep path == standalone path, gap
  # variants addressed to distinct jobs).  The index TSV carries every
  # member's cluster id implicitly through chat_inferences; for membership
  # the task re-derives members from the same in-memory API the index used
  # (ChatAnalyst.activity_cluster validates the id against the SAME
  # computation - the spec's same-clustering-validation requirement).
  dep :chat_activity_clusters
  input :file, :path, 'Root chat file or job root', nil, required: true, jobname: true, nofile: true
  input :cluster_id, :string, 'Cluster id (the Message id of the cluster first inference; a row key of chat_activity_clusters)', nil, required: true, nofile: true
  input :max_gap_seconds, :integer, 'Seconds between inference timestamps above which a new activity cluster starts (default 120)', 120, nofile: true
  desc 'TSV member detail of ONE activity cluster (the two-mode selection chat_timeline had): one row per member inference in chronological order, field list identical to chat_inferences. Validated against the SAME (root, max_gap_seconds) clustering through a task dependency on chat_activity_clusters; an unknown id raises ParameterException.'
  task :chat_activity_cluster => :tsv do |file, cluster_id, max_gap_seconds|
    # The dependency guarantees the same (root, max_gap_seconds) cluster job
    # exists/ran; its persistence IS the same computation this task selects
    # from (probe-pinned dep-path identity).
    index = step(:chat_activity_clusters).load
    members = parameterize { ChatAnalyst.activity_cluster(file, cluster_id, max_gap_seconds: max_gap_seconds) }
    rows = members.collect do |record|
      [record[:inference_id],
       [TS.timestamp(record[:timestamp]),
        TS.boolean(record[:reasoning_present]),
        TS.integer(record[:reasoning_characters]),
        TS.text(record[:first_message_id]),
        TS.text(record[:last_message_id]),
        TS.text(record[:trigger_message_id]),
        TS.text(record[:assistant_message_id]),
        TS.text(record[:activity_cluster_id]),
        TS.integer(record[:tool_call_count])]]
    end
    ChatAnalyst::TSVBase.build_table(
      key_field: 'Inference',
      fields: %w[timestamp reasoning_present reasoning_characters first_message_id last_message_id trigger_message_id assistant_message_id activity_cluster_id tool_call_count],
      rows: rows,
      annotations: {
        root_path: root_path_annotation(ChatAnalyst.canonical_chat_path(file)),
        max_gap_seconds: max_gap_seconds,
        total: rows.length
      }
    )
  end


  # -- D. Tool-call tables (contract §2D; bout 5) ----------------------------
  #
  # The shared §2D field list: IDENTICAL for chat_tool_calls and the
  # metadata-only chat_tool_call detail row.  Bodies never appear (1e): the
  # argument/output sizes and the output message id replace the arguments
  # JSON and the persisted output content the retired JSON detail carried
  # (pinned behavior change; snapshot var/baselines/phase3-removed/
  # chat_tool_call.rb).
  TOOL_CALL_FIELDS = %w[output_message_id tool call_id status reason timestamp
                        start_timestamp argument_characters output_characters
                        inference_id delegated target_agent target_conversation
                        copy_of source_kind].freeze

  # Token count fields (§2E): the core TOKEN_KEYS spelling.
  TOKEN_COUNT_FIELDS = %w[pt ct tt cct cwt rt].freeze

  # The contract §2E deduplication enumeration over the core's internal
  # symbols (scout-ai provenance/tokens.rb): :legacy_lineage renders as
  # 'lineage', :receipt_unresolved as 'receipt'.  An unknown future symbol
  # falls through verbatim rather than being invented away.
  TOKEN_DEDUPLICATION_LABELS = {
    inference_id: 'inference_id',
    provider_response_id: 'provider_response_id',
    legacy_lineage: 'lineage',
    receipt_unresolved: 'receipt'
  }.freeze

  # One ToolCall row (§2D metadata only): the call-start Message id key plus
  # the shared field list.  +chat_path+ is the call's canonical chat path;
  # +call+ is a timeline record (chat_tool_calls) or a tool_call record
  # (chat_tool_call) - both surfaces carry the same key names.  copy_of
  # arrives as an Integer index (same-chat strict copy, the timeline rule)
  # or a {chat:, call_index:} address (cross-chat mark_call_copies);
  # source_kind derives from copy_of presence (primary iff \N), exactly the
  # contract's definition, so the two copy-marking layers agree.
  helper :tool_call_row do |chat_path, call|
    copy_key = case call[:copy_of]
               when Integer then IDS.message_id(chat_path, call[:copy_of])
               when Hash then IDS.message_id(call[:copy_of][:chat], call[:copy_of][:call_index])
               end
    [IDS.message_id(chat_path, call[:call_index]),
     [TS.text(call[:output_index] ? IDS.message_id(chat_path, call[:output_index]) : nil),
      TS.text(call[:tool]),
      TS.text(call[:call_id]),
      TS.text(call[:status].to_s),
      TS.text(call[:reason]),
      TS.timestamp(call[:timestamp]),
      TS.timestamp(call[:start_timestamp]),
      TS.integer(call[:argument_characters]),
      TS.integer(call[:output_characters]),
      TS.text(call[:inference_id]),
      TS.boolean(call[:delegated]),
      TS.text(call[:target_agent]),
      TS.text(call[:target_conversation]),
      TS.text(copy_key),
      TS.text(copy_key ? 'copy' : 'primary')]]
  end

  # The tree-wide call universe chat_tool_calls and chat_tool_call_jobs
  # share (the legacy `follow: all` scope): every overview chat PLUS each
  # job's live log chats, uniq, sorted for deterministic row order.  Returns
  # [overview, sorted chat paths].
  helper :tree_wide_call_chats do |file|
    overview = ChatAnalyst.overview(file)
    chat_paths = overview[:chats].collect { |record| record[:path] } +
                 overview[:jobs].flat_map { |record| record[:live].to_a }
    [overview, chat_paths.uniq.sort]
  end

  input :file, :path, 'Chat file', nil, required: true, jobname: true
  input :call_index, :integer, 'Zero-based index of the function_call/mcp_call message that starts the call', nil, required: true, nofile: true
  desc 'Metadata-only TSV row for exactly one tool call (field list identical to chat_tool_calls): status, controlled reason, timestamps, argument/output character counts, output message id, delegation split, inference ownership, copy marking. PINNED behavior change (contract 1e/2D): the old JSON task returned the full arguments and output content - this row carries sizes and addresses ONLY; retrieve bodies through chat_range on the call/output message ids.'
  task :chat_tool_call => :tsv do |file, call_index|
    record = parameterize { ChatAnalyst.tool_call(file, call_index) }
    row = tool_call_row(record[:chat], record)
    ChatAnalyst::TSVBase.build_table(
      key_field: 'ToolCall', fields: TOOL_CALL_FIELDS, rows: [row],
      annotations: {root_path: root_path_annotation(record[:chat]), total: 1}
    )
  end

  # Minimal revision (plan step 4 -> TSV bout 5): the tree-wide tool-call
  # index, same universe (overview chats plus each job's live log chats,
  # uniq), same filter/pagination/dedupe semantics (filters narrow the list
  # only; totals stay raw), keyed by the 1a ToolCall grammar.
  input :file, :path, 'Root chat file or chat-producing job', nil, required: true, jobname: true, nofile: true
  input :page, :integer, 'Page number (1-based); enables pagination when set', nil, nofile: true
  input :per_page, :integer, 'Items per page (default 50 when page is set)', nil, nofile: true
  input :dedupe, :boolean, 'Mark socialized/log copies of the same logical call; totals stay raw', false, nofile: true
  input :tool, :string, 'Exact tool-name filter for the call list; narrows the listed rows only, totals stay raw', nil, nofile: true
  input :agent, :string, 'Exact target-agent filter for the call list; narrows the listed rows only, totals stay raw', nil, nofile: true
  input :conversation, :string, 'Exact conversation filter for the call list; narrows the listed rows only, totals stay raw', nil, nofile: true
  input :chat, :string, 'Exact chat path filter; narrows the listed rows only, totals stay raw', nil, nofile: true
  input :success, :boolean, 'Success-state filter for the call list (true matches status success, false matches failure); narrows the listed rows only, totals stay raw', nil, nofile: true
  desc 'Tree-wide TSV tool-call index keyed by ToolCall (the call-start Message id): metadata only, never arguments/output bodies. Filters (tool/agent/conversation/chat/success) and pagination narrow the listed rows only; the total annotation counts the raw call universe. The retired JSON summary block (successes/failures/incomplete/copies/by_tool) is NOT carried - settled simplification: derive counts from the rows (page through), totals via the pagination annotations; the applied filters ride the filters annotation.'
  task :chat_tool_calls => :tsv do |file, page, per_page, dedupe, tool, agent, conversation, chat, success|
    overview, chat_paths = tree_wide_call_chats(file)
    calls = chat_paths.flat_map do |path|
      begin
        ChatAnalyst.tool_calls(path)[:calls].collect { |call| call.merge(chat: path) }
      rescue JSON::ParserError => e
        raise ScoutException, "Error parsing tool call JSON: " + e.message
      end
    end
    calls, = dedupe ? mark_call_copies(calls) : [calls, nil]

    # Totals stay raw (whole universe, pre-filter): the filters annotation
    # self-describes which subset the rows hold.
    total = calls.length
    applied = []
    if tool || agent || conversation || chat || !success.nil?
      calls = calls.select do |call|
        (tool.nil? || call[:tool] == tool) &&
          (agent.nil? || call[:delegation_target]&.split('#', 2)&.first == agent) &&
          (conversation.nil? || call[:delegation_target]&.split('#', 2)&.last == conversation) &&
          (chat.nil? || call[:chat] == chat) &&
          (success.nil? || (call[:status] == :success) == success)
      end
      applied << "tool=#{tool}" if tool
      applied << "agent=#{agent}" if agent
      applied << "conversation=#{conversation}" if conversation
      applied << "chat=#{chat}" if chat
      applied << "success=#{success}" unless success.nil?
    end

    rows = calls.collect { |call| tool_call_row(call[:chat], call) }
    annotations = {root_path: root_path_annotation(overview[:root][:path])}
    annotations[:filters] = applied.join(',') unless applied.empty?
    page_rows, pagination = ChatAnalyst::TSVBase.paginate_rows(rows, page, per_page)
    annotations.merge!(pagination) if pagination
    # total ALWAYS counts the raw universe (contract 1f: filters and
    # pagination bound the listed rows only).
    annotations[:total] = total
    rows = page_rows if page_rows
    ChatAnalyst::TSVBase.build_table(
      key_field: 'ToolCall', fields: TOOL_CALL_FIELDS, rows: rows, annotations: annotations
    )
  end

  input :file, :path, 'Root chat file or chat-producing job', nil, required: true, jobname: true, nofile: true
  desc 'Flat call-to-job TSV: one row per (tool call, referenced job) pair over the tree-wide call universe (overview chats plus job live log chats, uniq - the same universe chat_tool_calls uses). Key CallJob = call-start Message id # escaped job path; the job cell is the alignment copy. A call with three job references yields three rows.'
  task :chat_tool_call_jobs => :tsv do |file|
    overview, chat_paths = tree_wide_call_chats(file)
    rows = chat_paths.flat_map do |path|
      ChatAnalyst.tool_calls(path)[:calls].flat_map do |call|
        Array(call[:jobs]).collect do |job_path|
          job_id = IDS.job_id(job_path)
          # call_message_id + '#' + escaped_job_path is a DIRECT string join
          # (contract 1a): the message id's own '#' is grammar, not a join
          # separator - same rule the chat_references composite keys use.
          [[IDS.message_id(path, call[:call_index]), job_id] * '#', [job_id]]
        end
      end
    end
    rows.sort_by! { |row| row[0] }
    ChatAnalyst::TSVBase.build_table(
      key_field: 'CallJob', fields: %w[job], rows: rows,
      annotations: {root_path: root_path_annotation(overview[:root][:path]), total: rows.length}
    )
  end

  # -- E. Token tables (contract §2E; bout 5) ---------------------------------

  input :file, :path, 'Root chat file or job root', nil, required: true, jobname: true, nofile: true
  desc 'Token SUMMARY TSV (contract 2E): four Scope rows (deduplicated_total, chat_evidence, receipt_evidence, receipt_only) x pt/ct/tt/cct/cwt/rt, native Integers via the :to_i cast. The scope rows are EVIDENCE COVERAGE descriptions: chat_evidence and receipt_evidence overlap and must not be summed (only deduplicated_total and receipt_only compare additively). The event list, evidence rows and attribution view moved to chat_token_events / chat_token_evidence / chat_attribution; the attribution input (and the event pagination inputs) are retired - pinned behavior change.'
  task :chat_tokens => :tsv do |file|
    result = ChatAnalyst.tokens(file)
    rows = ChatAnalyst::TOKEN_SCOPES.collect do |scope|
      totals = result[:scopes][scope]
      [scope.to_s, TOKEN_COUNT_FIELDS.collect { |field| TS.integer(totals[field.to_sym]) }]
    end
    ChatAnalyst::TSVBase.build_table(
      key_field: 'Scope', fields: TOKEN_COUNT_FIELDS, rows: rows, cast: :to_i,
      annotations: {
        root_path: root_path_annotation(result[:root][:path]),
        total: rows.length,
        conflicts: result[:conflicts][:events],
        incomplete_evidence: result[:conflicts][:incomplete_evidence_events]
      }
    )
  end

  input :file, :path, 'Root chat file or job root', nil, required: true, jobname: true, nofile: true
  input :page, :integer, 'Page number (1-based); enables pagination when set', nil, nofile: true
  input :per_page, :integer, 'Items per page (default 50 when page is set)', nil, nofile: true
  desc 'Paginated TSV of deduplicated token events: key TokenEvent (the 1a identity composite, e.g. inference_id#w1 or receipt#<escaped evidence address>), token counts (int-strings), the deduplication enumeration (inference_id | provider_response_id | lineage | receipt), conflict/incomplete_evidence flags, and the canonical evidence source/origin (canonical = evidence first). Serializes ChatAnalyst.tokens(file)[:events] - ONE tokens computation per run, no reimplementation.'
  task :chat_token_events => :tsv do |file, page, per_page|
    result = ChatAnalyst.tokens(file)
    rows = result[:events].collect do |event|
      tokens = event[:tokens] || {}
      canonical = event[:evidence].first
      [IDS.token_event_id(event),
       [TS.integer(tokens[:pt]),
        TS.integer(tokens[:ct]),
        TS.integer(tokens[:tt]),
        TS.integer(tokens[:cct]),
        TS.integer(tokens[:cwt]),
        TS.integer(tokens[:rt]),
        TS.text(TOKEN_DEDUPLICATION_LABELS[event[:deduplication]] || event[:deduplication].to_s),
        TS.boolean(event[:conflict]),
        TS.boolean(event[:incomplete_evidence]),
        TS.path(canonical && canonical[:source]),
        TS.text(canonical ? canonical[:origin].to_s : nil)]]
    end
    annotations = {root_path: root_path_annotation(result[:root][:path])}
    page_rows, pagination = ChatAnalyst::TSVBase.paginate_rows(rows, page, per_page)
    annotations.merge!(pagination) if pagination
    annotations[:total] = rows.length
    rows = page_rows if page_rows
    ChatAnalyst::TSVBase.build_table(
      key_field: 'TokenEvent',
      fields: TOKEN_COUNT_FIELDS + %w[deduplication conflict incomplete_evidence canonical_source canonical_origin],
      rows: rows, annotations: annotations
    )
  end

  # Evidence addresses (1a composites over the core's Array addresses):
  # a chat_meta meta_address is [chat path, index] - exactly the Message id
  # grammar; an agent_meta output_address is the same pair; an
  # evidence_address is [output_address, format, index], rendered
  # message_id#format#index.
  helper :evidence_message_address do |address|
    Array === address ? IDS.message_id(address[0], address[1]) : (address && address.to_s)
  end

  input :file, :path, 'Root chat file or job root', nil, required: true, jobname: true, nofile: true
  desc 'Aligned-by-construction TSV of token-event evidence rows: key Evidence = token_event_id#occurrence (1-based, canonical evidence first - the counted copy is occurrence 1), then origin (chat_meta | agent_meta), escaped source path, call_id/tool_name where the record carries them, and the origin-specific addresses: meta_address (Message id; chat_meta rows), evidence_address (message_id#meta#index) / output_address (Message id) / agent_meta_index (agent_meta rows), \N where the field does not apply. Same single tokens computation as chat_token_events.'
  task :chat_token_evidence => :tsv do |file|
    result = ChatAnalyst.tokens(file)
    rows = result[:events].flat_map do |event|
      event_id = IDS.token_event_id(event)
      event[:evidence].each_with_index.collect do |item, position|
        chat_meta = item[:origin] == :chat_meta
        evidence_address = nil
        if !chat_meta && Array === item[:evidence_address]
          evidence_address = IDS.composite_key(evidence_message_address(item[:evidence_address][0]),
                                               item[:evidence_address][1].to_s,
                                               item[:evidence_address][2].to_s)
        end
        # Evidence key = token_event_id#occurrence (DIRECT join, 1a: the
        # token-event id's own '#' is grammar, not a join separator).
        [[event_id, (position + 1).to_s] * '#',
         [TS.text(item[:origin].to_s),
          TS.path(item[:source]),
          TS.text(item[:call_id]),
          TS.text(item[:tool_name]),
          TS.text(chat_meta ? evidence_message_address(item[:meta_address]) : nil),
          TS.text(evidence_address),
          TS.text(chat_meta ? nil : evidence_message_address(item[:output_address])),
          TS.integer(chat_meta ? nil : item[:agent_meta_index])]]
      end
    end
    ChatAnalyst::TSVBase.build_table(
      key_field: 'Evidence',
      fields: %w[origin source call_id tool_name meta_address evidence_address output_address agent_meta_index],
      rows: rows,
      annotations: {root_path: root_path_annotation(result[:root][:path]), total: rows.length}
    )
  end

  input :file, :path, 'Root chat file or job root', nil, required: true, jobname: true, nofile: true
  desc 'Token attribution TSV (contract 2E): three Bucket rows (root, delegated, unattributed) of the canonical-evidence-source split - ChatAnalyst.attribution semantics unchanged - each with pt/ct/tt/cct/cwt/rt (int-strings) and the event count; conflicts/incomplete_evidence ride as quality annotations. The linked/unresolved job lists are NOT cells (settled simplification, contract 2E): they remain available through the overview/job surfaces.'
  task :chat_attribution => :tsv do |file|
    # ONE tokens computation per run: the attribution view reuses the report
    # through tokens_report: (the phase-2 single-fetch discipline).
    report = ChatAnalyst.tokens(file)
    view = ChatAnalyst.attribution(file, tokens_report: report)
    rows = {
      'root' => view[:root_chat_tokens],
      'delegated' => view[:delegated_tokens],
      'unattributed' => view[:unattributed_tokens]
    }.collect do |bucket, totals|
      [bucket, TOKEN_COUNT_FIELDS.collect { |field| TS.integer(totals[field.to_sym]) } << TS.integer(totals[:events])]
    end
    ChatAnalyst::TSVBase.build_table(
      key_field: 'Bucket', fields: TOKEN_COUNT_FIELDS + %w[events], rows: rows,
      annotations: {
        root_path: root_path_annotation(view[:root][:path]),
        total: rows.length,
        conflicts: report[:conflicts][:events],
        incomplete_evidence: report[:conflicts][:incomplete_evidence_events]
      }
    )
  end
end
