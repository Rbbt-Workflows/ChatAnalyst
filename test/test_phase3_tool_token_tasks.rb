$LOAD_PATH.unshift '.'
require 'test/test_helper'
require 'test/scout/agent_meta_fixtures'
require 'stringio'

# Phase 3 bout 5 (plan step 6, first half): the tool-call and token TSV
# surface (contract 2D/2E) - chat_tool_call (metadata-only detail, PINNED
# reduction), chat_tool_calls, chat_tool_call_jobs, chat_tokens (summary;
# attribution input retired), chat_token_events, chat_token_evidence,
# chat_attribution.
#
# Per-task checks: #: metadata (key_field/fields/cast/annotations), key
# uniqueness via the 1a grammars, FK resolution (message ids, token-event
# identity composites, escaped paths), pagination semantics (filters narrow
# the rows only; totals stay raw), single tokens-fetch discipline, and the
# no-payload invariant (no argument JSON, no output content, no exception
# text anywhere).
class TestPhase3ToolTokenTasks < Test::Unit::TestCase
  include ChatAnalystFixtures

  TS = ChatAnalyst::TSVBase
  IDS = ChatAnalyst::Ids

  def setup
    @__test_dir ||= File.expand_path(Scout.tmp.chatanalyst_test.to_s)
    FileUtils.mkdir_p(@__test_dir)
    @dir = File.join(@__test_dir, 'tool_token')
    FileUtils.mkdir_p(@dir)

    # A call fixture with a delegation, a failure and a copy: a worker job
    # log chat (agent.chat) carries the SAME call ids/arguments as the
    # parent so dedupe marks cross-chat copies; the parent's bash call
    # fails (the output is the JSON envelope a command tool returns); the
    # second bash call repeats the first call id -> a strict same-chat copy.
    @call_text = "user: Run the worker\n" +
                 'function_call: ' + %({"name":"ask","arguments":{"agent":"Worker","conversation":"c1"},"id":"a1"}) + "\n" +
                 'function_call: ' + %({"name":"bash","arguments":{"cmd":"ls"},"id":"b1"}) + "\n" +
                 'function_call_output: ' + %({"name":"bash","content":"{\\"stdout\\":\\"ok\\",\\"exit_status\\":0,\\"id\\":\\"b1\\"}","id":"b1"}) + "\n" +
                 'function_call: ' + %({"name":"bash","arguments":{"cmd":"ls"},"id":"b1"}) + "\n" +
                 'function_call_output: ' + %({"name":"bash","content":"{\\"stderr\\":\\"boom\\",\\"exit_status\\":1,\\"id\\":\\"b1\\"}","id":"b1"}) + "\n" +
                 "meta: pt=3 ct=2 tt=6 inference_id=p1 timestamp=2026-02-03T11:00:05.000Z\n" +
                 "assistant: done\n"
    @worker = make_job(@dir, 'Worker/ask/Default_w',
                       logs: {'agent.chat' => @call_text})
    # The PARENT anchors its ask output at the worker job through a REAL
    # receipt (gem helper meta_receipt, like every other fixture here), so
    # the call->job table and the copy-marking layers see one resolved
    # reference; the worker log chat repeats the same call ids/arguments
    # (the copy source).
    @parent = write_chat(@dir, 'parent.chat',
                         "user: Run the worker\n" +
                         'function_call: ' + %({"name":"ask","arguments":{"agent":"Worker","conversation":"c1"},"id":"a1"}) + "\n" +
                         'function_call_output: ' + receipt_output('a1', [meta_receipt("job=#{@worker}")]) + "\n" +
                         'function_call: ' + %({"name":"bash","arguments":{"cmd":"ls"},"id":"b1"}) + "\n" +
                         'function_call_output: ' + %({"name":"bash","content":"{\\"stdout\\":\\"ok\\",\\"exit_status\\":0,\\"id\\":\\"b1\\"}","id":"b1"}) + "\n" +
                         'function_call: ' + %({"name":"bash","arguments":{"cmd":"ls"},"id":"b1"}) + "\n" +
                         'function_call_output: ' + %({"name":"bash","content":"{\\"stderr\\":\\"boom\\",\\"exit_status\\":1,\\"id\\":\\"b1\\"}","id":"b1"}) + "\n" +
                         "meta: pt=3 ct=2 tt=6 inference_id=p1 timestamp=2026-02-03T11:00:05.000Z\n" +
                         "assistant: done\n")
    # receipt-only token fixture for the token family (agent_meta evidence)
    @receipt_only = fixture_receipt_only(@dir + '/receipts')
  end

  # -- shared assertions ------------------------------------------------------

  def row_for(table, key)
    fields = table.fields
    values = table[key]
    fields.each_with_index.to_h { |f, i| [f, values[i]] }
  end

  def assert_no_call_payload(table)
    table.each do |key, values|
      ([key] + values).each do |cell|
        next if cell.nil?
        refute_includes cell.to_s, 'ls"', 'argument JSON must not appear'
        refute_includes cell.to_s, 'child answer', 'output content must not appear'
        refute_includes cell.to_s, 'boom', 'exception/output body must not appear'
        refute_includes cell.to_s, 'argument'
      end
    end
  end

  # -- D. chat_tool_calls -------------------------------------------------------

  def test_chat_tool_calls_metadata_and_key_grammar
    result = ChatAnalyst.job(:chat_tool_calls, {file: @parent}).run
    assert_equal 'ToolCall', result.key_field
    assert_equal ChatAnalyst::TOOL_CALL_FIELDS, result.fields
    assert_nil result.options[:cast], 'mixed table: no native cast'

    # every key is a Message id; the tree-wide index legitimately repeats an
    # index across DIFFERENT chats (the log-copy chat), but never within one
    result.keys.each { |id| assert IDS.parse_message_id(id) }
    per_chat = Hash.new { |h, k| h[k] = [] }
    result.keys.each { |id| path, index = IDS.parse_message_id(id); per_chat[path] << index }
    per_chat.each_value { |indices| assert_equal indices.uniq, indices.sort, 'unique call starts per chat' }
    assert_no_call_payload(result)
  end

  def test_chat_tool_calls_copy_marking_and_source_kind
    result = ChatAnalyst.job(:chat_tool_calls, {file: @parent, dedupe: true}).run
    copies = result.keys.count { |id| row_for(result, id)['source_kind'] == 'copy' }
    assert copies > 0, 'the log-copy chat repeats the parent calls -> copies marked'
    result.keys.each do |id|
      row = row_for(result, id)
      assert_equal(row['copy_of'] == '\\N' ? 'primary' : 'copy', row['source_kind'])
      # copy_of resolves in-range as a Message id (FK)
      next if row['copy_of'] == '\\N'
      path, index = IDS.parse_message_id(row['copy_of'])
      assert_includes result.keys, row['copy_of'], 'copy_of points at a listed call'
    end
    # totals stay raw: dedupe marks but never drops
    raw = ChatAnalyst.job(:chat_tool_calls, {file: @parent}).run
    assert_equal raw.options[:total], result.options[:total]
  end

  def test_chat_tool_calls_filters_narrow_only_with_raw_totals
    raw = ChatAnalyst.job(:chat_tool_calls, {file: @parent}).run
    only_ask = ChatAnalyst.job(:chat_tool_calls, {file: @parent, tool: 'ask'}).run
    assert only_ask.values.all? { |row| row[1] == 'ask' }
    assert_equal raw.options[:total], only_ask.options[:total], 'total stays raw'
    assert_equal 'tool=ask', only_ask.options[:filters]

    failing = ChatAnalyst.job(:chat_tool_calls, {file: @parent, success: false}).run
    assert failing.length >= 1, 'the stderr/exit-1 copy is a failing call'
    # the filter keeps every NOT-success row: failure AND unknown (an ask
    # whose receipt output has no error fields stays unknown)
    assert failing.values.all? { |row| %w[failure unknown].include?(row[3]) },
           failing.values.collect { |row| row[3] }.inspect
    assert failing.values.any? { |row| row[3] == 'failure' }
    assert_equal raw.options[:total], failing.options[:total]
    assert_equal 'success=false', failing.options[:filters]

    none = ChatAnalyst.job(:chat_tool_calls, {file: @parent, tool: 'askx'}).run
    assert_equal 0, none.length
    assert_equal raw.options[:total], none.options[:total]

    agent = ChatAnalyst.job(:chat_tool_calls, {file: @parent, agent: 'Worker'}).run
    assert agent.values.all? { |row| row[11] == 'Worker' }
    conv = ChatAnalyst.job(:chat_tool_calls, {file: @parent, conversation: 'c1'}).run
    assert conv.values.all? { |row| row[12] == 'c1' }
  end

  def test_chat_tool_calls_pagination_semantics
    raw = ChatAnalyst.job(:chat_tool_calls, {file: @parent}).run
    total = raw.options[:total]
    assert total >= 3
    paged = ChatAnalyst.job(:chat_tool_calls, {file: @parent, page: 1, per_page: 2}).run
    assert_equal 2, paged.length
    assert_equal total, paged.options[:total]
    assert_equal 2, paged.options[:per_page]

    beyond = ChatAnalyst.job(:chat_tool_calls, {file: @parent, page: 999}).run
    assert_equal 0, beyond.length
    assert_equal total, beyond.options[:total]

    # filter + pagination combine; total still raw
    both = ChatAnalyst.job(:chat_tool_calls,
                           {file: @parent, tool: 'bash', page: 1, per_page: 1}).run
    assert_equal 1, both.length
    assert_equal total, both.options[:total]
    assert_equal 'tool=bash', both.options[:filters]
  end

  def test_chat_tool_calls_inference_fk_and_delegation_split
    # canonical persisted layout: META precedes the response segment it
    # accounts for, so the ask call IS emitted by the meta (owner rule).
    text = "user: Run the worker\n" +
           "meta: pt=3 ct=2 tt=6 inference_id=p1 timestamp=2026-02-03T11:00:05.000Z\n" +
           'function_call: ' + %({"name":"ask","arguments":{"agent":"Worker","conversation":"c1"},"id":"a1"}) + "\n" +
           'function_call_output: ' + %({"name":"ask","content":"child answer","id":"a1"}) + "\n" +
           "assistant: done\n"
    parent = write_chat(@dir, 'owned.chat', text)
    result = ChatAnalyst.job(:chat_tool_calls, {file: parent}).run
    ask_key = result.keys.find { |id| row_for(result, id)['tool'] == 'ask' }
    refute_nil ask_key
    row = row_for(result, ask_key)
    assert_equal 'true', row['delegated']
    assert_equal 'Worker', row['target_agent']
    assert_equal 'c1', row['target_conversation']
    # inference_id is a Message FK pointing at the owning meta message
    assert_equal IDS.message_id(parent, 1), row['inference_id']
  end

  # -- D. chat_tool_call (metadata-only detail; PINNED reduction) ---------------

  def test_chat_tool_call_single_metadata_row
    result = ChatAnalyst.job(:chat_tool_call, {file: @parent, call_index: 1}).run
    assert_equal 1, result.length
    assert_equal 'ToolCall', result.key_field
    assert_equal ChatAnalyst::TOOL_CALL_FIELDS, result.fields
    assert_equal 1, result.options[:total]
    assert_equal IDS.message_id(@parent, 1), result.keys.first
    assert_no_call_payload(result)

    row = row_for(result, result.keys.first)
    assert_equal 'ask', row['tool']
    assert_equal 'true', row['delegated']
    assert_equal IDS.message_id(@parent, 2), row['output_message_id']
    assert_equal '38', row['argument_characters'], 'raw persisted arguments string length'
    assert Integer(row['output_characters'])
    # status/reason are controlled strings, never exception text
    assert_includes %w[success failure unknown], row['status']
    refute_includes row['reason'].to_s, 'boom'
  end

  def test_chat_tool_call_pin_bodies_absent
    result = ChatAnalyst.job(:chat_tool_call, {file: @parent, call_index: 3}).run
    assert_equal 1, result.length
    row = row_for(result, result.keys.first)
    flat = ([result.keys.first] + result.values.first).join(' ')
    # PIN (contract 2D/1e): no argument JSON, no output content in ANY cell.
    # The reason cell may legitimately carry the CONTROLLED symbol
    # 'exit_status' (a nonzero command exit); the envelope BODY never
    # appears: no quoted keys, no 'boom'.
    refute_includes flat, '"cmd"'
    refute_includes flat, '"ls"'
    refute_includes flat, 'stdout'
    refute_includes flat, 'boom'
    refute_includes flat, '\"exit_status\"'
    # ... but sizes and addresses ARE present
    refute_equal '\\N', row['argument_characters']
    refute_equal '\\N', row['output_characters']
    assert IDS.parse_message_id(row['output_message_id'])
  end

  def test_chat_tool_call_evidence_chain_via_chat_range
    # the documented successor path: sizes+addresses in, bodies via chat_range
    detail = ChatAnalyst.job(:chat_tool_call, {file: @parent, call_index: 1}).run
    output_id = row_for(detail, detail.keys.first)['output_message_id']
    chat_path, index = IDS.parse_message_id(output_id)
    slice = ChatAnalyst.job(:chat_range, {file: chat_path, first: index, last: index}).run
    assert Chat.parse(slice).first[:content].include?('child answer')
  end

  def test_chat_tool_call_error_when_no_call_starts
    error = assert_raise(ParameterException) do
      ChatAnalyst.job(:chat_tool_call, {file: @parent, call_index: 0}).run
    end
    assert_match(/No tool call starts at index 0/, error.message)
  end

  # -- D. chat_tool_call_jobs ----------------------------------------------------

  def test_chat_tool_call_jobs_pairs_and_composite_key
    result = ChatAnalyst.job(:chat_tool_call_jobs, {file: @parent}).run
    assert_equal 'CallJob', result.key_field
    assert_equal %w[job], result.fields
    assert result.options[:total] >= 1
    assert result.keys.uniq == result.keys
    result.keys.each do |key|
      # the composite grammar: a full Message id (path#call_index) + '#' +
      # escaped job path.  The message id contributes exactly one '#'
      # (escaped paths cannot carry one), so the key carries exactly two and
      # the message part is the FIRST TWO segments.
      assert_equal 2, key.count('#'), key
      parts = key.split('#', -1)
      message_part = parts[0, 2] * '#'
      job_part = parts[2]
      path, index = IDS.parse_message_id(message_part)
      assert_equal @parent, path
      assert_equal job_part, row_for(result, key)['job'], 'alignment copy'
      assert_equal @worker, TS.unpath(job_part), 'job part unescapes to the referenced job'
    end
  end

  def test_chat_tool_call_jobs_multiple_jobs_multiple_rows
    w1 = make_job(@dir, 'W1/ask/Default_1')
    w2 = make_job(@dir, 'W2/ask/Default_2')
    parent = write_chat(@dir, 'two_jobs.chat',
                        receipt_chat_text('a1' => [meta_receipt("job=#{w1}"),
                                                   meta_receipt("job=#{w2}")]))
    result = ChatAnalyst.job(:chat_tool_call_jobs, {file: parent}).run
    assert_equal 2, result.length, 'one call, two job references -> two rows'
    assert_equal 2, result.length
    result.keys.each do |key|
      assert_equal 2, key.count('#'), 'call_message_id#job: message id contributes one #'
      assert_equal key.split('#', -1)[2], row_for(result, key)['job']
    end
    assert result.keys.uniq == result.keys
    assert_equal [IDS.escape_path(w1), IDS.escape_path(w2)].sort,
                 result.values.collect(&:first).sort
  end

  # -- E. chat_tokens (summary; attribution input retired) -----------------------

  def test_chat_tokens_summary_shape_and_native_cast
    result = ChatAnalyst.job(:chat_tokens, {file: @receipt_only}).run
    assert_equal 'Scope', result.key_field
    assert_equal ChatAnalyst::TOKEN_COUNT_FIELDS, result.fields
    assert_equal :to_i, result.options[:cast]
    assert_equal %w[deduplicated_total chat_evidence receipt_evidence receipt_only],
                 result.keys.sort_by { |k| ChatAnalyst::TOKEN_SCOPES.index(k.to_sym) }
    assert_equal 4, result.options[:total]
    assert Integer === result.options[:conflicts]
    assert Integer === result.options[:incomplete_evidence]
    assert_nil result.options[:page], 'the summary table is never paginated'

    job = ChatAnalyst.job(:chat_tokens, {file: @receipt_only})
    job.run
    reopened = TSV.open(job.path)
    assert Integer === reopened['deduplicated_total'].first,
           'native :to_i cast on read-back'
    assert_equal 182, reopened['deduplicated_total'].values_at('tt').first
    assert_equal 180, reopened['receipt_only'].values_at('tt').first
  end

  def test_chat_tokens_conflict_and_incomplete_annotations
    conflict = fixture_conflict(@dir + '/conflict')
    result = ChatAnalyst.job(:chat_tokens, {file: conflict}).run
    assert_equal 1, result.options[:conflicts]

    incomplete = fixture_incomplete_evidence(@dir + '/incomplete')
    result = ChatAnalyst.job(:chat_tokens, {file: incomplete}).run
    assert_equal 1, result.options[:incomplete_evidence]
  end

  def test_chat_tokens_retired_inputs_are_absent
    # PIN (settled behavior change): attribution (and page/per_page) inputs
    # are RETIRED - an unknown input is IGNORED by the job layer (same
    # convention as chat_range's retired raw input; pinned by executing it),
    # and the output is the summary table only.
    info = ChatAnalyst.task_info(:chat_tokens)
    declared = info[:inputs].collect { |input| input.name.to_s }
    refute_includes declared, 'attribution'
    refute_includes declared, 'page'
    refute_includes declared, 'per_page'

    result = ChatAnalyst.job(:chat_tokens, {file: @receipt_only, attribution: true}).run
    assert_equal 'Scope', result.key_field, 'unknown input ignored: still the summary table'
    assert_equal 4, result.length
  end

  # -- E. chat_token_events --------------------------------------------------------

  def test_chat_token_events_shape_identity_and_labels
    result = ChatAnalyst.job(:chat_token_events, {file: @receipt_only}).run
    assert_equal 'TokenEvent', result.key_field
    assert_equal ChatAnalyst::TOKEN_COUNT_FIELDS +
                 %w[deduplication conflict incomplete_evidence canonical_source canonical_origin],
                 result.fields
    assert result.options[:total] >= 3

    result.keys.each do |key|
      # 1a identity grammar: identity-kind#escaped-value; the value part of a
      # receipt identity may itself contain # (an evidence address) - only
      # the KIND is guaranteed separator-free.
      kind = key.split('#', 2).first
      assert_includes %w[inference_id provider_response_id lineage receipt], kind
    end
    result.values.each do |row|
      assert_includes %w[inference_id provider_response_id lineage receipt], row[6]
      assert_includes %w[true false], row[7]
      assert_includes %w[true false], row[8]
      assert_includes %w[chat_meta agent_meta], row[10]
    end
    # canonical_source FK: every non-null cell unescapes to an existing path
    result.values.each do |row|
      next if row[9] == '\\N'
      assert File.exist?(TS.unpath(row[9])), "canonical source missing: #{row[9]}"
    end
  end

  def test_chat_token_events_dedupe_enumeration_covers_all_values
    receipt_only = ChatAnalyst.job(:chat_token_events, {file: @receipt_only}).run
    assert receipt_only.values.all? { |row| row[6] == 'inference_id' }

    # a receipt WITHOUT any inference id dedupes on the receipt address
    # (identity :receipt, agent_meta origin): the core's fourth identity rule.
    unresolved = write_chat(@dir + '/unresolved', 'parent.chat',
                            receipt_chat_text('a1' => [meta_receipt('pt=7 tt=9')]))
    events = ChatAnalyst.job(:chat_token_events, {file: unresolved}).run
    labels = events.values.collect { |row| row[6] }.uniq
    assert_includes labels, 'receipt', 'receipt-only events dedupe on the receipt address'
    assert events.keys.all? { |key| key.start_with?('receipt#') }
  end

  def test_chat_token_events_pagination
    raw = ChatAnalyst.job(:chat_token_events, {file: @receipt_only}).run
    total = raw.options[:total]
    paged = ChatAnalyst.job(:chat_token_events,
                            {file: @receipt_only, page: 1, per_page: 2}).run
    assert_equal 2, paged.length
    assert_equal total, paged.options[:total]
    assert_equal 2, paged.options[:per_page]
    beyond = ChatAnalyst.job(:chat_token_events,
                             {file: @receipt_only, page: 99}).run
    assert_equal 0, beyond.length
    assert_equal total, beyond.options[:total]
  end

  def test_chat_token_events_single_tokens_fetch
    calls = 0
    ChatAnalyst.singleton_class.send(:alias_method, :__tokens_b5, :tokens)
    ChatAnalyst.singleton_class.send(:define_method, :tokens) do |*args, &block|
      calls += 1
      __tokens_b5(*args, &block)
    end
    begin
      # clean: the earlier tests already cached these jobs; a replay would
      # skip the task body entirely and prove nothing about fetch discipline.
      ChatAnalyst.job(:chat_token_events, {file: @receipt_only}).clean.run
      assert_equal 1, calls, 'ONE tokens computation per task run'
      calls = 0
      ChatAnalyst.job(:chat_token_evidence, {file: @receipt_only}).clean.run
      assert_equal 1, calls
      calls = 0
      ChatAnalyst.job(:chat_attribution, {file: @receipt_only}).clean.run
      assert_equal 1, calls, 'the attribution view reuses the one report (tokens_report:)'
    ensure
      ChatAnalyst.singleton_class.send(:alias_method, :tokens, :__tokens_b5)
      ChatAnalyst.singleton_class.send(:remove_method, :__tokens_b5)
    end
  end

  # -- E. chat_token_evidence --------------------------------------------------------

  def test_chat_token_evidence_alignment_and_canonical_first
    events = ChatAnalyst.job(:chat_token_events, {file: @receipt_only}).run
    evidence = ChatAnalyst.job(:chat_token_evidence, {file: @receipt_only}).run
    assert_equal 'Evidence', evidence.key_field
    assert_equal %w[origin source call_id tool_name meta_address
                    evidence_address output_address agent_meta_index],
                 evidence.fields

    # aligned-by-construction: every occurrence key decomposes into a listed
    # token-event id + a 1-based occurrence; canonical evidence is 1
    evidence.keys.each do |key|
      event_id, occurrence = key[0...key.rindex('#')], key[(key.rindex('#') + 1)..]
      assert events.keys.include?(event_id), "#{event_id} not in chat_token_events"
      assert Integer(occurrence) >= 1
    end
    events.keys.each do |event_id|
      first = evidence.keys.find { |k| k == "#{event_id}#1" }
      refute_nil first, "canonical occurrence 1 missing for #{event_id}"
    end

    # receipt_only fixture: every inference has ONLY receipt evidence, so
    # every row is agent_meta with output addresses.  The core record never
    # puts meta_address on an agent_meta row: that column is \N here BY
    # CONSTRUCTION (logged contract note: both address columns exist for
    # alignment; the non-applicable one is \N).
    evidence.values.each do |row|
      assert File.exist?(TS.unpath(row[1])), 'source FK resolves'
      case row[0]
      when 'agent_meta'
        refute_equal '\\N', row[5], 'agent_meta rows carry evidence_address'
        refute_equal '\\N', row[6], 'agent_meta rows carry output_address'
        assert_equal '\\N', row[4], 'meta_address is \\N on agent_meta rows'
        refute_equal '\\N', row[7], 'agent_meta rows carry the receipt index'
      when 'chat_meta'
        refute_equal '\\N', row[4], 'chat_meta rows carry meta_address'
        assert_equal '\\N', row[5], 'evidence_address is \\N on chat_meta rows'
        assert_equal '\\N', row[6], 'output_address is \\N on chat_meta rows'
        assert_equal '\\N', row[7], 'agent_meta_index is \\N on chat_meta rows'
      else
        flunk "unknown origin #{row[0]}"
      end
    end
    assert_equal 2, evidence.values.count { |row| row[0] == 'agent_meta' }
    assert_equal 1, evidence.values.count { |row| row[0] == 'chat_meta' }
  end

  def test_chat_token_evidence_chat_meta_rows
    # The suite parent: the one meta message (index 3) yields a chat_meta
    # evidence row whose meta_address is the meta Message id; the receipt
    # carries only job=, so no agent_meta rows exist here.
    evidence = ChatAnalyst.job(:chat_token_evidence, {file: @parent}).run
    rows = evidence.values
    assert rows.any? { |row| row[0] == 'chat_meta' }
    assert rows.none? { |row| row[0] == 'agent_meta' }
    # The receipt links the parent to the worker's SAVED log chat, so the
    # p1 event carries chat_meta evidence in BOTH files (canonical first =
    # parent, occurrence 2 = worker log). meta_address is each evidence's
    # own meta Message id.
    sources = {}
    rows.select { |row| row[0] == 'chat_meta' }.each do |row|
      path, index = IDS.parse_message_id(row[4])
      assert_equal TS.unpath(row[1]), path, 'meta_address shares the row source file'
      assert [7, 6].include?(index), 'meta at parent index 7 / worker log index 6'
      sources[path] = true
      # chat_meta evidence carries NO receipt address block: the receipt
      # columns are \N BY CONSTRUCTION (core record shape, logged).
      assert_equal '\\N', row[5], 'evidence_address is \N on chat_meta rows'
      assert_equal '\\N', row[6], 'output_address is \N on chat_meta rows'
      assert_equal '\\N', row[7], 'agent_meta_index is \N on chat_meta rows'
    end

    # A receipt WITH token fields adds the agent_meta side: call_id,
    # tool_name, evidence/output addresses and the receipt index.
    worker = make_job(@dir + '/tokens_chat', 'Worker/ask/Default_t')
    parent = write_chat(@dir + '/tokens_chat', 'parent.chat',
                        receipt_chat_text('a1' => [meta_receipt("job=#{worker}"),
                                                   meta_receipt('pt=7 ct=3 tt=10 inference_id=t1')]))
    both = ChatAnalyst.job(:chat_token_evidence, {file: parent}).run
    receipt_rows = both.values.select { |row| row[0] == 'agent_meta' }
    assert_equal 1, receipt_rows.length
    row = receipt_rows.first
    assert_equal 'a1', row[2]
    assert_equal 'ask', row[3]
    assert_equal '\\N', row[4]
    refute_equal '\\N', row[5]
    refute_equal '\\N', row[6]
    assert Integer(row[7]) >= 0, 'receipt entry index is a non-negative int-str'
  end

  # -- E. chat_attribution -----------------------------------------------------------

  def test_chat_attribution_three_buckets_and_cross_consumer_agreement
    result = ChatAnalyst.job(:chat_attribution, {file: @receipt_only}).run
    assert_equal 'Bucket', result.key_field
    assert_equal ChatAnalyst::TOKEN_COUNT_FIELDS + %w[events], result.fields
    assert_equal %w[root delegated unattributed].sort, result.keys.sort
    assert_equal 3, result.options[:total]

    # cross-consumer agreement (pattern from test_cross_consumer_tokens.rb):
    # the table equals ChatAnalyst.attribution directly
    view = ChatAnalyst.attribution(@receipt_only)
    assert_equal view[:root_chat_tokens][:tt], Integer(row_for(result, 'root')['tt'])
    assert_equal view[:delegated_tokens][:tt], Integer(row_for(result, 'delegated')['tt'])
    assert_equal view[:unattributed_tokens][:tt], Integer(row_for(result, 'unattributed')['tt'])
    assert_equal Integer(row_for(result, 'root')['events']) +
                 Integer(row_for(result, 'delegated')['events']) +
                 Integer(row_for(result, 'unattributed')['events']),
                 view[:total][:events]
  end

  def test_chat_attribution_quality_annotations_and_split
    result = ChatAnalyst.job(:chat_attribution, {file: @receipt_only}).run
    assert Integer === result.options[:conflicts]
    assert Integer === result.options[:incomplete_evidence]
    root_tt = Integer(row_for(result, 'root')['tt'])
    delegated_tt = Integer(row_for(result, 'delegated')['tt'])
    unattributed_tt = Integer(row_for(result, 'unattributed')['tt'])
    summary = ChatAnalyst.job(:chat_tokens, {file: @receipt_only}).run
    assert_equal root_tt + delegated_tt + unattributed_tt,
                 Integer(row_for(summary, 'deduplicated_total')['tt']),
                 'buckets partition the deduplicated total'
    # The split is over the CANONICAL evidence SOURCE: an event whose
    # canonical evidence physically lives in a linked job's chat file (the
    # saved worker log) attributes to delegated.  The plus_log fixture has
    # exactly that: w1/w2/w3 canonical in Worker agent.chat, p1 in the root.
    parent, _worker = fixture_receipt_plus_log(@dir + '/plus_log')
    plus = ChatAnalyst.job(:chat_attribution, {file: parent}).run
    assert_equal 190, Integer(row_for(plus, 'delegated')['tt'])
    assert_equal 100, Integer(row_for(plus, 'root')['tt'])
    # receipt-only scope counts events with NO chat evidence at all: here
    # zero, because the worker log saves every delegated event's evidence
    plus_summary = ChatAnalyst.job(:chat_tokens, {file: parent}).run
    assert_equal 0, Integer(row_for(plus_summary, 'receipt_only')['tt']),
                 'chat_evidence and receipt_evidence overlap; receipt_only is the disjoint part'
  end
end
