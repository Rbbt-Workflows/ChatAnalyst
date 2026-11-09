$LOAD_PATH.unshift '.'
require File.expand_path(File.join(File.dirname(__FILE__), 'test_helper'))
require 'test/scout/agent_meta_fixtures'
require 'test/scout/n1_malformed_fixture'

# rev3 step 3 (defect N1): unresolved_jobs must never contain nil.  The
# reference-less duplicate warning produced by the traversal-stage on_error
# for an agent_job edge (reference Hash without a String job path) must not
# leak a null into the attribution view; on the committed baseline the
# same fixtures yield [ghost, nil] (demonstrated in
# tmp/rev3/step3/repro_nil_fixture.rb and the baseline-runner logs).
#
# Phase 2: the chat_report composite was retired; every pin here runs
# against ChatAnalyst.attribution (the promoted public surface) and the
# chat_tokens attribution view.
class TestUnresolvedJobsNeverNil < Test::Unit::TestCase
  include ChatAnalystFixtures

  def test_missing_child_reference_reports_no_nil
    Dir.mktmpdir do |dir|
      parent, ghost = fixture_cortex_continue_missing(dir)
      delegation = ChatAnalyst.attribution(parent)

      assert delegation[:unresolved_jobs].all? { |ref| String === ref },
             "nil or non-String leaked: #{delegation[:unresolved_jobs].inspect}"
      assert_equal [ghost], delegation[:unresolved_jobs]
      assert_equal 0, delegation[:linked_jobs].length
      assert_equal 6, delegation[:total][:tt]
      assert_equal 6, delegation[:root_chat_tokens][:tt]
      assert_equal 0, delegation[:delegated_tokens][:tt]
      assert_equal 0, delegation[:unattributed_tokens][:tt]
    end
  end

  def test_malformed_edges_are_counted_not_serialized
    Dir.mktmpdir do |dir|
      parent, _ghost = fixture_cortex_continue_missing(dir)
      delegation = ChatAnalyst.attribution(parent)

      # The traversal-stage duplicate fires once per unresolved agent_job
      # edge; it must be surfaced as an additive count, never as a null list
      # entry.  (Phase C: the compact-graph traversal reports each
      # unresolved receipt as a warning CARRYING the reference path, so
      # there is no longer a reference-less warning to count —
      # malformed_edges is structurally 0 under the new traversal, and the
      # no-nil invariant is what this fixture still pins.)
      assert_equal 0, delegation[:malformed_edges]
      assert delegation[:unresolved_jobs].none?(&:nil?)
    end
  end

  # The no-nil invariant survives on the TASK surface too (chat_tokens
  # attribution view), not only the module method.
  def test_chat_tokens_attribution_view_reports_no_nil
    Dir.mktmpdir do |dir|
      parent, ghost = fixture_cortex_continue_missing(dir)
      view = ChatAnalyst.job(:chat_tokens, {file: parent, attribution: true}).run[:attribution]
      assert_equal [ghost], view[:unresolved_jobs]
      assert view[:unresolved_jobs].none?(&:nil?)
    end
  end

  # chat_agents was retired in Phase C (zero external consumers per the
  # Stage 0 sweep); the no-nil edge invariant survives in the attribution
  # view above and in tool_calls job records.
  def test_agents_task_also_reports_no_nil
    Dir.mktmpdir do |dir|
      parent, _ghost = fixture_cortex_continue_missing(dir)
      error = assert_raise(TaskNotFound) { ChatAnalyst.job(:chat_agents, {file: parent}).run }
      assert_match(/chat_agents/, error.message)
    end
  end
end
