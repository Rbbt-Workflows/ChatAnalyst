$LOAD_PATH.unshift '.'
require 'test/test_helper'

# Minimal revision phase 2 (plan step 6, decision D4 keep+fix): the
# chat_accounting single-pass pin.  Claim 4 (verified, holds): the adapter
# called ChatAnalyst.tokens repeatedly per chat — once in its own scope,
# again per chat in the closure scope (token_events_per_chat), and once
# more per chat for the merge — plus a separate overview and relationships
# call per chat.  The fixed implementation computes tokens / overview /
# relationships exactly ONCE per chat for the whole response (local
# memoization only; no persistent caching abstraction).
class TestChatAccountingSinglePass < Test::Unit::TestCase
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

  def test_own_scope_calls_each_api_once_per_chat
    top = closure_chat
    with_call_counters do |counts|
      result = ChatAnalyst.job(:chat_accounting, {file: top}).run

      # two chats in the closure (base + top), each fetched exactly once
      assert_equal 2, counts['tokens'], "tokens calls: #{counts.inspect}"
      assert_equal 2, counts['overview']
      assert_equal 2, counts['relationships']

      # behavior unchanged: both closure chats appear, imports resolved
      assert_equal 2, result[:entries].length
      assert result[:closure].length == 2
      JSON.generate(result)
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

      entry = result[:entries].first
      assert_equal :closure, entry[:scope]
      assert_equal 2, entry[:chats].length
      assert_equal({File.join(@dir, 'base.chat') => 0, top => 0},
                   entry[:token_events_per_chat])
      JSON.generate(result)
    end
  end
end
