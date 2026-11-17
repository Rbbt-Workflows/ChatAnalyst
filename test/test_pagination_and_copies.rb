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

  # Phase 3 conversion (contract 2D): chat_tool_calls is a TSV (key
  # ToolCall).  The JSON summary block (failures/copies/by_tool) is NOT an
  # annotation (settled simplification: everything in it is derivable from
  # the rows); the pagination total stays raw.
  def test_chat_tool_calls_pagination_and_dedupe
    Dir.mktmpdir do |dir|
      path = fixture_with_calls(dir)
      result = ChatAnalyst.job(:chat_tool_calls, {file: path}).run
      assert_equal 6, result.length
      assert_equal 6, result.total
      assert result.values.none? { |row| row[13] != '\\N' }, 'no copy markings without dedupe'
      # the tool histogram is derivable from the rows: projections are real
      # evidence (bash x4 incl. copy, read x2)
      assert_equal 4, result.values.count { |row| row[1] == 'bash' }
      assert_equal 2, result.values.count { |row| row[1] == 'read' }
      assert_equal 2, result.values.count { |row| row[3] == 'failure' }

      paged = ChatAnalyst.job(:chat_tool_calls, {file: path, page: 2, per_page: 4}).run
      assert_equal 2, paged.length
      assert_equal 2, paged.total_pages
      assert_equal 6, paged.total
      assert_equal 1, paged.prev_page
      assert_nil paged.next_page
      # the page rows carry the same columns as the unpaginated table
      assert paged.values.all? { |row| row.length == result.values.first.length }

      # dedupe MARKS copies (copy_of/source_kind columns) instead of
      # dropping rows: 6 rows, 3 marked copy, 3 primary
      deduped = ChatAnalyst.job(:chat_tool_calls, {file: path, dedupe: true}).run
      assert_equal 6, deduped.total, 'total stays raw under dedupe'
      assert_equal 6, deduped.length, 'dedupe marks copies, it does not drop rows'
      assert_equal 3, deduped.values.count { |row| row[13] != '\\N' }
      assert_equal 3, deduped.values.count { |row| row[13] == '\\N' }
      assert_equal 3, deduped.values.count { |row| row[14] == 'primary' }
      assert_equal 3, deduped.values.count { |row| row[14] == 'copy' }

      # paged and deduped combine: pages carry copy markings too
      paged_deduped = ChatAnalyst.job(:chat_tool_calls, {file: path, page: 1, per_page: 4, dedupe: true}).run
      assert_equal 6, paged_deduped.total
      assert_equal 2, paged_deduped.total_pages
      assert_equal 4, paged_deduped.length
    end
  end

  # chat_tokens is the SUMMARY table now (contract 2E); the paginated event
  # list lives on chat_token_events.
  def test_chat_tokens_is_the_summary_table
    Dir.mktmpdir do |dir|
      parent = fixture_receipt_only(dir)
      summary = ChatAnalyst.job(:chat_tokens, {file: parent}).run
      assert_equal 'Scope', summary.key_field
      assert_equal 4, summary.length
      assert_equal 4, summary.total
      assert_equal %w[chat_evidence deduplicated_total receipt_evidence receipt_only],
                   summary.keys.sort
      assert Integer === summary.conflicts
      assert Integer === summary.incomplete_evidence

      events = ChatAnalyst.job(:chat_token_events, {file: parent}).run
      assert_equal 3, events.length
      paged = ChatAnalyst.job(:chat_token_events, {file: parent, page: 1, per_page: 2}).run
      assert_equal 2, paged.length
      assert_equal 2, paged.total_pages
      assert_equal 3, paged.total
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
      assert_equal 6, result.length
      assert_equal 2, result.values.count { |row| row[3] == 'failure' }
      assert_equal 4, result.values.count { |row| row[1] == 'bash' }
      error = assert_raise(TaskNotFound) { ChatAnalyst.job(:chat_report, {file: path}).run }
      assert_match(/chat_report/, error.message)
    end
  end
end
