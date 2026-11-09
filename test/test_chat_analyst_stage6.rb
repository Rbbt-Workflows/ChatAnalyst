# Phase C smoke: tokens / relationships / live over the offline fixtures.
$LOAD_PATH.unshift '.'
require 'test/test_helper'   # workflow + fixtures + clean Scout state
require 'test/scout/n1_malformed_fixture'
require 'test/scout/n2_job_root_fixture'
require 'json'

class TestPhaseCSmoke < Test::Unit::TestCase
  include ChatAnalystFixtures

  def test_overview_and_timeline_do_not_load_token_events_unrequested
    Dir.mktmpdir do |dir|
      root, _child = fixture_job_root_with_delegation(dir)
      calls = []
      Chat.singleton_class.send(:alias_method, :__token_events_without_spy, :provenance_token_events)
      Chat.singleton_class.send(:define_method, :provenance_token_events) do |*args, &block|
        calls << args.length
        __token_events_without_spy(*args, &block)
      end
      begin
        ChatAnalyst.overview(root)
        ChatAnalyst.timeline(root)
        assert_equal [], calls, 'overview/timeline must not load token events'
      ensure
        Chat.singleton_class.send(:alias_method, :provenance_token_events, :__token_events_without_spy)
        Chat.singleton_class.send(:remove_method, :__token_events_without_spy)
      end
    end
  end

  # N1 ghost-job regression: a receipt pointing at a nonexistent job must be
  # reported as a warning by tokens(), never raised (the totals traversals
  # each need their own warnings sink).
  def test_tokens_unresolved_job_reference_is_a_warning_not_a_raise
    Dir.mktmpdir do |dir|
      parent, ghost = fixture_cortex_continue_missing(dir)
      result = ChatAnalyst.tokens(parent)
      assert result[:warnings].any? { |w| w[:reason] == :unresolved_job_reference }
      assert_equal 6, result[:scopes][:deduplicated_total][:tt]
      JSON.generate(result)
    end
  end

  def test_tokens_three_way_reconciliation_reestablished
    Dir.mktmpdir do |dir|
      root, _child = fixture_job_root_with_delegation(dir)
      result = ChatAnalyst.tokens(root)
      core = Chat.provenance_token_totals(root, root_type: :job)

      # The three-way reconciliation of rev3 defect N2, re-established by
      # execution on the NEW API: root(90) + delegated(150) = total(240).
      assert_equal 90, result[:events].select { |e| %w[r1 rr1].include?(e[:inference_id]) }
                                   .sum { |e| e[:tokens][:tt] }
      assert_equal 150, result[:events].find { |e| e[:inference_id] == 'k1' }[:tokens][:tt]
      assert_equal 240, core[:tt]
      assert_equal 240, result[:scopes][:deduplicated_total][:tt]
      assert result[:conflicts][:authoritative]
      assert_equal 0, result[:conflicts][:events]
      # evidence carries absolute source paths, no Step/Path leaks
      serialized = JSON.generate(result)
      refute serialized.include?('Path('), 'Path leak'
      assert_equal 3, result[:events].length

      # receipt-only coverage: every scope from the core totals, coverage
      # semantics (chat_evidence and receipt_evidence overlap; receipt_only
      # is the subset) — receipts 150+30 + own meta 2 = 182 deduplicated.
      parent = fixture_receipt_only(dir)
      scopes = ChatAnalyst.tokens(parent)[:scopes]
      assert_equal 182, scopes[:deduplicated_total][:tt]
      assert_equal 2, scopes[:chat_evidence][:tt]
      assert_equal 180, scopes[:receipt_evidence][:tt]
      assert_equal 180, scopes[:receipt_only][:tt]
    end
  end

  def test_tokens_conflicts_reported_and_authoritative_flag
    Dir.mktmpdir do |dir|
      path = fixture_conflict(dir)
      result = ChatAnalyst.tokens(path)
      assert result[:conflicts][:events] >= 1, 'g1 conflict expected'
      refute result[:conflicts][:authoritative]
      conflicting = result[:events].find { |e| e[:inference_id] == 'g1' }
      assert conflicting[:conflict]
      assert conflicting[:evidence].length == 2
      JSON.generate(result)
    end
  end

  def test_relationships_import_continue_last
    Dir.mktmpdir do |dir|
      base = write_chat(dir, 'base.chat', "user: hi\nassistant: yo\n")
      mid = write_chat(dir, 'middle.chat', "import: base.chat\nuser: q\nassistant: a\n")
      top = write_chat(dir, 'top.chat', "import: middle.chat\nlast: base.chat\ncontinue: missing.chat\nuser: t\nassistant: b\n")
      result = ChatAnalyst.relationships(top)
      types = result[:references].collect { |r| r[:type] }.sort
      assert_equal %i[continue import last], types
      imp = result[:references].find { |r| r[:type] == :import }
      assert imp[:resolved]
      assert_equal File.expand_path(mid), imp[:target]
      assert_equal 0, imp[:message_index]
      cont = result[:references].find { |r| r[:type] == :continue }
      refute cont[:resolved]
      assert_equal :missing, cont[:unresolved_reason]
      # closure post-order: deepest first, root last
      assert_equal [File.expand_path(base), File.expand_path(mid), File.expand_path(top)],
                   result[:import_closure]
    end
  end

  def test_live_reports_entries_and_scanned_without_step_objects
    Dir.mktmpdir do |dir|
      # a running sidecar job (pid = self so it is live); the sidecar stores
      # SHORT paths resolved against Workflow.directory (test-isolated), so
      # the job must live there, not in the fixture dir.
      save = write_chat(dir, 'live.chat', "user: go\n")
      wdir = Workflow.directory.respond_to?(:find) ? Workflow.directory.find.to_s : Workflow.directory.to_s
      job = File.join(wdir, 'W/ask/Default_1')
      FileUtils.mkdir_p(job)
      File.write(job + '.info', {status: 'running', pid: Process.pid}.to_json)
      File.write(save.sub(/\.chat\z/, '') + '.jobs', "W/ask/Default_1\n")
      result = ChatAnalyst.live(save)
      assert_equal true, result[:scanned][:sidecar]
      workload = result[:entries].select { |e| e[:kind] == :workload_context }
      assert workload.any? { |e| e[:reference].to_s.include?('W/ask/Default_1') }
      assert workload.none? { |e| e.key?(:step) }, 'step object leaked'
      assert workload.all? { |e| e[:state] == :running }
      JSON.generate(result) # serializable
    end
  end

  def test_live_absent_sidecar_is_not_an_error
    Dir.mktmpdir do |dir|
      save = write_chat(dir, 'quiet.chat', "user: go\n")
      result = ChatAnalyst.live(save)
      assert_equal false, result[:scanned][:sidecar]
      # an agent save file whose last message is a user message with no
      # assistant round-trip is itself a live agent activity entry.
      activity = result[:entries].select { |e| e[:kind] == :agent_activity }
      assert activity.any? { |e| e[:agent_file] == save && e[:active] == true }
      assert result[:entries].none? { |e| e.key?(:step) }
      JSON.generate(result)
    end
  end
end
