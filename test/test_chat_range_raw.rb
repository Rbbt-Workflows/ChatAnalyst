$LOAD_PATH.unshift '.'
require 'test/test_helper'
require 'test/scout/agent_meta_fixtures'

# Minimal revision phase 2 (plan step 5, decision D1 + retirement 5c), PHASE
# 3 CONVERSION (bout 4): the six pins of the retired test_extract_chat_range.rb
# on chat_range, now over the :chat OUTPUT (contract 2B: the byte-exact
# persisted slice is THE output; the raw INPUT is retired; the envelope
# fields chat/first/last live in the persisted job INPUTS because a :chat
# output carries no '#:' annotation line).
# The retired task's cross-chat `start:`/`end:` split-input convenience and
# its job-root rejection were properties of the OLD adapter interface; the
# pins that survive port onto chat_range's first/last inputs plus the raw
# output:
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
    job = ChatAnalyst.job(:chat_range, nil, **inputs)
    text = job.run
    [text, job]
  end

  # A :chat output carries no '#:' annotation line, so the slice addressing
  # (chat/first/last) is recovered from the persisted job INPUTS: info[:inputs]
  # is the positional input Array (file, first, last) in declared order.
  def slice_inputs(job)
    step = Step.load(job.path)
    step.info['inputs']
  end

  def test_raw_slice_is_inclusive_and_round_trips
    text, job = run_range(file: chat_file, first: 1, last: 2)
    # inclusive: exactly messages 1..2 round-trip out of the output text
    assert_equal 2, Chat.parse(text).length
    assert_equal %w[second third], Chat.parse(text).map { |m| m[:content] }
    assert_equal %w[assistant user], Chat.parse(text).map { |m| m[:role].to_s }
    assert_equal Chat.load(chat_file)[1..2], Chat.parse(text),
                 'output text must reload to exactly the selected messages'
    # the slice addressing lives in the persisted job INPUTS (contract 1f
    # amendment: a :chat output carries no '#:' line)
    assert_equal [chat_file, 1, 2], slice_inputs(job)
    assert_equal chat_file, Step.load(job.path).info['provided_inputs']['file']
  end

  def test_raw_is_byte_exact_persisted_form
    text, _job = run_range(file: chat_file, first: 0, last: 0)
    assert_equal 'user:' + "\n\n" + 'first', text.strip,
                 'byte-exact persisted slice text (role line + blank line + content)'
    refute text.start_with?('{'), 'raw is chat-file text, never JSON'
    # single-message slice: first == last in the inputs
    _t, job = run_range(file: chat_file, first: 2, last: 2)
    assert_equal [chat_file, 2, 2], slice_inputs(job)
  end

  # Exception-class note (deliberate port deviation, recorded in the phase-2
  # report): the retired adapter wrapped range/source validation in
  # ParameterException; the new surface validates in ChatAnalyst.range and
  # raises ArgumentError for range bounds and missing sources (the
  # task-level cap and job-root rejection stay ParameterException, below).
  # The REJECTION semantics are the pin; the class follows the new layer.
  def test_rejects_invalid_ranges_and_missing_source
    # the task layer rescues ArgumentError from ChatAnalyst.range and maps it
    # to ParameterException (the migrated consumer surface is a Scout job)
    assert_raise(ParameterException) { run_range(file: chat_file, first: -1, last: 0) }
    assert_raise(ParameterException) { run_range(file: chat_file, first: 2, last: 1) }
    assert_raise(ParameterException) { run_range(file: chat_file, first: 0, last: 3) }
    assert_raise(ParameterException) { run_range(file: File.join(@__test_dir, 'missing.chat'), first: 0, last: 0) }
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
      text, _job = run_range(file: short, first: 1, last: 2)
      assert_equal %w[second third], Chat.parse(text).map { |m| m[:content] }
      assert_equal %w[assistant user], Chat.parse(text).map { |m| m[:role].to_s }
    ensure
      FileUtils.rm_rf(File.dirname(absolute))
    end
  end

  def test_short_and_absolute_addresses_agree
    absolute = home_chat_file
    begin
      home = File.expand_path('~')
      short = "~#{absolute[home.length..]}"
      short_text, _j1 = run_range(file: short, first: 0, last: 2)
      absolute_text, _j2 = run_range(file: absolute, first: 0, last: 2)
      assert_equal absolute_text, short_text
      assert_equal Chat.load(absolute).map { |m| m[:content] },
                   Chat.parse(short_text).map { |m| m[:content] }
    ensure
      FileUtils.rm_rf(File.dirname(absolute))
    end
  end

  # Phase 3 pins: the task-level cap still applies BEFORE any load, and the
  # boundary of exactly MAX_RANGE_MESSAGES is allowed.
  def test_range_cap_boundary
    # the cap guard fires BEFORE any chat load: a 3-message chat with a
    # capped-width request hits the CAP check first (ParameterException naming
    # the cap), never the out-of-range check of the underlying loader.
    cap = ChatAnalyst::MAX_RANGE_MESSAGES
    wide = File.join(@__test_dir, 'wide.chat')
    File.write(wide, "user:\n\na\n\nassistant:\n\nb\n\nuser:\n\nc\n")
    _text, job = run_range(file: wide, first: 0, last: 2)
    assert_equal [wide, 0, 2], slice_inputs(job)
    error = assert_raise(ParameterException) do
      run_range(file: wide, first: 0, last: cap)
    end
    assert_match(/at most #{cap} messages/, error.message)
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
