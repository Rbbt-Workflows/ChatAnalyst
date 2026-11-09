$LOAD_PATH.unshift '.'
require 'test/test_helper'

# Minimal revision phase 2 (plan step 5, decision D1 + retirement 5c): the
# six pins of the retired test_extract_chat_range.rb ported onto chat_range
# (raw mode).  The retired task's cross-chat `start:`/`end:` split-input
# convenience and its job-root rejection were properties of the OLD adapter
# interface; the pins that survive port onto chat_range's first/last inputs
# plus the new raw mode:
#   - inclusive range selection,
#   - raw text is the byte-exact persisted slice and round-trips,
#   - invalid ranges and missing sources raise ParameterException,
#   - short (~) address forms resolve,
#   - job roots are rejected (chat files only).
# Deliberate loss (recorded, not a gap): message_content's cross-chat batch
# convenience (multiple ids across chats in one call) is knowingly dropped;
# the migrated agent issues one chat_range per chat.
class TestChatRangeRawMode < Test::Unit::TestCase
  def chat_file
    path = File.join(@__test_dir, 'source.chat')
    File.write(path, "user:\n\nfirst\n\nassistant:\n\nsecond\n\nuser:\n\nthird\n")
    path
  end

  def run_range(**inputs)
    ChatAnalyst.job(:chat_range, nil, **inputs).run
  end

  def test_raw_slice_is_inclusive_and_round_trips
    result = run_range(file: chat_file, first: 1, last: 2, raw: true)
    assert_equal 2, result[:messages].length
    assert_equal %w[second third], result[:messages].map { |m| m[:content] }

    assert_equal Chat.load(chat_file)[1..2], Chat.parse(result[:raw]),
                 'raw text must reload to exactly the selected messages'
    assert_equal %w[second third], Chat.parse(result[:raw]).map { |m| m[:content] }
    assert_equal %w[assistant user], Chat.parse(result[:raw]).map { |m| m[:role].to_s }
  end

  def test_raw_is_byte_exact_persisted_form
    result = run_range(file: chat_file, first: 0, last: 0, raw: true)
    assert_equal 'user:' + "\n\n" + 'first', result[:raw].strip,
                 'byte-exact persisted slice text (role line + blank line + content)'
    refute result[:raw].start_with?('{'), 'raw is chat-file text, never JSON'
  end

  # Exception-class note (deliberate port deviation, recorded in the phase-2
  # report): the retired adapter wrapped range/source validation in
  # ParameterException; the new surface validates in ChatAnalyst.range and
  # raises ArgumentError for range bounds and missing sources (the
  # task-level cap and job-root rejection stay ParameterException, below).
  # The REJECTION semantics are the pin; the class follows the new layer.
  def test_rejects_invalid_ranges_and_missing_source
    assert_raise(ArgumentError) { run_range(file: chat_file, first: -1, last: 0) }
    assert_raise(ArgumentError) { run_range(file: chat_file, first: 2, last: 1) }
    assert_raise(ArgumentError) { run_range(file: chat_file, first: 0, last: 3) }
    assert_raise(ArgumentError) { run_range(file: File.join(@__test_dir, 'missing.chat'), first: 0, last: 0) }
  end

  # short_path_from_path only produces ~-relative addresses for files under
  # the home directory, so the short-path fixture must live there; the test
  # sandbox tmpdir (/tmp) would defeat the round-trip under test.
  def home_chat_file
    dir = File.join(File.expand_path('~'), '.scout', 'tmp', "chatanalyst-range-#{$$}")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, 'source.chat')
    File.write(path, "user:\n\nfirst\n\nassistant:\n\nsecond\n\nuser:\n\nthird\n")
    path
  end

  def test_short_address_round_trips_through_raw
    absolute = home_chat_file
    begin
      short = "~#{absolute[File.expand_path('~').length..]}"
      result = run_range(file: short, first: 1, last: 2, raw: true)
      assert_equal %w[second third], Chat.parse(result[:raw]).map { |m| m[:content] }
      assert_equal %w[assistant user], Chat.parse(result[:raw]).map { |m| m[:role].to_s }
    ensure
      FileUtils.rm_rf(File.dirname(absolute))
    end
  end

  def test_short_and_absolute_addresses_agree
    absolute = home_chat_file
    begin
      home = File.expand_path('~')
      short = "~#{absolute[home.length..]}"
      short_raw = run_range(file: short, first: 0, last: 2, raw: true)[:raw]
      absolute_raw = run_range(file: absolute, first: 0, last: 2, raw: true)[:raw]
      assert_equal absolute_raw, short_raw
      assert_equal Chat.load(absolute).map { |m| m[:content] },
                   Chat.parse(short_raw).map { |m| m[:content] }
    ensure
      FileUtils.rm_rf(File.dirname(absolute))
    end
  end

  def test_rejects_job_root
    # A persisted Step has an .info sidecar; chat_range stays chat-file-only.
    path = File.join(@__test_dir, 'job_root')
    File.write(path, "user:\n\nnot a chat root\n")
    File.write(path + '.info', {}.to_json)
    assert_raise(ParameterException) do
      ChatAnalyst.job(:chat_range, nil, file: path, first: 0, last: 0).run
    end
  end
end
