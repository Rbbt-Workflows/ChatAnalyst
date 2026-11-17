$LOAD_PATH.unshift '.'
require 'test/test_helper'
require 'test/scout/agent_meta_fixtures'
require 'json'

# Fine-grained provenance: import/continue/last relationship extraction and
# per-chat accounting scope.  All fixtures are offline tmpdir chats, so no
# providers and no network are needed.
#
# Phase C: `provenance_relationships` was retired as a TASK (zero external
# consumers per the Stage 0 sweep) and its semantics live on as the
# ChatAnalyst.relationships module method (Stage 6), exercised here directly.
# `follow` is DROPPED everywhere (Stage 0 decision recorded in Phase A): the
# three old follow-behaviour tests are replaced by one test pinning that the
# new chat_overview has no follow input and always traverses the whole tree.
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
      result = ChatAnalyst.relationships(top)
      refs = result[:references]
      assert_equal 2, refs.length
      assert refs.all? { |r| r[:type] == :import }
      assert refs.all? { |r| r[:resolved] }
      # ScoutCoder: core Chat.load indexes the first import line at 0 (not 1);
      # document the verified semantics instead of asserting an off-by-one.
      assert_equal 0, refs.first[:message_index]
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
      result = ChatAnalyst.relationships(top)
      closure = result[:import_closure].collect { |path| File.basename(path) }
      assert_equal %w[base.chat middle.chat top.chat], closure

      # explicit cycle: a imports b, b imports a
      a = write_chat(dir, 'a.chat', "import: b.chat\nuser: a\n")
      write_chat(dir, 'b.chat', "import: a.chat\nuser: b\n")
      cyclic = ChatAnalyst.relationships(a)
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
      result = ChatAnalyst.relationships(chat)
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
      result = ChatAnalyst.relationships(chat)
      ref = result[:references].first
      assert_equal :import, ref[:type]
      refute ref[:resolved]
      assert_equal :missing, ref[:unresolved_reason]
      # own-scope accounting still works on the importing chat (phase-3
      # TSV: one row keyed by the chat, imports multi-value cell)
      accounting = ChatAnalyst.job(:chat_accounting, {file: chat}).run
      assert_equal 1, accounting.keys.length
      assert_equal 'own', accounting.scope
      assert_equal 'Chat', accounting.key_field
      row = accounting[accounting.keys.first]
      # unresolved_imports carries the unresolved REFERENCE text; imports
      # carries resolved targets only, so a missing import contributes a
      # null imports cell and its reference text in unresolved_imports.
      assert_equal ['nope.chat'], row['unresolved_imports'].split('|')
      assert_equal '\\N', row['imports']
    end
  end

  def test_own_scope_keeps_imported_chats_separate
    Dir.mktmpdir do |dir|
      base, middle, top = import_chain(dir)
      result = ChatAnalyst.job(:chat_accounting, {file: top, scope: 'own'}).run
      assert_equal 'own', result.scope
      assert_equal 3, result.keys.length
      assert_nil result.options[:cast], 'mixed table: no native cast'
      by_name = result.keys.to_h do |key|
        row = result[key]
        [File.basename(ChatAnalyst::Ids.unescape_path(key)), row]
      end

      own_top = by_name['top.chat']
      assert_equal 2, own_top['tt'].to_i
      assert own_top['imports'].split('|').any? { |i| ChatAnalyst::Ids.unescape_path(i).end_with?('middle.chat') }

      own_middle = by_name['middle.chat']
      assert_equal 30, own_middle['tt'].to_i

      own_base = by_name['base.chat']
      assert_equal 15, own_base['tt'].to_i

      # no double counting: sum of own totals equals the closure total
      closure = ChatAnalyst.job(:chat_accounting, {file: top, scope: 'closure'}).run
      own_sum = result.keys.sum { |key| result[key]['tt'].to_i }
      assert_equal closure[closure.keys.first]['tt'].to_i, own_sum
      assert_equal 'closure', closure.scope
      assert_equal 1, closure.keys.length
    end
  end

  # Replaces the three old `follow` tests (default-is-all, invalid-follow,
  # memo-distinguishes-follow): `follow` no longer exists anywhere in the
  # exported surface; chat_overview always traverses references and direct
  # dependencies, and an unknown task input is rejected by the framework.
  # Phase 3: chat_overview is the per-CHAT TSV table; the JOB universe moved
  # to job_overview (one row per job node).  Both are asserted here.
  def test_follow_is_gone_and_overview_always_traverses
    Dir.mktmpdir do |dir|
      dep = make_job(dir, 'D/load/Default_1')
      log = "user: w\nmeta: pt=3 tt=4 inference_id=w1\nassistant: done\n"
      job = make_job(dir, 'W/ask/Default_w', dependencies: [dep], logs: {'agent.chat' => log})
      chat = write_chat(dir, 'chat.chat',
                        "user: q\n" \
                        "meta: pt=1 tt=2 inference_id=p1\n" \
                        "meta: job=#{job}\n" \
                        "assistant: a\n")
      result = ChatAnalyst.job(:chat_overview, {file: chat}).run
      jobs = ChatAnalyst.job(:job_overview, {file: chat}).run
      job_paths = jobs.keys.collect { |key| ChatAnalyst::Ids.unescape_path(key) }
      assert job_paths.any? { |p| p.end_with?('W/ask/Default_w') }
      assert job_paths.any? { |p| p.end_with?('D/load/Default_1') },
             "direct dependency not traversed: #{job_paths.inspect}"
      assert result.keys.none? { |k| k.end_with?('agent.chat') },
             'log chats are listed per job, never traversed as chats'
      refute ChatAnalyst.tasks[:chat_overview].inputs.collect { |input| input.first.to_s }.include?('follow'),
             'follow input still present on chat_overview'
    end
  end
end
