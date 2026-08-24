$LOAD_PATH.unshift '.'
require 'test/test_helper'
require 'test/scout/agent_meta_fixtures'
require 'json'

# Scenario tests for the delegated-receipt (agent_meta) support in
# ChatAnalyst tasks.  All fixtures are offline: persisted chat text plus
# temporary job directories.
class TestAgentMetaTasks < Test::Unit::TestCase
  include ChatAnalystFixtures

  def test_overview_reports_agent_job_edges_and_receipts
    Dir.mktmpdir do |dir|
      parent, worker = fixture_agent_job(dir)
      result = ChatAnalyst.job(:chat_overview, {file: parent}).run
      agent_edges = result[:edges].select { |edge| edge[:relation].to_s == 'agent_job' }
      assert_equal 1, agent_edges.length
      detail = agent_edges.first[:detail]
      assert_equal 'a1', detail[:call_id]
      assert_equal 'ask', detail[:tool_name]
      assert detail[:evidence_address].include?(:agent_meta) ||
             detail[:evidence_address].include?('agent_meta')
      chat = result[:chats].find { |c| c[:path] =~ /parent\.chat/ }
      assert chat[:receipt_records] >= 1
      assert result[:totals][:agent_job_edges] >= 1
    end
  end

  def test_tool_calls_attach_receipt_summary
    Dir.mktmpdir do |dir|
      parent, _worker = fixture_receipt_only(dir)
      result = ChatAnalyst.job(:chat_tool_calls, {file: parent}).run
      call = result[:calls].find { |c| c[:tool] == 'ask' }
      refute_nil call, result.inspect
      receipt = call[:agent_meta]
      assert_equal 2, receipt[:receipt_meta_count]
      assert_equal %w[w1 w2], receipt[:direct_event_ids].sort
      assert_equal %w[w1 w2], receipt[:receipt_only_event_ids].sort
      assert_equal 180, receipt[:direct_token_total][:tt]
      assert_equal 0, receipt[:unresolved_receipts]
    end
  end

  def test_agents_classifies_evidence
    Dir.mktmpdir do |dir|
      parent, worker = fixture_receipt_plus_log(dir)
      result = ChatAnalyst.job(:chat_agents, {file: parent}).run
      interaction = result[:interactions].first
      refute_nil interaction, result.inspect
      assert_equal 'Worker', interaction[:target_agent]
      assert_equal %w[w1 w2], interaction[:receipt][:event_ids].sort
      assert interaction[:receipt][:token_total][:tt] > 0
      assert_equal :both, interaction[:child_evidence]
    end
  end

  def test_agents_receipt_only_classification
    Dir.mktmpdir do |dir|
      parent = fixture_receipt_only(dir)
      result = ChatAnalyst.job(:chat_agents, {file: parent}).run
      interaction = result[:interactions].first
      assert_equal :receipt_only, interaction[:child_evidence]
    end
  end

  def test_meta_evidence_includes_both_origins
    Dir.mktmpdir do |dir|
      parent, _worker = fixture_receipt_only(dir)
      result = ChatAnalyst.job(:meta_evidence, {file: parent}).run
      items = result[:records]
      origins = items.collect { |item| item[:origin].to_s }.uniq
      assert origins.include?('chat_meta')
      assert origins.include?('agent_meta')
      receipt = items.find { |item| item[:origin].to_s == 'agent_meta' }
      assert receipt[:inference_id]
      assert receipt[:call_id]
      assert receipt[:evidence_address]
    end
  end

  def test_reasoning_covers_receipt_and_chat
    Dir.mktmpdir do |dir|
      parent = write_chat(dir, 'parent.chat',
                          receipt_chat_text({'a1' => [meta_receipt('pt=10 tt=10 inference_id=w1 reas=worker thought hard'),
                                                      meta_receipt('pt=5 tt=5 inference_id=w2')]},
                                            extra: ['meta: pt=1 ct=1 tt=2 inference_id=p1 reas=parent thought']))
      result = ChatAnalyst.job(:chat_reasoning, {file: parent}).run
      assert_equal 2, result[:total]
      items = result[:items]
      origins = items.collect { |item| item[:origin].to_s }.sort
      assert_equal %w[agent_meta chat_meta], origins
      receipt_item = items.find { |item| item[:origin].to_s == 'agent_meta' }
      assert_equal 'a1', receipt_item[:call_id]
      assert_equal 'ask', receipt_item[:tool_name]
      assert receipt_item[:address].include?('agent_meta')
      assert_equal true, receipt_item[:receipt_only]
    end
  end

  def test_conflict_reported_not_summed
    Dir.mktmpdir do |dir|
      parent = fixture_conflict(dir)
      result = ChatAnalyst.job(:chat_tokens, {file: parent}).run
      assert result[:conflicts].length == 1
      # Counted once from canonical evidence, not both copies.
      assert_equal 6 + 4, result[:deduplicated_total][:tt]
    end
  end

  def test_incomplete_evidence_reported
    Dir.mktmpdir do |dir|
      parent = fixture_incomplete_evidence(dir)
      result = ChatAnalyst.job(:chat_tokens, {file: parent}).run
      assert_equal 1, result[:incomplete_evidence].length
      assert_equal 4, result[:deduplicated_total][:tt]
      assert_equal 0, result[:conflicts].length
      event = result[:events].find { |e| e[:inference_id] == 'h1' }
      assert_equal 2, event[:evidence].length
    end
  end

  def test_two_receipts_one_job_keeps_both_call_ids
    Dir.mktmpdir do |dir|
      parent, worker = fixture_two_receipts_one_job(dir)
      overview = ChatAnalyst.job(:chat_overview, {file: parent}).run
      agent_edges = overview[:edges].select { |edge| edge[:relation].to_s == 'agent_job' }
      assert_equal 2, agent_edges.length
      assert_equal %w[a1 a2], agent_edges.collect { |e| e[:detail][:call_id] }.sort
      agents = ChatAnalyst.job(:chat_agents, {file: parent}).run
      assert_equal %w[a1 a2], agents[:interactions].collect { |i| i[:call_id] }.sort
    end
  end

  # Plan fixture D: nested receipt chain terminates and every direct event id
  # is counted exactly once across both delegation paths.
  def test_nested_chain_counts_every_event_once
    Dir.mktmpdir do |dir|
      parent, worker = fixture_nested_chain(dir)
      core = Chat.provenance_token_totals(parent)
      assert_equal 157, core[:tt]
      task = ChatAnalyst.job(:chat_tokens, {file: parent}).run
      assert_equal core[:tt], task[:deduplicated_total][:tt]
      assert_equal 5, task[:receipt_only][:tt]
      overview = ChatAnalyst.job(:chat_overview, {file: parent}).run
      assert overview[:totals][:agent_job_edges] >= 1
      agents = ChatAnalyst.job(:chat_agents, {file: parent}).run
      critic = agents[:interactions].find { |i| i[:target_agent] == 'Critic' }
      assert_equal :receipt_only, critic[:child_evidence]
      worker_interaction = agents[:interactions].find { |i| i[:target_agent] == 'Worker' }
      assert_equal :log_only, worker_interaction[:child_evidence]
    end
  end

  def test_report_is_compact
    Dir.mktmpdir do |dir|
      parent, worker = fixture_receipt_plus_log(dir)
      result = ChatAnalyst.job(:chat_report, {file: parent}).run
      assert_equal 290, result[:tokens][:deduplicated_total][:tt]
      assert result[:agent_job_edges] >= 0
      assert result[:receipt_summaries].length <= 3
    end
  end

  def test_message_index_untouched_by_receipts
    Dir.mktmpdir do |dir|
      parent = fixture_receipt_only(dir)
      result = ChatAnalyst.job(:message_index, {file: parent}).run
      messages = result
      assert messages.none? { |m| m[:address].to_s.include?('agent_meta') }
    end
  end
end
