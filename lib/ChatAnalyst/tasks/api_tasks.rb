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

module ChatAnalyst
  input :file, :path, 'Root chat file or job root (job detected via .info sidecar)', nil, required: true, jobname: true, nofile: true
  input :root_type, :string, 'Force root type: "chat" or "job" (default: detect)', nil, nofile: true
  desc 'Compact overview of the provenance tree: chats with message/role counts and job/delegation references keyed by originating message index; jobs with direct dependencies. Absolute paths, zero-based indices, no bodies.'
  task :chat_overview => :json do |file, root_type|
    ChatAnalyst.overview(file, root_type: root_type ? root_type.to_sym : nil)
  end

  input :file, :path, 'Root chat file or job root', nil, required: true, jobname: true, nofile: true
  input :bursts, :array, 'Burst ids whose bouts are inlined as detail (default: none)', nil, nofile: true
  input :burst_gap, :integer, 'Seconds between bouts above which a new burst starts (default 120)', 120, nofile: true
  desc 'Timeline of persisted interaction bouts over the provenance tree: chat path + first/last zero-based message indices + timestamp + reasoning preview + tool-call positions. Bursts are temporal groupings only (elapsed-gap), never semantic phases.'
  task :chat_timeline => :json do |file, bursts, burst_gap|
    ChatAnalyst.timeline(file, bursts: Array(bursts || []).map(&:to_i), burst_gap: burst_gap)
  end

  input :file, :path, 'Chat file', nil, required: true, jobname: true
  input :role, :string, 'Optional role filter (e.g. user, assistant, meta)', nil, nofile: true
  input :page, :integer, 'Page number (1-based); enables pagination when set', nil, nofile: true
  input :per_page, :integer, 'Items per page (default 50 when page is set)', nil, nofile: true
  desc 'Zero-based index of every message in one chat: role, character count, large flag, timestamp when present. Never bodies. Role filter and pagination narrow the list only.'
  task :chat_messages => :json do |file, role, page, per_page|
    # LARGE_MESSAGE_CHARACTERS lives in workflow.rb; identical fallback for
    # standalone library use.
    threshold = defined?(LARGE_MESSAGE_CHARACTERS) ? LARGE_MESSAGE_CHARACTERS : 100_000
    messages = ChatAnalyst.message_index(file).collect do |entry|
      next if role && !role.to_s.empty? && entry[:role] != role.to_s
      entry.merge(large: entry[:characters] > threshold)
    end.compact
    envelope = paginate_items(messages, page, per_page)
    next envelope.merge(messages: envelope.delete(:items)) if envelope
    messages
  end

  input :file, :path, 'Chat file', nil, required: true, jobname: true
  input :first, :integer, 'Zero-based first message (inclusive)', 0
  input :last, :integer, 'Zero-based last message (inclusive)', nil, required: true
  input :raw, :boolean, 'Also carry the exact persisted text of the slice (Chat.print of the selected messages) under :raw', false, nofile: true
  desc "Inclusive retrieval of one message range from one chat, loading only the addressed chat. Task-level cap #{MAX_RANGE_MESSAGES} messages per request; use sub-ranges for longer spans. raw: true adds the byte-exact persisted slice text for export/import round-trips."
  task :chat_range => :json do |file, first, last, raw|
    # Chat files only (ported pin from the retired raw-range adapter): a
    # persisted Step root (.info sidecar) is a JOB root — job trees enter
    # through chat_overview/chat_timeline paths, never range addressing.
    raise ParameterException,
          'chat_range requires a chat file root; pass the chat path directly' if File.exist?(File.expand_path(file.to_s) + '.info')
    raise ParameterException,
          "chat_range retrieves at most #{MAX_RANGE_MESSAGES} messages per request (asked #{last - first + 1} for #{first}..#{last}); request sub-ranges (e.g. #{first}..#{[last, first + MAX_RANGE_MESSAGES - 1].min}) instead" if last - first + 1 > MAX_RANGE_MESSAGES
    result = ChatAnalyst.range(file, first, last)
    # Raw mode (plan step 5, decision D1): the EXACT persisted text of the
    # slice, Chat.print of the selected message objects, carried byte-exact
    # inside the structured envelope.  Chat.print emits the writer's
    # "role:\n\ncontent" line form for each message; Chat.load of that text
    # reproduces the same message sequence, which is what the retired
    # raw-slice round-trip pins demanded.
    result[:raw] = Chat.print(Chat.load(result[:chat])[first..last]) if raw
    result
  end

  input :file, :path, 'Chat file', nil, required: true, jobname: true
  input :call_index, :integer, 'Zero-based index of the function_call/mcp_call message that starts the call', nil, required: true, nofile: true
  desc 'Full evidence for exactly one tool call: arguments, persisted output content, status/reason/error, delegation target and job references. Detail counterpart of the compact chat_tool_calls index.'
  task :chat_tool_call => :json do |file, call_index|
    ChatAnalyst.tool_call(file, call_index)
  end

  # Minimal revision (plan step 4): the tree-wide STRUCTURED tool-call index.
  # Moved from workflow.rb into api_tasks.rb; per-call records carry a chat
  # path plus integers, never a "path#index" concatenated string.  Same
  # universe (overview chats plus each job's live log chats, uniq), same
  # summary-raw / filter-narrows semantics, same dedupe identity rule (the
  # MD5 in tool_call_identity stays internal).
  input :file, :path, 'Root chat file or chat-producing job', nil, required: true, jobname: true, nofile: true
  input :page, :integer, 'Page number (1-based); enables pagination when set', nil, nofile: true
  input :per_page, :integer, 'Items per page (default 50 when page is set)', nil, nofile: true
  input :dedupe, :boolean, 'Mark socialized/log copies of the same logical call; summary counts stay raw', false, nofile: true
  input :tool, :string, 'Exact tool-name filter for the call list; summary counts stay raw', nil, nofile: true
  input :agent, :string, 'Exact target-agent filter for the call list; summary counts stay raw', nil, nofile: true
  input :conversation, :string, 'Exact conversation filter for the call list; summary counts stay raw', nil, nofile: true
  input :chat, :string, 'Exact chat path filter; summary counts stay raw', nil, nofile: true
  input :success, :boolean, 'Success-state filter for the call list (true/false; true matches status :success, false matches :failure); summary counts stay raw', nil, nofile: true
  desc 'Structured tree-wide tool-call index: per-call records {chat, call_index, output_index?, tool, call_id?, status, delegated, delegation_target?, jobs, argument_characters, output_characters, copy_of?}; filters/pagination narrow the list only.'
  task :chat_tool_calls => :json do |file, page, per_page, dedupe, tool, agent, conversation, chat, success|
    # Legacy scope (old `follow: all` semantics): the call universe is every
    # chat of the session tree, INCLUDING each job's own log chats
    # (projection chats).  The compact graph lists those under :live
    # (supplementary, never followed by the core), so this task unions them
    # explicitly; ChatAnalyst.tool_calls per chat is strict (referenced chats
    # only) and never concatenates addresses.
    overview = ChatAnalyst.overview(file)
    chat_paths = overview[:chats].collect { |record| record[:path] } +
                 overview[:jobs].flat_map { |record| record[:live].to_a }
    chat_paths.uniq!
    calls = chat_paths.sort.flat_map do |path|
      ChatAnalyst.tool_calls(path)[:calls].collect do |call|
        {
          chat: path,
          call_index: call[:call_index],
          output_index: call[:output_index],
          tool: call[:tool],
          call_id: call[:call_id],
          status: call[:status],
          delegated: call[:delegated],
          delegation_target: call[:delegation_target],
          jobs: call[:jobs],
          argument_characters: call[:argument_characters],
          output_characters: call[:output_characters]
        }.compact
      end
    end
    calls, unique_calls = dedupe ? mark_call_copies(calls) : [calls, nil]

    # Summary counts stay raw (whole session); filters narrow the main list
    # only, exactly as before.  The tri-state status stays a symbol
    # (:success/:failure/:unknown); the success FILTER accepts booleans and
    # compares against status == :success.
    result = {
      total: calls.length,
      successes: calls.count { |call| call[:status] == :success },
      failures: calls.count { |call| call[:status] == :failure },
      incomplete: calls.count { |call| call[:status].nil? || call[:status] == :unknown },
      copies: calls.count { |call| call[:copy_of] },
      by_tool: calls.group_by { |call| call[:tool] || '(unknown)' }.transform_values(&:length)
    }
    result[:unique_calls] = unique_calls if unique_calls

    if tool || agent || conversation || chat || !success.nil?
      calls = calls.select do |call|
        (tool.nil? || call[:tool] == tool) &&
          (agent.nil? || call[:delegation_target]&.split('#', 2)&.first == agent) &&
          (conversation.nil? || call[:delegation_target]&.split('#', 2)&.last == conversation) &&
          (chat.nil? || call[:chat] == chat) &&
          (success.nil? || (call[:status] == :success) == success)
      end
    end
    result[:calls] = calls

    envelope = paginate_items(calls, page, per_page)
    next envelope.merge(calls: envelope.delete(:items), **result.except(:calls)) if envelope
    result
  end


  input :file, :path, 'Root chat file or job root', nil, required: true, jobname: true, nofile: true
  input :page, :integer, 'Page number (1-based); enables pagination when set', nil, nofile: true
  input :per_page, :integer, 'Items per page (default 50 when page is set)', nil, nofile: true
  input :attribution, :boolean, 'Add the root/delegated/unattributed token attribution view (ChatAnalyst.attribution) alongside the summary', false, nofile: true
  desc 'Deduplicated direct-inference token accounting (scopes, conflicts, evidence locations) delegated to the core provenance token APIs. With attribution: true the response also carries the attribution view (root/delegated/unattributed split, linked and unresolved delegation jobs). Event pages carry events + paging metadata + root only.'
  task :chat_tokens => :json do |file, page, per_page, attribution|
    result = ChatAnalyst.tokens(file)
    # Legacy-compatible flat totals (test_cross_consumer_tokens.rb pins
    # task[:deduplicated_total][:tt] etc.): the scope totals are duplicated
    # at the top level alongside the structured scopes Hash.  Evidence
    # `origin` symbols are stringified for JSON parity with the old task.
    scopes = result[:scopes]
    result[:deduplicated_total] = scopes[:deduplicated_total]
    result[:receipt_only] = scopes[:receipt_only]
    result[:chat_evidence] = scopes[:chat_evidence]
    result[:receipt_evidence] = scopes[:receipt_evidence]
    result[:attribution] = ChatAnalyst.attribution(file, tokens_report: result) if attribution

    envelope = paginate_items(result[:events], page, per_page)
    if envelope
      # Event pages repeat ONLY the paging envelope, its items and the root:
      # scopes/conflicts/warnings/flat totals stay on the unpaginated shape
      # (minimal revision phase 2, plan step 5 layering fix).  The
      # attribution view, when requested, rides along on the page too: it is
      # requested explicitly, not repeated incidentally.
      envelope[:events] = envelope.delete(:items)
      envelope[:root] = result[:root]
      envelope[:attribution] = result[:attribution] if result.key?(:attribution)
    else
      envelope = result
    end
    envelope
  end
end
