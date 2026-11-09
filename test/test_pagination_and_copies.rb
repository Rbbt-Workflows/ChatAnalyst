$LOAD_PATH.unshift '.'
require 'test/test_helper'
require 'test/scout/agent_meta_fixtures'
require 'json'

# Pagination, copy-marking, and failure-count behaviour of the ChatAnalyst
# report tasks. Uses the same offline fixture family as the agent_meta tests.
class TestPaginationAndCopies < Test::Unit::TestCase
  include ChatAnalystFixtures

  # Root chat with three tool calls, one failing (its output content is the
  # JSON envelope a command-style tool returns). A producer job keeps a
  # socialized-projection log with the exact same call ids and arguments, so
  # the copy is discovered through a job log edge and the two must reconcile
  # to three unique calls out of six discovered.
  def fixture_with_calls(dir)
    text = "user: run\n" +
           'function_call: ' + %q({"name":"bash","arguments":"{\"cmd\":\"ls\"}","id":"t1"}) + "\n" +
           'function_call_output: ' + %q({"name":"bash","content":"{\"stdout\":\"ok\",\"stderr\":\"\",\"exit_status\":0,\"id\":\"t1\"}","id":"t1"}) + "\n" +
           'function_call: ' + %q({"name":"bash","arguments":"{\"cmd\":\"bad\"}","id":"t2"}) + "\n" +
           'function_call_output: ' + %q({"name":"bash","content":"{\"stdout\":\"\",\"stderr\":\"boom\",\"exit_status\":1,\"id\":\"t2\"}","id":"t2"}) + "\n" +
           'function_call: ' + %q({"name":"read","arguments":"{\"path\":\"a\"}","id":"t3"}) + "\n" +
           'function_call_output: ' + %q({"name":"read","content":"data","id":"t3"}) + "\n" +
           "meta: pt=1 ct=1 tt=2 inference_id=p1\n" +
           "assistant: done\n"
    job = make_job(dir, 'Worker/ask/Default_p', logs: {'projection.chat' => text})
    write_chat(dir, 'one.chat', text + "meta: job=#{job}\n")
  end

  def test_chat_tool_calls_pagination_and_dedupe
    Dir.mktmpdir do |dir|
      path = fixture_with_calls(dir)
      result = ChatAnalyst.job(:chat_tool_calls, {file: path}).run
      assert_equal 6, result[:total]
      assert_equal 6, result[:calls].length
      assert_equal 2, result[:failures]
      assert result[:calls].none? { |call| call[:copy_of] }
      # the by_tool histogram counts both copies: projections are real evidence
      assert_equal 4, result[:by_tool]['bash']
      assert_equal 2, result[:by_tool]['read']

      paged = ChatAnalyst.job(:chat_tool_calls, {file: path, page: 2, per_page: 4}).run
      assert_equal 2, paged[:calls].length
      assert_equal 2, paged[:total_pages]
      assert_equal 6, paged[:total]
      assert_equal 1, paged[:prev_page]
      assert_nil paged[:next_page]
      # counts still cover every call, not just the page
      assert_equal 2, paged[:failures]
      assert_equal 4, paged[:by_tool]['bash']

      deduped = ChatAnalyst.job(:chat_tool_calls, {file: path, dedupe: true}).run
      assert_equal 6, deduped[:total]
      assert_equal 3, deduped[:copies]
      assert_equal 3, deduped[:unique_calls]
      assert_equal 3, deduped[:calls].count { |call| call[:copy_of] }
      assert_equal 3, deduped[:calls].count { |call| !call[:copy_of] }

      # paged and deduped combine: pages carry copy markings too
      paged_deduped = ChatAnalyst.job(:chat_tool_calls, {file: path, page: 1, per_page: 4, dedupe: true}).run
      assert_equal 6, paged_deduped[:total]
      assert_equal 3, paged_deduped[:unique_calls]
      assert_equal 4, paged_deduped[:calls].length
    end
  end

  def test_chat_tokens_pagination
    Dir.mktmpdir do |dir|
      parent = fixture_receipt_only(dir)
      result = ChatAnalyst.job(:chat_tokens, {file: parent}).run
      assert_equal 3, result[:events].length

      paged = ChatAnalyst.job(:chat_tokens, {file: parent, page: 1, per_page: 2}).run
      assert_equal 2, paged[:events].length
      assert_equal 2, paged[:total_pages]
      assert_equal 3, paged[:total]
      # Minimal revision phase 2 (plan step 5 layering): an event page is a
      # PAGE, not a repeated summary — it carries events + paging metadata +
      # root only, and the flat totals stay on the unpaginated shape.
      assert_equal %i[page per_page total total_pages next_page prev_page events root],
                   paged.keys.sort_by { |key| paged.keys.index(key) }
      assert_equal parent, paged[:root][:path]
      refute paged.key?(:deduplicated_total), 'event page must not repeat summary totals'
      refute paged.key?(:scopes), 'event page must not repeat scopes'
      refute paged.key?(:conflicts), 'event page must not repeat conflicts'
      refute paged.key?(:warnings), 'event page must not repeat warnings'
    end
  end

  # chat_agents was retired in Phase C (zero external consumers per the
  # Stage 0 sweep; its delegation evidence lives on in chat_report's
  # delegation section and the chat_tool_calls adapter records).  The
  # pagination envelope behaviour this suite pins survives on chat_tokens.
  def test_chat_agents_pagination
    Dir.mktmpdir do |dir|
      parent, _worker = fixture_receipt_plus_log(dir)
      error = assert_raise(TaskNotFound) { ChatAnalyst.job(:chat_agents, {file: parent}).run }
      assert_match(/chat_agents/, error.message)
    end
  end

  # chat_report was retired in phase 2; its failure/unique-call counting
  # conveniences are NOT ported (deliberate loss: chat_tool_calls carries
  # the same counts as summary fields on a strictly raw universe).
  def test_chat_report_counts_failures_and_unique_calls
    Dir.mktmpdir do |dir|
      path = fixture_with_calls(dir)
      result = ChatAnalyst.job(:chat_tool_calls, {file: path}).run
      assert_equal 6, result[:total]
      assert_equal 2, result[:failures]
      assert_equal 4, result[:by_tool]['bash']
      error = assert_raise(TaskNotFound) { ChatAnalyst.job(:chat_report, {file: path}).run }
      assert_match(/chat_report/, error.message)
    end
  end
end
