$LOAD_PATH.unshift '.'
require File.expand_path(File.join(File.dirname(__FILE__), 'test_helper'))
require 'json'
require 'fileutils'
require 'time'

# Inbox-access API (scout-ai `inbox` prompt strategy, de79709): the three
# additive tasks live_chats / inbox_state / post_inbox_advice.  The
# end-to-end test runs the real Chat.inbox delivery against a posted note.
#
# Note on job reuse: these tasks are :json jobs whose only input is `file`
# (jobname), so two calls with the same file share one Step and the second
# call returns the cached result.  Tests that must observe a change on disk
# use unique jobnames (ChatAnalyst.job(:task, {...}, 'name')).
class TestInboxTasks < Test::Unit::TestCase
  setup do
    @dir = File.join(@__test_dir, 'session')
    FileUtils.mkdir_p(@dir)
  end

  # Job ids for the inbox_state runs that must observe a disk change: the
  # task is a persisted job keyed on `file`, so a shared id would serve the
  # first result again instead of re-reading the inbox. The per-process
  # memory cache set up by test_helper isolates runs in CI; unique ids keep
  # the tests correct when jobs are also spilled to disk.
  def fresh_id(label)
    "#{label}-#{File.basename(@__test_dir)}"
  end


  # --- fixtures ---------------------------------------------------------

  # Job root with own chats (agent + worker), a society chat, and mtimes
  # ordered so agent.chat is the newest.
  def fixture_job_root
    job = File.join(@dir, 'W', 'load', 'Default_1')
    files = job + '.files'
    FileUtils.mkdir_p(File.join(files, 'ask.society'))
    File.write(job, 'answer')
    File.write(job + '.info', {dependencies: [], status: 'done', pid: Process.pid}.to_json)
    File.write(File.join(files, 'agent.chat'), "user: running\n")
    File.write(File.join(files, 'worker.chat'), "user: old\n")
    File.write(File.join(files, 'ask.society', 'child.chat'), "user: child\n")

    FileUtils.touch(File.join(files, 'worker.chat'), mtime: Time.now - 300)
    FileUtils.touch(File.join(files, 'ask.society', 'child.chat'), mtime: Time.now - 120)
    FileUtils.touch(File.join(files, 'agent.chat'), mtime: Time.now - 2)
    job
  end

  # Chat save_file with one pending and one delivered inbox note.
  def fixture_chat_with_inbox
    chat = File.join(@dir, 'parent.chat')
    File.write(chat, "user: p\n")
    FileUtils.mkdir_p(File.join(@dir, 'parent.chat.files', 'inbox'))
    FileUtils.mkdir_p(File.join(@dir, 'parent.chat.files', 'inbox_removed'))
    File.write(File.join(@dir, 'parent.chat.files', 'inbox', 'a.md'), 'advice A')
    File.write(File.join(@dir, 'parent.chat.files', 'inbox_removed', 'old.md'), 'old advice')
    chat
  end

  # --- live_chats -------------------------------------------------------

  def test_live_chats_orders_newest_first_and_flags_active
    job = fixture_job_root
    result = ChatAnalyst.job(:live_chats, {file: job}).run

    paths = result[:chats].collect { |c| c[:path] }
    assert_equal File.join(job + '.files', 'agent.chat'), paths.first
    assert paths.include?(File.join(job + '.files', 'ask.society', 'child.chat'))
    assert paths.include?(File.join(job + '.files', 'worker.chat'))

    # mtimes strictly non-increasing newest-first
    mtimes = result[:chats].collect { |c| Time.parse(c[:mtime]) }
    assert_equal mtimes.sort.reverse, mtimes

    assert_equal 3, result[:total]
    assert_equal true, result[:chats].first[:likely_active]
    assert result[:chats][1..].none? { |c| c[:likely_active] }

    # job status present on a job root
    assert_equal 'done', result[:job][:status]
    assert_equal :job, result[:root_kind]
    entry = result[:chats].first
    assert entry[:age].is_a?(Float)
    assert_equal File.size(File.join(job + '.files', 'agent.chat')), entry[:size]
  end

  def test_live_chats_falls_back_to_glob_on_chat_without_files
    chat = File.join(@dir, 'bare.chat')
    File.write(chat, "user: alone\n")
    result = ChatAnalyst.job(:live_chats, {file: chat}).run

    assert_equal :chat, result[:root_kind]
    assert result[:job].nil?
    assert result[:chats].empty? || result[:chats].first[:path] == chat
  end

  def test_live_chats_glob_fallback_finds_unsaved_logs
    # A damaged job (dependencies entry unreadable) makes provenance
    # traversal yield nothing; the bounded glob under `<root>.files/` still
    # recovers the logs physically on disk.
    job = File.join(@dir, 'W', 'load', 'Damaged')
    files = job + '.files'
    FileUtils.mkdir_p(File.join(files, 'ask.society'))
    File.write(job, 'r')
    File.write(job + '.info', {dependencies: 'garbage', status: 'done'}.to_json)
    File.write(File.join(files, 'agent.chat'), "user: a\n")
    File.write(File.join(files, 'ask.society', 'child.chat'), "user: c\n")

    result = ChatAnalyst.job(:live_chats, {file: job}).run
    assert_equal :glob, result[:source]
    paths = result[:chats].collect { |c| c[:path] }
    assert paths.include?(File.join(files, 'agent.chat'))
    assert paths.include?(File.join(files, 'ask.society', 'child.chat'))
    assert_equal paths.length, paths.uniq.length
    assert_equal true, result[:chats].first[:likely_active]
  end

  def test_live_chats_chat_root_uses_sidecar_society_chats
    # A chat root keeps its own file plus society conversations from the
    # .files sidecar; the top-level root copy is excluded by core provenance.
    chat = File.join(@dir, 'live.chat')
    File.write(chat, "user: live\n")
    files = File.join(@dir, 'live.chat.files')
    FileUtils.mkdir_p(File.join(files, 'ask.society'))
    File.write(File.join(files, 'ask.society', 'child.chat'), "user: c\n")
    FileUtils.touch(File.join(files, 'ask.society', 'child.chat'), mtime: Time.now - 3)

    result = ChatAnalyst.job(:live_chats, {file: chat}).run
    assert_equal :provenance, result[:source]
    paths = result[:chats].collect { |c| c[:path] }
    assert_equal [chat, File.join(files, 'ask.society', 'child.chat')], paths
  end

  def test_live_chats_rejects_missing_file
    assert_raise(ParameterException) do
      ChatAnalyst.job(:live_chats, {file: File.join(@dir, 'nope.chat')}).run
    end
  end

  # --- inbox_state ------------------------------------------------------

  def test_inbox_state_lists_pending_and_delivered_with_content
    chat = fixture_chat_with_inbox
    state = ChatAnalyst.job(:inbox_state, {file: chat}).run

    assert_equal chat, state[:save_file]
    assert_equal chat + '.files', state[:files_dir]
    assert_equal File.join(chat + '.files', 'inbox'), state[:inbox_dir]
    assert_equal File.join(chat + '.files', 'inbox_removed'), state[:inbox_removed_dir]

    assert_equal ['a.md'], state[:pending].collect { |n| n[:name] }
    assert_equal 'advice A', state[:pending].first[:content]
    assert_equal 8, state[:pending].first[:size]
    assert_not_nil Time.parse(state[:pending].first[:mtime])

    assert_equal ['old.md'], state[:delivered].collect { |n| n[:name] }
    assert_equal 'old advice', state[:delivered].first[:content]
  end

  def test_inbox_state_missing_directories_are_empty
    chat = File.join(@dir, 'lonely.chat')
    File.write(chat, "user: l\n")
    state = ChatAnalyst.job(:inbox_state, {file: chat}).run

    assert_empty state[:pending]
    assert_empty state[:delivered]
    assert_equal File.join(chat + '.files', 'inbox'), state[:inbox_dir]
  end

  def test_inbox_state_rejects_job_root
    job = fixture_job_root
    assert_raise(ParameterException) do
      ChatAnalyst.job(:inbox_state, {file: job}).run
    end
  end

  # --- post_inbox_advice ------------------------------------------------

  def test_post_creates_note_and_it_appears_pending
    chat = fixture_chat_with_inbox
    posted = ChatAnalyst.job(:post_inbox_advice,
                             {file: chat, message: 'check the temp files', name: 'n1.md'}).run

    target = File.join(chat + '.files', 'inbox', 'n1.md')
    assert_equal target, posted[:posted]
    assert File.file?(target)
    assert_equal 'check the temp files', Open.read(target)

    state = ChatAnalyst.job(:inbox_state, fresh_id('after-post'), {file: chat}).run
    names = state[:pending].collect { |n| n[:name] }
    assert names.include?('n1.md')
    assert_equal 'check the temp files',
                 state[:pending].detect { |n| n[:name] == 'n1.md' }[:content]
  end

  def test_post_default_name_is_timestamped
    chat = fixture_chat_with_inbox
    posted = ChatAnalyst.job(:post_inbox_advice, {file: chat, message: 'auto named'}).run
    assert_match(/\A\d{8}-\d{6}-advice\.md\z/, posted[:name])
    assert File.file?(File.join(chat + '.files', 'inbox', posted[:name]))
  end

  def test_post_rejects_bad_inputs
    chat = fixture_chat_with_inbox
    assert_raise(ParameterException) do
      ChatAnalyst.job(:post_inbox_advice, {file: chat, message: '   '}).run
    end
    assert_raise(ParameterException) do
      ChatAnalyst.job(:post_inbox_advice, {file: chat, message: 'x', name: 'a/b.md'}).run
    end
  end

  # --- end to end against scout-ai itself -------------------------------

  def test_end_to_end_post_delivers_through_chat_inbox
    chat = File.join(@dir, 'e2e.chat')
    File.write(chat, "user: start\n")

    advice = 'stop repeating the same probe; check the save_file shape'
    posted = ChatAnalyst.job(:post_inbox_advice, {file: chat, message: advice}).run

    # still pending before the real inference
    before = ChatAnalyst.job(:inbox_state, fresh_id('before'), {file: chat}).run
    assert_equal [posted[:name]], before[:pending].collect { |n| n[:name] }

    # the strategy: same call scout-ai makes on every real inference
    prepared = Chat.inbox([{role: 'user', content: 'x'}], save_file: chat)

    # the posted content was appended as a user message, after the transcript
    injected = prepared.select { |m| m[:role] == 'user' && m[:content] == advice }
    assert_equal 1, injected.length
    assert_equal 'x', prepared.first[:content]

    # the note moved into inbox_removed/ (delivery record, name preserved)
    assert !File.exist?(File.join(chat + '.files', 'inbox', posted[:name]))
    removed = File.join(chat + '.files', 'inbox_removed', posted[:name])
    assert File.file?(removed)
    assert_equal advice, Open.read(removed)

    after = ChatAnalyst.job(:inbox_state, fresh_id('after'), {file: chat}).run
    assert_empty after[:pending]
    assert_equal [posted[:name]], after[:delivered].collect { |n| n[:name] }
    assert_equal advice, after[:delivered].first[:content]

    # consume-once: a second real inference appends nothing new
    second = Chat.inbox([{role: 'user', content: 'y'}], save_file: chat)
    assert second.none? { |m| m[:content] == advice }
  end
end
