$LOAD_PATH.unshift '.'
require 'test/test_helper'
require 'test/scout/agent_meta_fixtures'

# Stage 7 task-family smoke: every exported task is a thin adapter over the
# module API (argument validation + serialization only, no analysis logic).
# Each test runs one representative operation through the real Scout job
# machinery so wiring, inputs and JSON serialization are exercised together.
class TestChatAnalystTasks < Test::Unit::TestCase
  include ChatAnalystFixtures

  def parent_with_job(dir)
    worker_log = "user: work\n" \
                 "meta: pt=100 ct=50 tt=150 inference_id=w1\n" \
                 "assistant: done\n"
    worker = make_job(dir, 'Worker/ask/Default_w', logs: {'agent.chat' => worker_log})
    parent = write_chat(dir, 'parent.chat',
                        receipt_chat_text('a1' => [meta_receipt("job=#{worker}")],
                                          extra: ['meta: pt=1 ct=1 tt=2 inference_id=p1']))
    [parent, worker]
  end

  # -- six thin tasks ------------------------------------------------------

  def test_chat_overview_task_serializes_module_result
    Dir.mktmpdir do |dir|
      parent, worker = parent_with_job(dir)
      result = ChatAnalyst.job(:chat_overview, {file: parent}).run
      # Phase 3 TSV surface: one row per chat, annotations on the #: line
      assert_equal 1, result.length
      row = result[result.keys.first]
      assert_equal '5', row['messages']
      assert_equal '2', row['references']
      assert result.keys.first.include?('parent.chat')
      assert result.options[:root_path]
      assert result.options[:total] == 1
      assert result.options[:chats] == 1
      assert result.options[:jobs] == 1
      assert result.options[:delegations] == 1
    end
  end

  # chat_timeline was retired in phase 3 bout 4 (snapshot:
  # var/baselines/phase3-removed/chat_timeline.rb) - the temporal surface is
  # chat_activity_clusters/chat_inferences/chat_activity_cluster, pinned in
  # test/test_phase3_temporal_tasks.rb.

  def test_chat_messages_task_indexes_one_chat
    Dir.mktmpdir do |dir|
      parent, _worker = parent_with_job(dir)
      result = ChatAnalyst.job(:chat_messages, {file: parent}).run
      assert result.length >= 4
      assert result.all? { |_key, row| row.length == 4 }
      assert result.keys.first.end_with?('#0')
    end
  end

  def test_chat_range_task_returns_inclusive_messages
    Dir.mktmpdir do |dir|
      parent, _worker = parent_with_job(dir)
      result = ChatAnalyst.job(:chat_range, {file: parent, first: 0, last: 1}).run
      # :chat output: the byte-exact persisted slice; parse back to compare
      reloaded = Chat.parse(result)
      assert_equal 2, reloaded.length
      assert_equal 'Run the worker', reloaded.first[:content]
    end
  end

  def test_chat_tool_calls_task_filters_by_range
    Dir.mktmpdir do |dir|
      parent, _worker = parent_with_job(dir)
      result = ChatAnalyst.job(:chat_tool_calls, {file: parent}).run
      assert result.length >= 1
      assert result.values.first[1], 'tool column present'
    end
  end

  def test_chat_tokens_task_reports_scopes
    Dir.mktmpdir do |dir|
      parent, _worker = parent_with_job(dir)
      result = ChatAnalyst.job(:chat_tokens, {file: parent}).run
      assert_equal 'Scope', result.key_field
      assert Integer(result['deduplicated_total'][2]) >= 151, 'deduplicated_total tt (native Integer under :to_i cast)'
    end
  end

  # -- retired legacy adapters fail fast (phase 2 retirement pins) ------------

  # The four Phase C legacy adapters were retired in phase 2 (plan step 5):
  # message_index/message_content were superseded by chat_messages (role
  # filter + pagination) and chat_range (raw mode), chat_report by the
  # attribution view (ChatAnalyst.attribution / chat_tokens attribution:true),
  # extract_chat_range by chat_range raw mode.  Their snapshots live in
  # var/baselines/rev-phase2-removed/.
  def test_retired_message_index_and_content_fail_fast
    Dir.mktmpdir do |dir|
      parent, _worker = parent_with_job(dir)
      error = assert_raise(TaskNotFound) { ChatAnalyst.job(:message_index, {file: parent}).run }
      assert_match(/message_index/, error.message)
      error = assert_raise(TaskNotFound) { ChatAnalyst.job(:message_content, {file: parent, ids: ['x#0']}).run }
      assert_match(/message_content/, error.message)
    end
  end

  def test_retired_chat_report_fails_fast
    Dir.mktmpdir do |dir|
      parent, _worker = parent_with_job(dir)
      error = assert_raise(TaskNotFound) { ChatAnalyst.job(:chat_report, {file: parent}).run }
      assert_match(/chat_report/, error.message)
    end
  end

  def test_chat_tool_calls_keeps_filters
    Dir.mktmpdir do |dir|
      parent, _worker = parent_with_job(dir)
      result = ChatAnalyst.job(:chat_tool_calls, {file: parent, dedupe: true}).run
      assert_equal 'ToolCall', result.key_field
      assert result.total >= 1, 'raw total annotation'
    end
  end

  # chat_report's adapter test was retired with the task (phase 2); the
  # attribution surface it covered is pinned in test_attribution.rb.

  # -- operational tasks untouched ------------------------------------------

  def test_live_chats_and_inbox_still_registered
    %i[live_chats inbox_state post_inbox_advice chat_accounting].each do |name|
      assert ChatAnalyst.tasks.key?(name), "#{name} missing from task family"
    end
  end

  def test_retired_tasks_are_gone
    %i[chat_agents meta_evidence chat_reasoning provenance_relationships
       message_index message_content extract_chat_range chat_report
       chat_timeline].each do |name|
      refute ChatAnalyst.tasks.key?(name), "#{name} should have been retired (Phase C / phase 2 / phase 3)"
    end
  end
end
