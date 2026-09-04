$LOAD_PATH.unshift '.'
require File.expand_path(File.join(File.dirname(__FILE__), 'test_helper'))
require 'test/scout/agent_meta_fixtures'
require 'test/scout/n2_job_root_fixture'

# rev3 step 4 (defect N2): on a job root, root_chat_tokens must cover the
# job's own chats (agent chat + result chat) per the README, so
# unattributed_tokens shrinks and root + delegated + unattributed reconciles
# with deduplicated_total.  On the step-3 baseline the Hash#select pair bug
# leaves root_chat_tokens at 0 and dumps the whole total into unattributed
# (see tmp/rev3/step4/trace_n2_precise.rb: events matching root_chat_paths: 0).
class TestJobRootOwnChatTokens < Test::Unit::TestCase
  include ChatAnalystFixtures

  def test_job_root_own_chats_count_as_root
    Dir.mktmpdir do |dir|
      root, _child = fixture_job_root_with_delegation(dir)
      report = ChatAnalyst.job(:chat_report, {file: root}).run
      delegation = report[:delegation]

      # agent.chat events (60 tt) + result .chat events (30 tt): both are the
      # job's own chats and must be root tokens (the result projection is a
      # distinct chat with its own inference id).
      assert_equal 90, delegation[:root_chat_tokens][:tt],
                   delegation.inspect
      assert_equal 150, delegation[:delegated_tokens][:tt]
      assert_equal 0, delegation[:unattributed_tokens][:tt]
      assert_equal 240, report[:tokens][:deduplicated_total][:tt]
      assert_equal delegation[:root_chat_tokens][:tt] + delegation[:delegated_tokens][:tt] +
                   delegation[:unattributed_tokens][:tt],
                   report[:tokens][:deduplicated_total][:tt]
    end
  end

  def test_chat_file_root_behavior_unchanged
    Dir.mktmpdir do |dir|
      parent, _worker = fixture_cortex_continue(dir)
      report = ChatAnalyst.job(:chat_report, {file: parent}).run
      delegation = report[:delegation]

      assert_equal 6, delegation[:root_chat_tokens][:tt]
      assert_equal 150, delegation[:delegated_tokens][:tt]
      assert_equal 0, delegation[:unattributed_tokens][:tt]
      assert_equal 156, report[:tokens][:deduplicated_total][:tt]
    end
  end
end
