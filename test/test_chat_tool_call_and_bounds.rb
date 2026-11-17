$LOAD_PATH.unshift '.'
require 'test/test_helper'
require 'test/scout/agent_meta_fixtures'

# Minimal revision phase 1, plan step 2 + step 3 additions:
# - ChatAnalyst.tool_call (Ruby API) and the chat_tool_call task: full
#   evidence for exactly one call (arguments, persisted output content,
#   status/reason/error, delegation, jobs).
# - chat_tool_call error contract: a useful error when no tool call STARTS
#   at call_index.
# - The failure-investigation chain (review flagship): timeline ->
#   chat_tool_call -> chat_range, using ONLY chat paths and integers — no
#   digest ids, no address reconstruction, no "path#index" strings.
# - chat_messages pagination + role filter + large flag (legacy
#   message_index capabilities carried forward).
# - chat_range task-level cap MAX_RANGE_MESSAGES (200) with an error naming
#   the cap and suggesting sub-ranges; first == last accepted.
class TestChatToolCallAndBounds < Test::Unit::TestCase
  include ChatAnalystFixtures
  IDS = ChatAnalyst::Ids

  def teardown
    ChatAnalyst::TIMELINE_CACHE.clear
  end

  # Root chat with a failing bash call whose output carries the JSON
  # envelope a command-style tool returns, plus a succeeding read call and
  # an ask delegation with a receipt-anchored job.
  def failing_calls_chat(dir)
    worker = make_job(dir, 'Worker/ask/Default_w', logs: {'agent.chat' => "user: w\nassistant: ok\n"})
    path = write_chat(dir, 'fails.chat', "user: run\n" +
      'function_call: ' + %({"name":"ask","arguments":"{\\"agent\\":\\"Worker\\"}","id":"a1"}) + "\n" +
      'function_call_output: ' + %({"name":"ask","content":"ok","id":"a1","meta":#{[meta_receipt("job=#{worker}")].to_json}}) + "\n" +
      'function_call: ' + %({"name":"bash","arguments":"{\\"cmd\\":\\"bad\\"}","id":"t2"}) + "\n" +
      'function_call_output: ' + %({"name":"bash","content":"{\\"stderr\\":\\"boom\\",\\"exit_status\\":1}","id":"t2"}) + "\n" +
      'function_call: ' + %({"name":"read","arguments":"{\\"path\\":\\"a\\"}","id":"t3"}) + "\n" +
      'function_call_output: ' + %({"name":"read","content":"data","id":"t3"}) + "\n" +
      "meta: pt=1 ct=1 tt=2 inference_id=p1\n" +
      "assistant: done\n")
    [path, worker]
  end

  # -- step 2: ChatAnalyst.tool_call -------------------------------------------

  def test_tool_call_returns_full_evidence_for_a_failed_call
    TmpFile.with_dir do |dir|
      path, = failing_calls_chat(dir)
      record = ChatAnalyst.tool_call(path, 3)
      assert_equal 'bash', record[:tool]
      assert_equal({'cmd' => 'bad'}, record[:arguments])
      assert_equal 3, record[:call_index]
      assert_equal 4, record[:output_index]
      assert_equal :failure, record[:status]
      assert_equal :exit_status, record[:reason]
      assert_equal 1, record[:error][:exit_status]
      # The ACTUAL persisted output content, not just a status summary.
      assert record[:output].include?('"boom"')
      assert record[:output_characters] > 0
      assert Integer === record[:argument_characters]
      refute record[:delegated]
      assert_equal [], record[:jobs]
      # plain serializable data only
      JSON.generate(record)
    end
  end

  def test_tool_call_returns_delegation_and_job_references
    TmpFile.with_dir do |dir|
      path, worker = failing_calls_chat(dir)
      record = ChatAnalyst.tool_call(path, 1)
      assert_equal 'ask', record[:tool]
      assert_equal 'Worker#default', record[:delegation_target]
      assert record[:delegated]
      assert_equal [worker], record[:jobs]
      assert_equal 18, record[:argument_characters]
    end
  end

  def test_tool_call_error_when_no_call_starts_at_index
    TmpFile.with_dir do |dir|
      path, = failing_calls_chat(dir)
      # index 2 is a function_call_output: no call STARTS there.
      error = assert_raise(ArgumentError) { ChatAnalyst.tool_call(path, 2) }
      assert_match(/No tool call starts at index 2/, error.message)
      assert_match(/#{Regexp.escape(path)}/, error.message)
      assert_match(/function_call\/mcp_call start/, error.message)
      assert_match(/\[1, 3, 5\]/, error.message,
                   'message names the valid call start indices')

      # index 0 is the user message: also not a call start.
      error = assert_raise(ArgumentError) { ChatAnalyst.tool_call(path, 0) }
      assert_match(/No tool call starts at index 0/, error.message)

      # out-of-range and negative indices raise the bounded error first.
      assert_raise(ArgumentError) { ChatAnalyst.tool_call(path, 99) }
      assert_raise(ArgumentError) { ChatAnalyst.tool_call(path, -1) }
    end
  end

  # Phase 3 conversion (contract 2D): chat_tool_call is a metadata-only TSV
  # (ONE row, field list identical to chat_tool_calls).  Full evidence stays
  # on the Ruby API (ChatAnalyst.tool_call) and via chat_range addresses.
  def test_chat_tool_call_task_runs_through_job_machinery
    TmpFile.with_dir do |dir|
      path, = failing_calls_chat(dir)
      tsv = ChatAnalyst.job(:chat_tool_call, {file: path, call_index: 3}).run
      assert_equal 1, tsv.length
      assert_equal 'ToolCall', tsv.key_field
      key, row = tsv.entries.first
      # the key IS the call-start Message id (chat path + '#3')
      assert_equal [IDS.chat_id(path), '3'].join('#'), key
      assert_equal 'bash', row[1]
      assert_equal 'failure', row[3]
      # BEHAVIOR-CHANGE PIN: no argument JSON, no output content in any cell
      assert row.none? { |cell| cell.include?('"cmd"') }
      assert row.none? { |cell| cell.include?('boom') }
      # ...but the sizes and addresses are present
      assert_equal '13', row[7], 'argument_characters'
      assert row[8].to_i > 0, 'output_characters'
      output_id = row[0]
      assert_equal '4', output_id.split('#').last, 'output_message_id address'
      # the address resolves: chat_range round-trips the output message
      chat, index = IDS.parse_message_id(output_id)
      slice = ChatAnalyst.job(:chat_range, {file: chat, first: index, last: index}).run
      assert Chat.parse(slice).first[:content].include?('boom')
    end
  end

  def test_compact_call_index_carries_argument_and_output_characters
    TmpFile.with_dir do |dir|
      path, = failing_calls_chat(dir)
      calls = ChatAnalyst.tool_calls(path)[:calls]
      assert calls.all? { |call| Integer === call[:argument_characters] }
      assert calls.all? { |call| Integer === call[:output_characters] }
      bash = calls.find { |call| call[:tool] == 'bash' }
      assert_equal 13, bash[:argument_characters], 'raw persisted arguments string length'
      ask = calls.find { |call| call[:tool] == 'ask' }
      assert_equal 18, ask[:argument_characters]
    end
  end

  # -- the flagship failure-investigation chain ---------------------------------

  def test_failure_investigation_chain_timeline_tool_call_range
    TmpFile.with_dir do |dir|
      path, = failing_calls_chat(dir)
      # 1) compact index: find the failing call using ONLY the task outputs.
      result = ChatAnalyst.job(:chat_tool_calls, {file: path, success: false}).run
      assert_equal 1, result.length
      key, failing = result.entries.first
      chat_path, call_index = IDS.parse_message_id(key) # plain path + integer

      # 2) detail: chat_tool_call with chat path + integer (metadata row).
      tsv = ChatAnalyst.job(:chat_tool_call, {file: chat_path, call_index: call_index}).run
      assert_equal 'bash', tsv.values.first[1]
      assert_equal key, tsv.keys.first, 'the list row and detail row agree'
      assert_equal 'failure', tsv.values.first[3]

      # 3) context: chat_range around the failure, first == last accepted.
      output_id = tsv.values.first[0]
      output_chat, output_index = IDS.parse_message_id(output_id)
      single = ChatAnalyst.job(:chat_range, {file: output_chat, first: output_index, last: output_index}).run
      assert_equal 1, Chat.parse(single).length
      assert Chat.parse(single).first[:content].include?('boom')

      around = ChatAnalyst.job(:chat_range, {file: output_chat, first: call_index, last: output_index}).run
      assert_equal 2, Chat.parse(around).length
      assert_equal %w[function_call function_call_output], Chat.parse(around).collect { |m| m[:role] }

      # The chain used no digest ids; the only composite is the TSV grammar.
      assert chat_path.is_a?(String) && !chat_path.include?('#')
      assert Integer === call_index
    end
  end

  # -- step 3: chat_messages pagination / role filter / large flag --------------

  def sized_chat(dir)
    long = 'x' * 150_000
    write_chat(dir, 'sized.chat',
               "user:\n\nshort one\n\nassistant:\n\nshort two\n\nuser:\n\n#{long}\n\nmeta: pt=1\n\nuser:\n\n")
  end

  def test_chat_messages_paginates_and_filters_by_role
    TmpFile.with_dir do |dir|
      path = sized_chat(dir)
      plain = ChatAnalyst.job(:chat_messages, {file: path}).run
      # Phase 3 TSV surface: one row per message keyed by Message id
      assert_equal 4, plain.length
      assert plain.values.all? { |row| row[3] == 'false' || row[3] == 'true' }
      assert_equal ['false', 'false', 'true', 'false'], plain.values.collect { |row| row[3] }

      only_user = ChatAnalyst.job(:chat_messages, {file: path, role: 'user'}).run
      assert_equal ['user', 'user'], only_user.values.collect { |row| row[0] }
      assert_equal ['9', '150000'], only_user.values.collect { |row| row[1] }

      paged = ChatAnalyst.job(:chat_messages, {file: path, page: 1, per_page: 3}).run
      assert_equal 3, paged.length
      assert_equal 4, paged.options[:total]
      assert_equal 2, paged.options[:total_pages]
    end
  end

  # -- step 3: chat_range cap ----------------------------------------------------

  def test_chat_range_rejects_oversized_ranges_with_cap_named
    TmpFile.with_dir do |dir|
      text = (1..205).collect { |i| "user: m#{i}\n" }.join
      path = write_chat(dir, 'long.chat', text)
      assert_equal 200, ChatAnalyst::MAX_RANGE_MESSAGES

      error = assert_raise(ParameterException) do
        ChatAnalyst.job(:chat_range, {file: path, first: 0, last: 200}).run
      end
      assert_match(/at most 200 messages/, error.message)
      assert_match(/0\.\.200/, error.message)
      assert_match(/sub-ranges/, error.message)

      # exactly at the cap is fine, and first == last is fine.
      at_cap = ChatAnalyst.job(:chat_range, {file: path, first: 0, last: 199}).run
      assert_equal 200, Chat.parse(at_cap).length
      single = ChatAnalyst.job(:chat_range, {file: path, first: 199, last: 199}).run
      assert_equal ['m200'], Chat.parse(single).collect { |m| m[:content] }
    end
  end

  def test_chat_range_task_cap_only_ruby_api_uncapped
    TmpFile.with_dir do |dir|
      text = (1..205).collect { |i| "user: m#{i}\n" }.join
      path = write_chat(dir, 'long.chat', text)
      # Ruby API stays uncapped by design (the cap is a task-layer bound).
      result = ChatAnalyst.range(path, 0, 204)
      assert_equal 205, result[:messages].length
    end
  end
end
