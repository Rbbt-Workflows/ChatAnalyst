$LOAD_PATH.unshift '.'
require 'test/test_helper'
require 'json'

# Size fields of message_index and the filter inputs of chat_tool_calls. All
# fixtures are offline persisted chats written into the test tmpdir; the
# chat_tool_calls fixture mirrors the projection/log-copy shape used by the
# pagination tests so filtering can be checked against both raw and copied
# evidence.
class TestMessageSizesAndCallFilters < Test::Unit::TestCase
  def write_chat(path, text)
    File.write(path, text)
    Path.setup(path)
  end

  def sized_chat(dir)
    long = 'x' * 150_000
    # a message with no content at all (empty body) still gets an entry
    text = "user:\n\nshort one\n\nassistant:\n\nshort two\n\nuser:\n\n#{long}\n\nmeta: pt=1\n\nuser:\n\n"
    write_chat(File.join(dir, 'sized.chat'), text)
  end

  # Root chat with a delegation-style call (so target_agent/conversation are
  # parsed from arguments) plus one failing plain call. The ask arguments are
  # built with to_json so the inner string is properly escaped JSON.
  def calls_chat(dir)
    ask_args = %q({"agent":"Worker","conversation":"Session","name":"sum"})
    ask_line = 'function_call: ' + {name: 'ask', arguments: ask_args, id: 't1'}.to_json + "\n"
    text = "user: run\n" +
           ask_line +
           'function_call_output: ' + %q({"name":"ask","content":"{\"content\":\"ok\"}","id":"t1"}) + "\n" +
           'function_call: ' + %q({"name":"bash","arguments":"{\"cmd\":\"ls\"}","id":"t2"}) + "\n" +
           'function_call_output: ' + %q({"name":"bash","content":"{\"stderr\":\"boom\",\"exit_status\":1}","id":"t2"}) + "\n" +
           "meta: pt=1 ct=1 tt=2 inference_id=p1\n" +
           "assistant: done\n"
    write_chat(File.join(dir, 'calls.chat'), text)
  end

  def test_chat_messages_reports_character_counts_and_large_flag
    Dir.mktmpdir do |dir|
      path = sized_chat(dir)
      result = ChatAnalyst.job(:chat_messages, {file: path}).run
      # Phase 3 TSV surface: role/characters/timestamp/large per Message id
      assert_equal %w[9 9 150000 4], result.values.collect { |row| row[1] }
      assert_equal ['false', 'false', 'true', 'false'], result.values.collect { |row| row[3] }
      # the meta entry keeps its row even though it carries no content
      meta_row = result.values.find { |row| row[0] == 'meta' }
      assert_equal '4', meta_row[1]
      assert_equal 'false', meta_row[3]
    end
  end

  def test_chat_messages_size_fields_survive_role_filter_and_pagination
    Dir.mktmpdir do |dir|
      path = sized_chat(dir)
      only_user = ChatAnalyst.job(:chat_messages, {file: path, role: 'user'}).run
      assert_equal ['9', '150000'], only_user.values.collect { |row| row[1] }

      paged = ChatAnalyst.job(:chat_messages, {file: path, page: 1, per_page: 3}).run
      assert_equal 3, paged.length
      assert_equal 4, paged.options[:total]
      assert paged.values.all? { |row| row.length == 4 }
    end
  end

  def test_threshold_boundary_marks_only_messages_above_it
    Dir.mktmpdir do |dir|
      text = "user:\n\n#{'y' * 100_000}\n\nassistant:\n\n#{'z' * 100_001}\n"
      path = write_chat(File.join(dir, 'boundary.chat'), text)
      result = ChatAnalyst.job(:chat_messages, {file: path}).run
      assert_equal ['100000', '100001'], result.values.collect { |row| row[1] }
      assert_equal ['false', 'true'], result.values.collect { |row| row[3] }
      assert_equal 100_000, ChatAnalyst::LARGE_MESSAGE_CHARACTERS
    end
  end

  # Minimal revision (plan step 4): chat_tool_calls emits STRUCTURED records
  # (chat path + integers, no "path#index" strings, no legacy boolean
  # success); target agent / conversation are the two halves of
  # delegation_target "Agent#Conversation".
  # Phase 3 conversion (contract 2D): chat_tool_calls is a TSV keyed by the
  # call-start Message id; delegation_target is split into the two contract
  # columns target_agent / target_conversation.
  def test_calls_chat_fixture_shape
    Dir.mktmpdir do |dir|
      path = calls_chat(dir)
      result = ChatAnalyst.job(:chat_tool_calls, {file: path}).run
      assert_equal 2, result.length
      assert_equal 'ToolCall', result.key_field
      ask = result.values.find { |row| row[1] == 'ask' }
      assert_equal 'Worker', ask[11], 'target_agent column'
      assert_equal 'Session', ask[12], 'target_conversation column'
      assert_equal 'true', ask[10], 'delegated'
      # every key parses back through the Message-id grammar
      result.keys.each { |k| ChatAnalyst::Ids.parse_message_id(k) }
    end
  end

  # Filters narrow the LIST only; the pagination total stays RAW (the whole
  # filtered universe is counted, not just the page).  Settled simplification
  # this bout: the old summary block (successes/failures/copies/by_tool) is
  # NOT an annotation; the rows + filters annotation carry what a consumer
  # needs and by_tool etc. stay derivable by paging.
  def test_tool_and_success_filters_narrow_the_call_list_only
    Dir.mktmpdir do |dir|
      path = calls_chat(dir)
      raw = ChatAnalyst.job(:chat_tool_calls, {file: path}).run
      assert_equal 2, raw.length

      only_ask = ChatAnalyst.job(:chat_tool_calls, {file: path, tool: 'ask'}).run
      assert_equal ['ask'], only_ask.values.collect { |row| row[1] }
      assert_equal 1, only_ask.length
      assert_equal 'tool=ask', only_ask.filters, 'applied filters are annotated'

      assert_equal 0, ChatAnalyst.job(:chat_tool_calls, {file: path, tool: 'askx'}).run.length

      failing = ChatAnalyst.job(:chat_tool_calls, {file: path, success: false}).run
      assert failing.values.all? { |row| row[3] == 'failure' }
      assert_equal ['bash'], failing.values.collect { |row| row[1] }
      assert_equal 1, failing.length

      ok = ChatAnalyst.job(:chat_tool_calls, {file: path, success: true}).run
      assert ok.values.all? { |row| row[3] == 'success' }
      assert_equal 1, ok.length
    end
  end

  def test_agent_conversation_and_chat_filters
    Dir.mktmpdir do |dir|
      path = calls_chat(dir)
      raw = ChatAnalyst.job(:chat_tool_calls, {file: path}).run

      worker = ChatAnalyst.job(:chat_tool_calls, {file: path, agent: 'Worker'}).run
      assert_equal ['ask'], worker.values.collect { |row| row[1] }
      assert_equal 'agent=Worker', worker.filters

      session = ChatAnalyst.job(:chat_tool_calls, {file: path, conversation: 'Session'}).run
      assert_equal ['ask'], session.values.collect { |row| row[1] }

      chat_path = ChatAnalyst::Ids.parse_message_id(raw.keys.first).first
      by_chat = ChatAnalyst.job(:chat_tool_calls, {file: path, chat: chat_path}).run
      assert_equal raw.length, by_chat.length
      assert by_chat.keys.all? { |k| k.include?(ChatAnalyst::Ids.chat_id(chat_path)) }

      assert_equal 0, ChatAnalyst.job(:chat_tool_calls, {file: path, agent: 'Nobody'}).run.length
    end
  end

  def test_filters_combine_and_paginate_after_filtering
    Dir.mktmpdir do |dir|
      path = calls_chat(dir)
      combined = ChatAnalyst.job(:chat_tool_calls, {file: path, success: true, agent: 'Worker'}).run
      assert_equal ['ask'], combined.values.collect { |row| row[1] }

      paged = ChatAnalyst.job(:chat_tool_calls, {file: path, success: false, page: 1, per_page: 5}).run
      assert paged.values.all? { |row| row[3] == 'failure' }
      assert_equal 1, paged.length
      # pagination is applied to the filtered list, but total stays RAW
      # (contract 1f: it counts the whole universe, not the filtered page)
      assert_equal 2, paged.total
      assert_equal 1, paged.total_pages, 'total_pages pages the LISTED rows'
    end
  end
end
