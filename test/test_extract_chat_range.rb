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
end
