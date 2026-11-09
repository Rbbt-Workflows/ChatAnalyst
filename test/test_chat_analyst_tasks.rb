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
      assert_equal parent, result[:root][:path]
      assert result[:jobs].any? { |job| job[:path] == worker }
      JSON.parse(result.to_json) # plain serializable data only
    end
  end

  def test_chat_timeline_task_returns_bouts
    Dir.mktmpdir do |dir|
      parent, _worker = parent_with_job(dir)
      result = ChatAnalyst.job(:chat_timeline, {file: parent}).run
      assert result[:bouts].any?
      assert result[:summary][:chats] >= 1
    end
  end

  def test_chat_messages_task_indexes_one_chat
    Dir.mktmpdir do |dir|
      parent, _worker = parent_with_job(dir)
      result = ChatAnalyst.job(:chat_messages, {file: parent}).run
      assert result.length >= 4
      assert result.all? { |message| message.key?(:index) }
    end
  end

  def test_chat_range_task_returns_inclusive_messages
    Dir.mktmpdir do |dir|
      parent, _worker = parent_with_job(dir)
      result = ChatAnalyst.job(:chat_range, {file: parent, first: 0, last: 1}).run
      assert_equal 0, result[:first]
      assert_equal 1, result[:last]
      assert_equal 2, result[:messages].length
    end
  end

  def test_chat_tool_calls_task_filters_by_range
    Dir.mktmpdir do |dir|
      parent, _worker = parent_with_job(dir)
      result = ChatAnalyst.job(:chat_tool_calls, {file: parent}).run
      assert result[:calls].length >= 1
      assert result[:calls].first[:tool]
    end
  end

  def test_chat_tokens_task_reports_scopes
    Dir.mktmpdir do |dir|
      parent, _worker = parent_with_job(dir)
      result = ChatAnalyst.job(:chat_tokens, {file: parent}).run
      assert result[:scopes][:deduplicated_total][:tt] >= 151
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
      assert result.key?(:total)
      assert result.key?(:calls)
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
       message_index message_content extract_chat_range chat_report].each do |name|
      refute ChatAnalyst.tasks.key?(name), "#{name} should have been retired (Phase C / phase 2)"
    end
  end
end
