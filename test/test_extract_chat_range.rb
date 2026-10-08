require_relative 'test_helper'

class TestExtractChatRange < Test::Unit::TestCase
  def chat_file
    path = File.join(@__test_dir, 'source.chat')
    File.write(path, "user:\n\nfirst\n\nassistant:\n\nsecond\n\nuser:\n\nthird\n")
    path
  end

  def run_extract(**inputs)
    ChatAnalyst.job(:extract_chat_range, nil, **inputs).run
  end

  def test_extracts_inclusive_range_and_round_trips
    result = run_extract(file: chat_file, start: 1, end: 2)
    assert_equal 2, Chat.load(TmpFile.with_file(result, false, extension: 'chat') { |p| p }).length
    assert_equal ['second', 'third'], Chat.load(TmpFile.with_file(result, false, extension: 'chat') { |p| p }).map { |m| m[:content] }
  end

  def test_return_path_and_explicit_output
    job = ChatAnalyst.job(:extract_chat_range, nil,file: chat_file, start: 0, end: 0)
    job.run
    assert_equal ['first'], Chat.load(job.path).map { |m| m[:content] }
  end

  def test_rejects_invalid_ranges_and_missing_source
    assert_raise(ParameterException) { run_extract(file: chat_file, start: -1, end: 0) }
    assert_raise(ParameterException) { run_extract(file: chat_file, start: 2, end: 1) }
    assert_raise(ParameterException) { run_extract(file: chat_file, start: 0, end: 3) }
    assert_raise(ParameterException) { run_extract(file: File.join(@__test_dir, 'missing.chat'), start: 0, end: 0) }
  end

  # short_path_from_path only produces ~-relative addresses for files under the
  # home directory, so the short-path fixtures must live there; the test
  # sandbox tmpdir (/tmp) would defeat the round-trip under test.
  def home_chat_file
    dir = File.join(File.expand_path('~'), '.scout', 'tmp', "chatanalyst-range-#{$$}")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, 'source.chat')
    File.write(path, "user:\n\nfirst\n\nassistant:\n\nsecond\n\nuser:\n\nthird\n")
    path
  end

  def test_round_trips_short_address_from_message_index
    absolute = home_chat_file
    begin
      index = ChatAnalyst.job(:message_index, nil, file: absolute).run
      address = index.find { |entry| entry[:role].to_s == 'user' }[:address]
      short_path, _index = address.split('#', 2)
      assert short_path.start_with?('~'), "message_index address should use the ~ short form: #{short_path}"
      job = ChatAnalyst.job(:extract_chat_range, nil, file: short_path, start: 1, end: 2)
      job.run
      extracted = Chat.load(job.path)
      assert_equal %w[second third], extracted.map { |m| m[:content] }
      assert_equal %w[assistant user], extracted.map { |m| m[:role].to_s }
    ensure
      FileUtils.rm_rf(File.dirname(absolute))
    end
  end

  def test_tilde_form_used_even_when_absolute_would_also_work
    absolute = home_chat_file
    begin
      home = File.expand_path('~')
      short = "~#{absolute[home.length..]}"
      short_job = ChatAnalyst.job(:extract_chat_range, nil, file: short, start: 0, end: 2)
      short_job.run
      absolute_job = ChatAnalyst.job(:extract_chat_range, nil, file: absolute, start: 0, end: 2)
      absolute_job.run
      assert_equal Chat.load(absolute_job.path).map { |m| m[:content] },
                   Chat.load(short_job.path).map { |m| m[:content] }
      # The ~ spelling is its own job name and resolves through expansion of
      # the literal input string, not by collapsing into the absolute job.
      assert short_job.path.include?('~'), 'job path should retain the literal ~ input form'
    ensure
      FileUtils.rm_rf(File.dirname(absolute))
    end
  end

  def test_rejects_job_root
    # A persisted Step has an .info sidecar; resolve_root classifies it as a
    # job root and extract_chat_range must stay chat-file-only.
    path = File.join(@__test_dir, 'job_root')
    File.write(path, "user:\n\nnot a chat root\n")
    File.write(path + '.info', {}.to_json)
    assert_raise(ParameterException) do
      ChatAnalyst.job(:extract_chat_range, nil, file: path, start: 0, end: 0).run
    end
  end
end
