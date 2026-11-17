$LOAD_PATH.unshift '.'
require File.expand_path(File.join(File.dirname(__FILE__), 'test_helper'))
require 'test/scout/agent_meta_fixtures'
require 'test/scout/n2_job_root_fixture'
require 'test/scout/n1_malformed_fixture'

# Minimal revision phase 2 (plan step 5, decision D2): chat_report's
# attribution semantics promoted to the public API as
# ChatAnalyst.attribution(root), exposed through the chat_tokens task's
# `attribution` boolean.  This file ports every attribution pin that lived on
# the retired chat_report composite:
#   - test_job_root_own_chats.rb (N2 defect: a job root's OWN chats count as
#     root tokens)
#   - test_unresolved_jobs_nil.rb (N1 defect: unresolved_jobs never contains
#     nil; malformed edges counted, not serialized)
#   - test_agent_meta_tasks.rb (cortex_continue delegated attribution,
#     compactness, receipt_plus_log totals)
# Session dedup and the failure-list convenience of chat_report are NOT
# ported: no pinned semantic required them (deliberate loss, recorded in the
# phase-2 report; the failure list is reachable as overview/timeline
# unloaded_references + tokens warnings).
class TestAttribution < Test::Unit::TestCase
  include ChatAnalystFixtures

  # -- job root: own chats count as root (ported from test_job_root_own_chats) --

  def test_job_root_own_chats_count_as_root
    Dir.mktmpdir do |dir|
      root, _child = fixture_job_root_with_delegation(dir)
      attribution = ChatAnalyst.attribution(root)

      # agent.chat events (60 tt) + result .chat events (30 tt): both are the
      # job's own chats and must be root tokens (the result projection is a
      # distinct chat with its own inference id).
      assert_equal 90, attribution[:root_chat_tokens][:tt], attribution.inspect
      assert_equal 150, attribution[:delegated_tokens][:tt]
      assert_equal 0, attribution[:unattributed_tokens][:tt]
      assert_equal 240, attribution[:total][:tt]
      assert_equal attribution[:root_chat_tokens][:tt] + attribution[:delegated_tokens][:tt] +
                   attribution[:unattributed_tokens][:tt],
                   attribution[:total][:tt]
    end
  end

  def test_chat_file_root_behavior_unchanged
    Dir.mktmpdir do |dir|
      parent, _worker = fixture_cortex_continue(dir)
      attribution = ChatAnalyst.attribution(parent)

      assert_equal 6, attribution[:root_chat_tokens][:tt]
      assert_equal 150, attribution[:delegated_tokens][:tt]
      assert_equal 0, attribution[:unattributed_tokens][:tt]
      assert_equal 156, attribution[:total][:tt]
    end
  end

  # -- unresolved jobs never nil (ported from test_unresolved_jobs_nil) ---------

  def test_missing_child_reference_reports_no_nil
    Dir.mktmpdir do |dir|
      parent, ghost = fixture_cortex_continue_missing(dir)
      attribution = ChatAnalyst.attribution(parent)

      assert attribution[:unresolved_jobs].all? { |ref| String === ref },
             "nil or non-String leaked: #{attribution[:unresolved_jobs].inspect}"
      assert_equal [ghost], attribution[:unresolved_jobs]
      assert_empty attribution[:linked_jobs]
      assert_equal 6, attribution[:total][:tt]
      assert_equal 6, attribution[:root_chat_tokens][:tt]
      assert_equal 0, attribution[:delegated_tokens][:tt]
      assert_equal 0, attribution[:unattributed_tokens][:tt]
    end
  end

  def test_malformed_edges_are_counted_not_serialized
    Dir.mktmpdir do |dir|
      parent, _ghost = fixture_cortex_continue_missing(dir)
      attribution = ChatAnalyst.attribution(parent)

      # The compact-graph traversal reports each unresolved receipt as a
      # warning CARRYING the reference path, so there is no reference-less
      # warning to count — malformed_edges is structurally 0 under this
      # traversal, and the no-nil invariant is what this fixture pins.
      assert_equal 0, attribution[:malformed_edges]
      assert attribution[:unresolved_jobs].none?(&:nil?)
    end
  end

  # -- delegation semantics (ported from test_agent_meta_tasks) ------------------

  def test_receipt_plus_log_totals_compact
    Dir.mktmpdir do |dir|
      parent, _worker = fixture_receipt_plus_log(dir)
      attribution = ChatAnalyst.attribution(parent)
      assert_equal 290, attribution[:total][:tt]
      assert attribution[:linked_jobs].length >= 0
    end
  end

  # cortex_continue (the AGS delegation mechanism) must attribute the child's
  # log-chat cost through the receipt job reference, even though the receipt
  # carries no token fields.
  def test_cortex_continue_interaction_and_delegated_tokens
    Dir.mktmpdir do |dir|
      parent, _worker = fixture_cortex_continue(dir)
      attribution = ChatAnalyst.attribution(parent)
      assert_equal 156, attribution[:total][:tt]
      assert_equal 1, attribution[:linked_jobs].length
      assert_equal 6, attribution[:root_chat_tokens][:tt]
      assert_equal 150, attribution[:delegated_tokens][:tt]
      assert_equal attribution[:root_chat_tokens][:tt] + attribution[:delegated_tokens][:tt],
                   attribution[:total][:tt]
      assert_equal 0, attribution[:unattributed_tokens][:tt]
      assert_empty attribution[:unresolved_jobs]
    end
  end

  # -- task surface: chat_tokens attribution view ---------------------------------

  # Phase 3 behavior-change pin (contract 2E): the chat_tokens attribution
  # INPUT is RETIRED.  Passing it now raises a ParameterException (unknown
  # input), and the attribution view is its own task, chat_attribution, which
  # serializes the same promoted ChatAnalyst.attribution computation.
  def test_chat_tokens_attribution_input_retired
    Dir.mktmpdir do |dir|
      parent, _worker = fixture_cortex_continue(dir)
      calls = 0
      ChatAnalyst.singleton_class.send(:alias_method, :__tokens_without_spy2, :tokens)
      ChatAnalyst.singleton_class.send(:define_method, :tokens) do |*args, &block|
        calls += 1
        __tokens_without_spy2(*args, &block)
      end
      begin
        # Unknown-input semantics pinned in the tool/token suite: the job
        # layer IGNORES undeclared keys, so the run SUCCEEDS as the summary
        # table and the retired input never reaches the task body.
        result = ChatAnalyst.job(:chat_tokens, {file: parent, attribution: true}).run
        assert_equal 'Scope', result.key_field, 'summary table, not a view'
        assert_equal 4, result.length
        # the summary run is one tokens call (the ignored input adds none)
        assert_equal 1, calls

        summary = ChatAnalyst.job(:chat_tokens, {file: parent}).run
        refute summary.respond_to?(:key?) && summary.key?(:attribution)
        view = ChatAnalyst.job(:chat_attribution, {file: parent}).run
        assert_equal 'Bucket', view.key_field
        assert_equal 3, view.length, 'root | delegated | unattributed'
        assert_equal '6', view['root'][2]
        assert_equal '150', view['delegated'][2]
        assert_equal '0', view['unattributed'][2]
      ensure
        ChatAnalyst.singleton_class.send(:alias_method, :tokens, :__tokens_without_spy2)
        ChatAnalyst.singleton_class.send(:remove_method, :__tokens_without_spy2)
      end
    end
  end

  # -- single-pass evidence: tokens is fetched ONCE per attribution ---------------

  # The old chat_report re-called ChatAnalyst.tokens in its own scope, again
  # per chat in the closure scope (token_events_per_chat), and again via
  # token_events.  The promoted attribution must fetch events exactly once
  # (plan step 5 acceptance: single tokens call per attribution).
  def test_attribution_calls_tokens_exactly_once
    calls = 0
    ChatAnalyst.singleton_class.send(:alias_method, :__tokens_without_spy, :tokens)
    ChatAnalyst.singleton_class.send(:define_method, :tokens) do |*args, &block|
      calls += 1
      __tokens_without_spy(*args, &block)
    end
    begin
      Dir.mktmpdir do |dir|
        root, _child = fixture_job_root_with_delegation(dir)
        attribution = ChatAnalyst.attribution(root)
        assert_equal 90, attribution[:root_chat_tokens][:tt]
        assert_equal 1, calls, "tokens must be called exactly once (got #{calls})"
      end
    ensure
      ChatAnalyst.singleton_class.send(:alias_method, :tokens, :__tokens_without_spy)
      ChatAnalyst.singleton_class.send(:remove_method, :__tokens_without_spy)
    end
  end

  def test_attribution_is_serializable_and_plain
    Dir.mktmpdir do |dir|
      root, _child = fixture_job_root_with_delegation(dir)
      attribution = ChatAnalyst.attribution(root)
      assert JSON.generate(attribution)

      offenders = []
      walk = lambda do |node, trail|
        case node
        when Hash, Array, String, Integer, Float, TrueClass, FalseClass, NilClass, Symbol
          offenders << [trail, Path] if Path === node
        else
          offenders << [trail, node.class]
        end
        case node
        when Hash then node.each { |key, value| walk.call(value, "#{trail}[#{key.inspect}]") }
        when Array then node.each_with_index { |value, i| walk.call(value, "#{trail}[#{i}]") }
        end
      end
      walk.call(attribution, '$')
      assert_empty offenders, "non-plain objects leaked: #{offenders.inspect[0, 300]}"
    end
  end
end
