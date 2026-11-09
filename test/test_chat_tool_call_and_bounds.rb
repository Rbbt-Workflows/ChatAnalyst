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

  def test_chat_tool_call_task_runs_through_job_machinery
    TmpFile.with_dir do |dir|
      path, = failing_calls_chat(dir)
      record = ChatAnalyst.job(:chat_tool_call, {file: path, call_index: 3}).run
      assert_equal 'bash', record[:tool]
      assert_equal :failure, record[:status]
      JSON.parse(record.to_json)
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
      assert_equal 1, result[:calls].length
      failing = result[:calls].first
      chat_path = failing[:chat]        # plain chat path, no '#'
      call_index = failing[:call_index] # integer

      # 2) detail: chat_tool_call with chat path + integer.
      record = ChatAnalyst.job(:chat_tool_call, {file: chat_path, call_index: call_index}).run
      assert_equal 'bash', record[:tool]
      assert_equal({'cmd' => 'bad'}, record[:arguments])
      assert_equal 4, record[:output_index]
      assert record[:output].include?('boom')

      # 3) context: chat_range around the failure, first == last accepted.
      single = ChatAnalyst.job(:chat_range, {file: chat_path, first: 4, last: 4}).run
      assert_equal 1, single[:messages].length
      assert single[:messages].first[:content].include?('boom')

      around = ChatAnalyst.job(:chat_range, {file: chat_path, first: 3, last: 4}).run
      assert_equal 2, around[:messages].length
      assert_equal %w[function_call function_call_output], around[:messages].collect { |m| m[:role] }

      # The chain used no digest ids and no address strings anywhere.
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
      assert_equal 4, plain.length
      assert plain.all? { |message| message.key?(:large) }
      assert_equal [false, false, true, false], plain.collect { |message| message[:large] }

      only_user = ChatAnalyst.job(:chat_messages, {file: path, role: 'user'}).run
      assert_equal ['user', 'user'], only_user.collect { |message| message[:role] }
      assert_equal [9, 150_000], only_user.collect { |message| message[:characters] }

      paged = ChatAnalyst.job(:chat_messages, {file: path, page: 1, per_page: 3}).run
      assert_equal 3, paged[:messages].length
      assert_equal 4, paged[:total]
      assert paged[:messages].all? { |message| message.key?(:characters) && message.key?(:large) }
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
      assert_equal 200, at_cap[:messages].length
      single = ChatAnalyst.job(:chat_range, {file: path, first: 199, last: 199}).run
      assert_equal ['m200'], single[:messages].collect { |m| m[:content] }
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
