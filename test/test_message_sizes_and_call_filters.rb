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

  def test_message_index_reports_character_counts_and_large_flag
    Dir.mktmpdir do |dir|
      path = sized_chat(dir)
      result = ChatAnalyst.job(:message_index, {file: path}).run
      assert result.all? { |message| Integer === message[:characters] }, 'every entry carries an integer characters'
      assert_equal [9, 9, 150_000, 4], result.collect { |message| message[:characters] }
      assert result.all? { |message| message.key?(:large) }, 'every entry carries the large key'
      assert_equal [false, false, true, false], result.collect { |message| message[:large] }
      # the meta entry keeps both keys even though it carries no content
      meta_entry = result.find { |message| message[:role] == :meta }
      assert_equal 4, meta_entry[:characters]
      assert_equal false, meta_entry[:large]
    end
  end

  def test_message_index_size_fields_survive_role_filter_and_pagination
    Dir.mktmpdir do |dir|
      path = sized_chat(dir)
      only_user = ChatAnalyst.job(:message_index, {file: path, role: 'user'}).run
      assert_equal [9, 150_000], only_user.collect { |message| message[:characters] }

      paged = ChatAnalyst.job(:message_index, {file: path, page: 1, per_page: 3}).run
      assert_equal 3, paged[:messages].length
      assert_equal 4, paged[:total]
      assert paged[:messages].all? { |message| message.key?(:characters) && message.key?(:large) }
    end
  end

  def test_threshold_boundary_marks_only_messages_above_it
    Dir.mktmpdir do |dir|
      text = "user:\n\n#{'y' * 100_000}\n\nassistant:\n\n#{'z' * 100_001}\n"
      path = write_chat(File.join(dir, 'boundary.chat'), text)
      result = ChatAnalyst.job(:message_index, {file: path}).run
      assert_equal [100_000, 100_001], result.collect { |message| message[:characters] }
      assert_equal [false, true], result.collect { |message| message[:large] }
      assert_equal 100_000, ChatAnalyst::LARGE_MESSAGE_CHARACTERS
    end
  end

  def test_calls_chat_fixture_shape
    Dir.mktmpdir do |dir|
      path = calls_chat(dir)
      result = ChatAnalyst.job(:chat_tool_calls, {file: path}).run
      assert_equal 2, result[:total]
      ask = result[:calls].find { |call| call[:tool] == 'ask' }
      assert_equal 'Worker', ask[:target_agent]
      assert_equal 'Session', ask[:conversation]
    end
  end

  def test_tool_and_success_filters_narrow_the_call_list_only
    Dir.mktmpdir do |dir|
      path = calls_chat(dir)
      raw = ChatAnalyst.job(:chat_tool_calls, {file: path}).run

      only_ask = ChatAnalyst.job(:chat_tool_calls, {file: path, tool: 'ask'}).run
      assert_equal ['ask'], only_ask[:calls].collect { |call| call[:tool] }
      # summary counts stay raw: total and by_tool describe the whole session
      assert_equal raw[:total], only_ask[:total]
      assert_equal raw[:by_tool], only_ask[:by_tool]
      assert only_ask[:calls].length < raw[:calls].length

      assert_equal 0, ChatAnalyst.job(:chat_tool_calls, {file: path, tool: 'askx'}).run[:calls].length

      failing = ChatAnalyst.job(:chat_tool_calls, {file: path, success: false}).run
      assert failing[:calls].all? { |call| call[:success] == false }
      assert_equal ['bash'], failing[:calls].collect { |call| call[:tool] }
      assert_equal raw[:failures], failing[:failures]

      ok = ChatAnalyst.job(:chat_tool_calls, {file: path, success: true}).run
      assert ok[:calls].all? { |call| call[:success] == true }
      assert_equal raw[:successes], ok[:successes]
    end
  end

  def test_agent_conversation_and_chat_filters
    Dir.mktmpdir do |dir|
      path = calls_chat(dir)
      raw = ChatAnalyst.job(:chat_tool_calls, {file: path}).run

      worker = ChatAnalyst.job(:chat_tool_calls, {file: path, agent: 'Worker'}).run
      assert_equal ['ask'], worker[:calls].collect { |call| call[:tool] }
      assert_equal raw[:total], worker[:total]

      session = ChatAnalyst.job(:chat_tool_calls, {file: path, conversation: 'Session'}).run
      assert_equal ['ask'], session[:calls].collect { |call| call[:tool] }

      chat_path = raw[:calls].first[:call_address].to_s.split('#', 2).first
      by_chat = ChatAnalyst.job(:chat_tool_calls, {file: path, chat: chat_path}).run
      assert_equal raw[:calls].length, by_chat[:calls].length
      assert by_chat[:calls].all? { |call| call[:call_address].to_s.start_with?("#{chat_path}#") }

      assert_equal 0, ChatAnalyst.job(:chat_tool_calls, {file: path, agent: 'Nobody'}).run[:calls].length
    end
  end

  def test_filters_combine_and_paginate_after_filtering
    Dir.mktmpdir do |dir|
      path = calls_chat(dir)
      combined = ChatAnalyst.job(:chat_tool_calls, {file: path, success: true, agent: 'Worker'}).run
      assert_equal ['ask'], combined[:calls].collect { |call| call[:tool] }

      paged = ChatAnalyst.job(:chat_tool_calls, {file: path, success: false, page: 1, per_page: 5}).run
      assert paged[:calls].all? { |call| call[:success] == false }
      assert_equal 1, paged[:calls].length
      assert paged.key?(:total_pages), 'pagination envelope is applied to the filtered list'
    end
  end
end
