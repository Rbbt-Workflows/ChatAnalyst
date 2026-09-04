$LOAD_PATH.unshift '.'
require File.expand_path(File.join(File.dirname(__FILE__), 'test_helper'))
require 'test/scout/agent_meta_fixtures'
require 'test/scout/n1_malformed_fixture'

# rev3 step 3 (defect N1): unresolved_jobs must never contain nil.  The
# reference-less duplicate warning produced by the traversal-stage on_error
# for an agent_job edge (reference Hash without a String job path) must not
# leak a null into delegation.unresolved_jobs; on the committed baseline the
# same fixtures yield [ghost, nil] (demonstrated in
# tmp/rev3/step3/repro_nil_fixture.rb and the baseline-runner logs).
class TestUnresolvedJobsNeverNil < Test::Unit::TestCase
  include ChatAnalystFixtures

  def test_missing_child_reference_reports_no_nil
    Dir.mktmpdir do |dir|
      parent, ghost = fixture_cortex_continue_missing(dir)
      report = ChatAnalyst.job(:chat_report, {file: parent}).run
      delegation = report[:delegation]

      assert delegation[:unresolved_jobs].all? { |ref| String === ref },
             "nil or non-String leaked: #{delegation[:unresolved_jobs].inspect}"
      assert_equal [ghost], delegation[:unresolved_jobs]
      assert_equal 0, delegation[:linked_jobs]
      assert_equal 6, report[:tokens][:deduplicated_total][:tt]
      assert_equal 6, delegation[:root_chat_tokens][:tt]
      assert_equal 0, delegation[:delegated_tokens][:tt]
      assert_equal 0, delegation[:unattributed_tokens][:tt]
    end
  end

  def test_malformed_edges_are_counted_not_serialized
    Dir.mktmpdir do |dir|
      parent, _ghost = fixture_cortex_continue_missing(dir)
      report = ChatAnalyst.job(:chat_report, {file: parent}).run
      delegation = report[:delegation]

      # The traversal-stage duplicate fires once per unresolved agent_job
      # edge (1 here); it must be surfaced as an additive count, never as a
      # null list entry.
      assert_equal 1, delegation[:malformed_edges]
      assert delegation[:unresolved_jobs].none?(&:nil?)
    end
  end

  def test_agents_task_also_reports_no_nil
    Dir.mktmpdir do |dir|
      parent, _ghost = fixture_cortex_continue_missing(dir)
      agents = ChatAnalyst.job(:chat_agents, {file: parent}).run
      interaction = agents[:interactions].first
      edges = interaction[:agent_job_edges]
      assert edges.all? { |e| e[:job].nil? || String === e[:job] },
             "non-String job on agent_job edge: #{edges.inspect}"
    end
  end
end
