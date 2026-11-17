$LOAD_PATH.unshift '.'
require 'test/test_helper'
require 'test/scout/agent_meta_fixtures'

# Minimal revision phase 2 (retirement 5c), PHASE 3 CONVERSION (bout 4):
# the retired message_index adapter's whole-session size/filter/pagination
# pins carried forward on chat_messages, now in TSV form (contract 2B).
# The retired adapter indexed EVERY chat of the traversal in one flat
# address list; the replacement indexes ONE chat per call — the migrated
# agent iterates overview chat paths (recorded deliberate loss, not a gap).
# The PINS that survive unchanged, against the same sized fixture:
# character counts, the large flag, the role filter, pagination semantics
# (total counts the RAW universe) and the meta-entry size fields.
class TestChatMessagesCarriesMessageIndexPins < Test::Unit::TestCase
  include ChatAnalystFixtures
  include Phase3TSVHelpers if defined?(Phase3TSVHelpers)

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

  def test_message_index_reports_character_counts_and_large_flag
    Dir.mktmpdir do |dir|
      path = sized_chat(dir)
      result = ChatAnalyst.job(:chat_messages, {file: path}).run
      assert_equal 'Message', result.key_field
      assert_equal %w[role characters timestamp large], result.fields
      assert result.values.all? { |row| row[1].match?(/\A\d+\z/) }, 'every row carries a decimal character count'
      assert_equal ['9', '9', '150000', '4'], result.values.collect { |row| row[1] }
      assert result.values.all? { |row| %w[true false].include?(row[3]) }, 'every row carries a boolean large flag'
      assert_equal ['false', 'false', 'true', 'false'], result.values.collect { |row| row[3] }
      # the meta entry keeps both fields even though it carries no content
      meta_key = result.keys.find { |key| key.end_with?('#3') }
      meta_row = result[meta_key]
      assert_equal 'meta', meta_row[0]
      assert_equal '4', meta_row[1]
      assert_equal 'false', meta_row[3]
    end
  end

  def test_message_index_size_fields_survive_role_filter_and_pagination
    Dir.mktmpdir do |dir|
      path = sized_chat(dir)
      only_user = ChatAnalyst.job(:chat_messages, {file: path, role: 'user'}).run
      assert_equal ['9', '150000'], only_user.values.collect { |row| row[1] }
      assert_equal 2, only_user.length
      # the role filter narrows the LIST only; total counts the raw chat
      assert_equal 4, only_user.options[:total]

      paged = ChatAnalyst.job(:chat_messages, {file: path, page: 1, per_page: 3}).run
      assert_equal 3, paged.length
      assert_equal 4, paged.options[:total]
      assert_equal 2, paged.options[:total_pages]
      assert_equal 2, paged.options[:next_page]
      # out-of-range page: empty rows, never an error; total unchanged
      past = ChatAnalyst.job(:chat_messages, {file: path, page: 9}).run
      assert_equal 0, past.length
      assert_equal 4, past.options[:total]
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

  # message_index was a whole-session index: chat_messages + overview chat
  # paths compose the same information with one call per chat.  A job
  # contributes a traversed transcript only when it is chat-typed: the job
  # FILE itself carries the chat text and its path ends in .chat (the same
  # shape as the n2 job-root fixture).
  def test_whole_session_index_composes_from_overview
    Dir.mktmpdir do |dir|
      worker = File.join(dir, 'Worker/ask/Default_w.chat')
      FileUtils.mkdir_p(File.dirname(worker))
      File.write(worker, "user: w\nmeta: pt=1 ct=1 tt=2 inference_id=w1\nassistant: d\n")
      File.write(worker + '.info', {status: 'done', type: 'chat', dependencies: []}.to_json)
      parent = File.join(@__test_dir, 'parent.chat')
      File.write(parent, "user: run\n" +
        'function_call: ' + %({"name":"ask","arguments":{"agent":"Worker"},"id":"a1"}) + "\n" +
        'function_call_output: ' + %({"name":"ask","content":"ok","id":"a1","meta":#{[meta_receipt("job=#{worker}")].to_json}}) + "\n" +
        "meta: pt=1 ct=1 tt=2 inference_id=p1\n" +
        "assistant: done\n")

      overview = ChatAnalyst.overview(parent)
      counts = overview[:chats].collect { |record| [record[:path], ChatAnalyst.message_index(record[:path]).length] }
      assert counts.length >= 2, "both chats indexed: #{counts.inspect}"
      assert counts.sum { |_path, count| count } >= 8
    end
  end
end
