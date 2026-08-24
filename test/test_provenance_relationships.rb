$LOAD_PATH.unshift '.'
require 'test/test_helper'
require 'test/scout/agent_meta_fixtures'
require 'json'

# Fine-grained provenance: import/continue/last relationship extraction and
# per-chat accounting scope.  All fixtures are offline tmpdir chats, so no
# providers and no network are needed.
class TestProvenanceRelationships < Test::Unit::TestCase
  include ChatAnalystFixtures

  # progressive-import chain: base <- middle (imports base twice) <- top
  def import_chain(dir)
    base = write_chat(dir, 'base.chat',
                      "user: base question\n" \
                      "meta: pt=10 ct=5 tt=15 inference_id=b1\n" \
                      "assistant: base answer\n")
    middle = write_chat(dir, 'middle.chat',
                        "import: base.chat\n" \
                        "user: middle question\n" \
                        "meta: pt=20 ct=10 tt=30 inference_id=m1\n" \
                        "assistant: middle answer\n")
    top = write_chat(dir, 'top.chat',
                     "import: middle.chat\n" \
                     "import: base.chat\n" \
                     "user: top question\n" \
                     "meta: pt=1 ct=1 tt=2 inference_id=t1\n" \
                     "assistant: top answer\n")
    [base, middle, top]
  end

  def test_relationships_extracts_import_events_with_positions
    Dir.mktmpdir do |dir|
      _base, _middle, top = import_chain(dir)
      result = ChatAnalyst.job(:provenance_relationships, {file: top}).run
      refs = result[:references]
      assert_equal 2, refs.length
      assert refs.all? { |r| r[:type] == :import }
      assert refs.all? { |r| r[:resolved] }
      assert_equal 1, refs.first[:message_index]
      targets = refs.collect { |r| r[:target] }
      assert targets.any? { |t| t.end_with?('middle.chat') }
      assert targets.any? { |t| t.end_with?('base.chat') }

      summary = result[:targets]
      assert_equal 2, summary.length
      assert summary.all? { |s| s[:resolved] }
    end
  end

  def test_import_closure_is_postorder_and_cycle_safe
    Dir.mktmpdir do |dir|
      base, middle, top = import_chain(dir)
      result = ChatAnalyst.job(:provenance_relationships, {file: top}).run
      closure = result[:import_closure].collect { |path| File.basename(path) }
      assert_equal %w[base.chat middle.chat top.chat], closure

      # explicit cycle: a imports b, b imports a
      a = write_chat(dir, 'a.chat', "import: b.chat\nuser: a\n")
      write_chat(dir, 'b.chat', "import: a.chat\nuser: b\n")
      cyclic = ChatAnalyst.job(:provenance_relationships, {file: a}).run
      assert_equal 2, cyclic[:import_closure].length
    end
  end

  def test_continue_and_last_are_relationships_but_not_import_closure
    Dir.mktmpdir do |dir|
      write_chat(dir, 'history.chat', "user: hi\nassistant: hello\n")
      chat = write_chat(dir, 'chat.chat',
                        "continue: history.chat\n" \
                        "user: q\n" \
                        "last: history.chat\n" \
                        "assistant: a\n")
      result = ChatAnalyst.job(:provenance_relationships, {file: chat}).run
      types = result[:references].collect { |r| r[:type].to_s }.sort
      assert_equal %w[continue last], types
      assert result[:references].all? { |r| r[:resolved] }
      # history.chat is not in the import closure
      refute result[:import_closure].any? { |p| p.end_with?('history.chat') }
    end
  end

  def test_missing_import_is_reported_not_raised
    Dir.mktmpdir do |dir|
      chat = write_chat(dir, 'chat.chat', "import: nope.chat\nuser: q\nassistant: a\n")
      result = ChatAnalyst.job(:provenance_relationships, {file: chat}).run
      ref = result[:references].first
      assert_equal :import, ref[:type]
      refute ref[:resolved]
      assert_equal :missing, ref[:unresolved_reason]
      # own-scope accounting still works on the importing chat
      accounting = ChatAnalyst.job(:chat_accounting, {file: chat}).run
      assert_equal 1, accounting[:entries].length
    end
  end

  def test_own_scope_keeps_imported_chats_separate
    Dir.mktmpdir do |dir|
      base, middle, top = import_chain(dir)
      result = ChatAnalyst.job(:chat_accounting, {file: top, scope: 'own'}).run
      assert_equal :own, result[:scope]
      assert_equal 3, result[:entries].length
      by_name = result[:entries].to_h { |e| [File.basename(e[:chat]), e] }

      own_top = by_name['top.chat']
      assert_equal 2, own_top[:tokens][:tt]
      assert own_top[:imports].any? { |i| i.end_with?('middle.chat') }

      own_middle = by_name['middle.chat']
      assert_equal 30, own_middle[:tokens][:tt]

      own_base = by_name['base.chat']
      assert_equal 15, own_base[:tokens][:tt]

      # no double counting: sum of own totals equals the closure total
      closure = ChatAnalyst.job(:chat_accounting, {file: top, scope: 'closure'}).run
      own_sum = result[:entries].sum { |e| e[:tokens][:tt] }
      assert_equal closure[:entries].first[:tokens][:tt], own_sum
    end
  end

  def test_default_follow_is_all_and_subset_changes_results
    Dir.mktmpdir do |dir|
      _base, _middle, top = import_chain(dir)
      all = ChatAnalyst.job(:chat_overview, {file: top}).run
      subset = ChatAnalyst.job(:chat_overview, {file: top, follow: 'job'}).run
      assert all[:chats].length >= subset[:chats].length
    end
  end

  def test_invalid_follow_raises_parameter_exception
    Dir.mktmpdir do |dir|
      _base, _middle, top = import_chain(dir)
      assert_raise(ParameterException) do
        ChatAnalyst.job(:chat_overview, {file: top, follow: 'nope'}).run
      end
    end
  end

  def test_memo_distinguishes_follow_options
    Dir.mktmpdir do |dir|
      dep = make_job(dir, 'D/load/Default_1')
      log = "user: w\nmeta: pt=3 tt=4 inference_id=w1\nassistant: done\n"
      job = make_job(dir, 'W/ask/Default_w', dependencies: [dep], logs: {'agent.chat' => log})
      chat = write_chat(dir, 'chat.chat',
                        "user: q\n" \
                        "meta: pt=1 tt=2 inference_id=p1\n" \
                        "meta: job=#{job}\n" \
                        "assistant: a\n")
      # default closure walks job + dependency + log relations
      all = ChatAnalyst.job(:chat_overview, {file: chat}).run
      # subset drops dependency traversal: strictly fewer jobs
      subset = ChatAnalyst.job(:chat_overview, {file: chat, follow: 'job,log'}).run
      assert all[:jobs].length > subset[:jobs].length,
             "default=#{all[:jobs].length} subset=#{subset[:jobs].length}"
    end
  end
end
