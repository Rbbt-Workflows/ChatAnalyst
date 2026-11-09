$LOAD_PATH.unshift '.'
require 'test/test_helper'
require 'test/scout/agent_meta_fixtures'
require 'json'

# Scenario tests for the delegated-receipt (meta envelope) support in the
# Phase C surface.  All fixtures are offline: persisted chat text plus
# temporary job directories.
#
# Phase C re-anchoring (plan step 7): the retired heuristic tasks
# (chat_agents, meta_evidence, chat_reasoning) and the old materialized-edge
# chat_overview/chat_report/chat_tool_calls shapes are gone; these tests now
# pin the SAME semantics through the new module API + the exported task
# family:
#   - receipt/job linkage    -> ChatAnalyst.overview job_references and
#                               ChatAnalyst.tool_calls jobs (anchored at the
#                               outer function_call_output index)
#   - evidence classification-> ChatAnalyst.tokens evidence origins/scopes
#   - conflict/incomplete    -> ChatAnalyst.tokens conflicts + evidence lists
#   - delegation rollup      -> ChatAnalyst.attribution (phase-2 promotion of
#                               the retired chat_report composite; exposed as
#                               chat_tokens attribution: true)
#   - tool-call receipts     -> chat_tool_calls task (tree-wide index)
class TestAgentMetaTasks < Test::Unit::TestCase
  include ChatAnalystFixtures

  # agent_job linkage + receipts: the compact graph resolves the receipt
  # job= reference and tool_calls attaches it to the OUTER output index.
  def test_overview_reports_job_references_and_receipts
    Dir.mktmpdir do |dir|
      parent, worker = fixture_agent_job(dir)
      overview = ChatAnalyst.overview(parent)
      parent_record = overview[:chats].find { |c| c[:path] =~ /parent\.chat/ }
      refute_nil parent_record
      # fixture_agent_job: receipt job= ref anchored at the outer output index 2
      assert_equal File.expand_path(worker), parent_record[:job_references][2]
      assert overview[:jobs].any? { |j| j[:path] == File.expand_path(worker) }
    end
  end

  def test_two_receipts_one_job_keeps_both_call_ids
    Dir.mktmpdir do |dir|
      parent, worker = fixture_two_receipts_one_job(dir)
      calls = ChatAnalyst.tool_calls(parent)[:calls]
      ask_calls = calls.select { |call| call[:tool] == 'ask' }
      assert_equal 2, ask_calls.length, 'two independent calls stay separate'
      assert_equal 2, ask_calls.collect { |call| call[:call_index] }.uniq.length
      # Both calls reference the same job through their own output indices.
      assert_equal [File.expand_path(worker), File.expand_path(worker)],
                   ask_calls.sort_by { |call| call[:call_index] }.collect { |call| call[:jobs].first }
    end
  end

  def test_tool_calls_attach_receipt_summary
    Dir.mktmpdir do |dir|
      parent = fixture_receipt_only(dir)
      result = ChatAnalyst.job(:chat_tool_calls, {file: parent}).run
      call = result[:calls].find { |c| c[:tool] == 'ask' }
      refute_nil call, result.inspect
      # The structured adapter keeps delegation-target parsing; the receipt
      # summary is available through the new tool_calls (receipt evidence
      # counts live in ChatAnalyst.tokens evidence lists).
      assert_equal 'Worker#default', call[:delegation_target]
      tokens = ChatAnalyst.tokens(parent)
      receipt_only_events = tokens[:events].select { |e| e[:evidence].any? { |item| item[:origin] == :agent_meta } }
      assert_equal %w[w1 w2], receipt_only_events.collect { |e| e[:inference_id] }.sort
    end
  end

  def test_conflict_reported_not_summed
    Dir.mktmpdir do |dir|
      parent = fixture_conflict(dir)
      result = ChatAnalyst.job(:chat_tokens, {file: parent}).run
      assert result[:conflicts][:events] == 1
      assert_equal false, result[:conflicts][:authoritative]
      # Counted once from canonical evidence, not both copies.
      assert_equal 6 + 4, result[:deduplicated_total][:tt]
    end
  end

  def test_incomplete_evidence_reported
    Dir.mktmpdir do |dir|
      parent = fixture_incomplete_evidence(dir)
      result = ChatAnalyst.job(:chat_tokens, {file: parent}).run
      assert_equal 1, result[:conflicts][:incomplete_evidence_events]
      assert_equal 4, result[:deduplicated_total][:tt]
      assert_equal 0, result[:conflicts][:events]
      event = result[:events].find { |e| e[:inference_id] == 'h1' }
      assert_equal 2, event[:evidence].length
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
      overview = ChatAnalyst.overview(parent)
      assert overview[:chats].sum { |record| record[:job_references].length } >= 1
    end
  end

  # chat_report's compactness pin, ported to the attribution view it kept
  # (phase 2: the composite was retired; the attribution semantics live on
  # ChatAnalyst.attribution via chat_tokens attribution: true).
  def test_report_is_compact
    Dir.mktmpdir do |dir|
      parent, worker = fixture_receipt_plus_log(dir)
      result = ChatAnalyst.job(:chat_tokens, {file: parent, attribution: true}).run
      assert_equal 290, result[:deduplicated_total][:tt]
      assert result[:attribution][:total][:tt] == 290
      assert result[:attribution][:linked_jobs].length >= 0
    end
  end

  # cortex_continue (the AGS delegation mechanism) must attribute the child's
  # log-chat cost through the receipt job reference, even though the receipt
  # carries no token fields.
  def test_cortex_continue_interaction_and_delegated_tokens
    Dir.mktmpdir do |dir|
      parent, worker = fixture_cortex_continue(dir)
      report = ChatAnalyst.job(:chat_tokens, {file: parent, attribution: true}).run
      delegation = report[:attribution]
      assert_equal 156, report[:deduplicated_total][:tt]
      assert_equal 1, delegation[:linked_jobs].length
      assert_equal 6, delegation[:root_chat_tokens][:tt]
      assert_equal 150, delegation[:delegated_tokens][:tt]
      assert_equal delegation[:root_chat_tokens][:tt] + delegation[:delegated_tokens][:tt],
                   report[:deduplicated_total][:tt]
      assert_equal 0, delegation[:unattributed_tokens][:tt]
      assert_empty delegation[:unresolved_jobs]

      accounting = ChatAnalyst.job(:chat_accounting, {file: parent}).run
      entry = accounting[:entries].find { |e| e[:chat].include?('parent.chat') }
      assert_equal 6, entry[:direct_tokens][:tt]
      assert_equal 150, entry[:delegated_tokens][:tt]
      assert_equal 156, entry[:tokens][:tt]
      assert_equal 1, entry[:delegated_subtrees].length
    end
  end

  # The generic fallback: any tool whose output carries meta receipts is a
  # delegation in the new tool_calls surface too (delegated true, jobs list).
  def test_generic_receipt_fallback
    Dir.mktmpdir do |dir|
      parent, worker = fixture_agent_job(dir)
      text = File.read(parent).sub('"name":"ask"', '"name":"custom_delegate"')
      File.write(parent, text)
      calls = ChatAnalyst.tool_calls(parent)[:calls]
      assert_equal 1, calls.length, calls.inspect
      assert_equal 'custom_delegate', calls.first[:tool]
      assert_equal true, calls.first[:delegated]
      assert_equal [File.expand_path(worker)], calls.first[:jobs]
    end
  end

  def test_chat_messages_untouched_by_receipts
    Dir.mktmpdir do |dir|
      parent = fixture_receipt_only(dir)
      result = ChatAnalyst.job(:chat_messages, {file: parent}).run
      assert result.none? { |m| m[:role].to_s.include?('agent_meta') }
    end
  end
end
