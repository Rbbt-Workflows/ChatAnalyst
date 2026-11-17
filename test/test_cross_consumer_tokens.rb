$LOAD_PATH.unshift '.'
require 'test/test_helper'
require 'test/scout/agent_meta_fixtures'
require 'json'
require 'open3'
require 'rbconfig'

# Cross-consumer consistency: the Scout-AI core collector, the
# `scout-ai llm prov --evidence` CLI, and the ChatAnalyst chat_tokens task
# must report the same deduplicated total for the same fixture.
class TestCrossConsumerTokens < Test::Unit::TestCase
  include ChatAnalystFixtures

  # The first line of `--evidence` output is the root chat total, which is the
  # deduplicated aggregate (same number the tree mode shows for the root).
  def parse_root_total(output)
    # ScoutCoder: with the Option-B rendering now in scout-ai, --evidence prints
    # per-event 'total=N' lines in the direct-events section BEFORE any aggregate;
    # the authoritative root figure is the 'root deduplicated_total=N' footer, so
    # it must be read first (the old first-'chat'-line heuristic now returns the
    # first per-event total instead of the session total).
    # (the marker may carry ANSI colour codes between 'root' and the value,
    # so match the unique deduplicated_total= token directly)
    footer = output[/deduplicated_total=(\d+)/, 1]
    return footer if footer
    line = output.lines.find { |l| l.include?('chat') && l =~ /total=/ }
    line && line[/total=(\d+)/, 1]
  end

# ScoutCoder: test-unit (bundled with Scout workflows) skips tests with
# `omit "reason"`, not RSpec/minitest-style `skip` — an undefined `skip` raises
# NoMethodError and turns the whole test into an error instead of an omission.

  def prov_evidence(path)
    scout_bin = ENV['SCOUT_AI_BIN'] || File.expand_path('~/git/scout-ai/bin/scout-ai')
    omit "#{scout_bin} not available" unless File.executable?(scout_bin)
    out, _err, _status = Open3.capture3({'SCOUT_LOG' => '0'},
                                        RbConfig.ruby, scout_bin,
                                        'llm', 'prov', '--evidence', path)
    out
  end

  def assert_same_total(parent)
    core = Chat.provenance_token_totals(parent)
    # Phase 3 TSV surface: chat_tokens is the 4-scope summary table; the
    # cast table returns native Integers per scope row.
    job = ChatAnalyst.job(:chat_tokens, {file: parent})
    task = job.run
    # in-process build_table rows are Strings; the :to_i cast yields native
    # Integers when the persisted TSV is reopened.
    assert_equal core[:tt].to_s, task['deduplicated_total'][2]
    reopened = TSV.open(job.path)
    assert_equal core[:tt], reopened['deduplicated_total']['tt']
    assert_equal core[:pt], reopened['deduplicated_total']['pt']
    assert_equal core[:ct], reopened['deduplicated_total']['ct']
    assert Integer === reopened['deduplicated_total'].first, 'native cast'
    cli = prov_evidence(parent)
    assert_match /total=/, cli
    assert_equal core[:tt].to_s, parse_root_total(cli), cli.lines.first
    core
  end

  def test_receipt_plus_saved_log_agrees
    Dir.mktmpdir do |dir|
      parent, _worker = fixture_receipt_plus_log(dir)
      core = assert_same_total(parent)
      assert_equal 290, core[:tt]
      # Same inference in receipt and saved log: counted once, two locations
      # (the event list moved to chat_token_events, evidence to
      # chat_token_evidence - both keyed by the TokenEvent id).
      events = ChatAnalyst.job(:chat_token_events, {file: parent}).run
      w1_key = events.keys.find { |key| key.end_with?('#w1') }
      refute_nil w1_key, events.keys.inspect
      assert_equal 150, Integer(events[w1_key][2]), 'tt column'
      evidence = ChatAnalyst.job(:chat_token_evidence, {file: parent}).run
      w1_rows = evidence.keys.select { |key| key[0...key.rindex('#')] == w1_key }
      assert_equal %w[agent_meta chat_meta], w1_rows.collect { |key|
        evidence[key][0]
      }.sort
    end
  end

  def test_receipt_only_agrees
    Dir.mktmpdir do |dir|
      parent = fixture_receipt_only(dir)
      core = assert_same_total(parent)
      assert_equal 182, core[:tt]
      task = ChatAnalyst.job(:chat_tokens, {file: parent}).run
      assert_equal '180', task['receipt_only'][2]
      # Receipt-only fixture: everything except the parent's own meta p1.
      assert_equal '120', task['receipt_only'][0]
      assert_equal '180', task['receipt_evidence'][2]
      assert_equal '180', task['receipt_only'][2]
      assert_equal '2', task['chat_evidence'][2]
    end
  end

  def test_agent_job_scenario_agrees
    Dir.mktmpdir do |dir|
      parent, _worker = fixture_agent_job(dir)
      core = assert_same_total(parent)
      assert_equal 182, core[:tt]
    end
  end
end
