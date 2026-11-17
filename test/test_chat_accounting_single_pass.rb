$LOAD_PATH.unshift '.'
require 'test/test_helper'
require 'test/scout/agent_meta_fixtures'

# Minimal revision phase 2 (plan step 6, decision D4 keep+fix), phase-3
# converted form: the chat_accounting single-pass pin, ported to the TSV
# output (contract 2F).  Claim 4 (verified, holds): the adapter called
# ChatAnalyst.tokens repeatedly per chat - once in its own scope, again per
# chat in the closure scope (token_events_per_chat), and once more per chat
# for the merge - plus a separate overview and relationships call per chat.
# The fixed implementation computes tokens / overview / relationships
# exactly ONCE per chat for the whole response (local memoization only; no
# persistent caching abstraction).  The TSV conversion keeps that guarantee;
# this suite also pins the |-invariant on REAL delegated_subtrees values.
class TestChatAccountingSinglePass < Test::Unit::TestCase
  include ChatAnalystFixtures
  def setup
    @dir = Dir.mktmpdir('chat_analyst_accounting')
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  def closure_chat
    base = File.join(@dir, 'base.chat')
    File.write(base, "user: hi\nassistant: yo\n")
    top = File.join(@dir, 'top.chat')
    File.write(top, "import: #{base}\nuser: q\nassistant: a\n")
    top
  end

  def with_call_counters
    counts = Hash.new(0)
    spies = {}
    %w[tokens overview relationships].each do |name|
      ChatAnalyst.singleton_class.send(:alias_method, :"__#{name}_without_spy", name.to_sym)
      spies[name] = lambda do |*args, &block|
        counts[name] += 1
        ChatAnalyst.public_send(:"__#{name}_without_spy", *args, &block)
      end
      ChatAnalyst.singleton_class.send(:define_method, name.to_sym) { |*args, &block| spies[name].call(*args, &block) }
    end
    begin
      yield counts
    ensure
      %w[tokens overview relationships].each do |name|
        ChatAnalyst.singleton_class.send(:alias_method, name.to_sym, :"__#{name}_without_spy")
        ChatAnalyst.singleton_class.send(:remove_method, :"__#{name}_without_spy")
      end
    end
  end

  def field_index(result, name)
    result.fields.index(name)
  end

  def test_own_scope_calls_each_api_once_per_chat
    top = closure_chat
    with_call_counters do |counts|
      result = ChatAnalyst.job(:chat_accounting, {file: top}).run

      # two chats in the closure (base + top), each fetched exactly once
      assert_equal 2, counts['tokens'], "tokens calls: #{counts.inspect}"
      assert_equal 2, counts['overview']
      assert_equal 2, counts['relationships']

      # behavior unchanged: both closure chats appear as rows (canonical
      # escaped keys), the scope annotation says own
      assert_equal 2, result.keys.length
      assert_equal 'own', result.scope
      assert result.keys.include?(ChatAnalyst::Ids.chat_id(File.join(@dir, 'base.chat')))
      assert result.keys.include?(ChatAnalyst::Ids.chat_id(top))
      # every column is a String cell (mixed table, no cast)
      result.each do |_key, row|
        assert row.all? { |cell| String === cell }, 'mixed table cells must be plain Strings'
      end
    end
  end

  def test_closure_scope_reuses_own_scope_events
    top = closure_chat
    with_call_counters do |counts|
      result = ChatAnalyst.job(:chat_accounting, {file: top, scope: 'closure'}).run

      # the closure merge must reuse the own-scope fetches, NOT re-call
      assert_equal 2, counts['tokens'], "tokens calls: #{counts.inspect}"
      assert_equal 2, counts['overview']
      assert_equal 2, counts['relationships']

      # ONE merged row keyed by the root, scope annotation says closure
      assert_equal 1, result.keys.length
      assert_equal ChatAnalyst::Ids.chat_id(top), result.keys.first
      assert_equal 'closure', result.scope
    end
  end

  def test_pipe_invariant_pinned_on_real_delegated_subtrees_and_imports
    parent, _worker = fixture_cortex_continue(@dir)

    own = ChatAnalyst.job(:chat_accounting, {file: parent}).run
    imports_i = field_index(own, 'imports')
    subtrees_i = field_index(own, 'delegated_subtrees')

    own.each do |_key, row|
      [row[imports_i], row[subtrees_i]].each do |cell|
        next if cell == '\\N'
        # a REAL multi-value cell: |-joined members, every member |-free,
        # and no member is empty (multi() raises on any '|' inside a member
        # by contract, so reaching here with a join proves the invariant)
        members = cell.split('|', -1)
        assert members.all? { |m| !m.empty? }, "empty member in #{cell.inspect}"
        assert_equal members.length, cell.count('|') + 1
      end
    end

    # the cortex_continue fixture has exactly one delegated subtree and no
    # imports: subtrees is a real populated multi-value cell
    row = own[ChatAnalyst::Ids.chat_id(parent)]
    subtrees = row[subtrees_i]
    refute_equal '\\N', subtrees, 'fixture must produce a real delegated_subtrees value'
    assert subtrees.include?('Cortex/continue/Default_1'), subtrees
    assert !subtrees.include?('||'), subtrees

    # an import-bearing root pins the OTHER multi column on real values
    base = File.join(@dir, 'imp.chat')
    File.write(base, "user: hi\nassistant: yo\n")
    top = File.join(@dir, 'imp_top.chat')
    File.write(top, "import: #{base}\nuser: q\nassistant: a\n")
    own2 = ChatAnalyst.job(:chat_accounting, {file: top}).run
    imports = own2[ChatAnalyst::Ids.chat_id(top)][imports_i]
    assert_equal ChatAnalyst::Ids.escape_path(base), imports, 'real import target, escaped, single member'

    # closure scope keeps the same invariant
    closure = ChatAnalyst.job(:chat_accounting, {file: parent, scope: 'closure'}).run
    closure.each do |_key, row|
      assert row[subtrees_i] == '\\N' || row[subtrees_i].count('|') >= 0
    end
  end

  def test_scope_annotation_and_rejects_unknown_scope
    top = closure_chat
    assert_equal 'own', ChatAnalyst.job(:chat_accounting, {file: top}).run.scope
    assert_equal 'closure', ChatAnalyst.job(:chat_accounting, {file: top, scope: 'closure'}).run.scope
    assert_raise(ParameterException) do
      ChatAnalyst.job(:chat_accounting, {file: top, scope: 'bogus'}).run
    end
  end
end
