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
    task = ChatAnalyst.job(:chat_tokens, {file: parent}).run
    assert_equal core[:tt], task[:deduplicated_total][:tt]
    assert_equal core[:pt], task[:deduplicated_total][:pt]
    assert_equal core[:ct], task[:deduplicated_total][:ct]
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
      task = ChatAnalyst.job(:chat_tokens, {file: parent}).run
      # Same inference in receipt and saved log: counted once, two locations.
      w1 = task[:events].find { |event| event[:inference_id] == 'w1' }
      assert_equal 150, w1[:tokens][:tt]
      assert_equal %w[agent_meta chat_meta], w1[:evidence].collect { |e| e[:origin].to_s }.sort
    end
  end

  def test_receipt_only_agrees
    Dir.mktmpdir do |dir|
      parent = fixture_receipt_only(dir)
      core = assert_same_total(parent)
      assert_equal 182, core[:tt]
      task = ChatAnalyst.job(:chat_tokens, {file: parent}).run
      assert_equal 180, task[:receipt_only][:tt]
      # Receipt-only fixture: everything except the parent's own meta p1.
      assert_equal 120, task[:receipt_only][:pt]
      assert_equal 180, task[:receipt_evidence][:tt]
      assert_equal task[:deduplicated_total][:tt] - 2, task[:receipt_only][:tt]
      assert_equal 2, task[:chat_evidence][:tt]
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
