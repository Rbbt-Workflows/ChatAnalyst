$LOAD_PATH.unshift '.'
require File.expand_path(File.join(File.dirname(__FILE__), 'test_helper'))
require 'json'
require 'fileutils'
require 'time'

# Inbox-access API (scout-ai `inbox` prompt strategy, per-save-file sibling
# scheme): the three additive tasks live_chats / inbox_state /
# post_inbox_advice, plus the in-flight delegation discovery through the
# transient `.jobs` files.  The end-to-end tests run the real
# Chat.inbox delivery against a posted note; no LLM is contacted (Chat.inbox
# is a pure prompt strategy).
#
# Layout this suite targets (scout-ai @ fa5a57d dirty tree, see
# tmp/inbox-v2/scout-ai-semantics.md): the inbox of a save_file is a SIBLING
# of it in its own directory, `Chat.inbox_dir(save_file)` /
# `Chat.inbox_removed_dir(save_file)` -- for save_file
# `<chat>.files/<agent>.chat`: `<chat>.files/<agent>.inbox{,_removed}`.
#
# Note on job reuse: these tasks are :json jobs whose only jobname input is
# `file`, so two calls with the same file share one Step and the second call
# returns the cached result.  Tests that must observe a change on disk use
# unique jobnames (ChatAnalyst.job(:task, {...}, 'name')).
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

  # Phase 3: one TSV row as an IndifferentHash keyed by field name.
  def row_for(result, key)
    result[key]
  end

  # Point Chat.load_job_reference's fallback bases at a tmp fixture tree so
  # `.jobs` references resolve hermetically (same technique as
  # test_job_reference_fallback.rb). Restores the shipped definition.
  def with_fixture_job_bases(&block)
    base = File.join(@__test_dir, 'jobs-base')
    FileUtils.mkdir_p(base)

    original = (Chat.method(:job_reference_fallback_bases) rescue nil)
    Chat.singleton_class.class_eval do
      define_method(:job_reference_fallback_bases) { [File.expand_path(base)] }
    end
    yield base
  ensure
    if original
      Chat.singleton_class.class_eval do
        define_method(:__restored_job_reference_fallback_bases, original)
        alias_method :job_reference_fallback_bases, :__restored_job_reference_fallback_bases
        remove_method :__restored_job_reference_fallback_bases
      end
    else
      Chat.singleton_class.class_eval do
        remove_method(:job_reference_fallback_bases) if method_defined?(:job_reference_fallback_bases)
      end
    end
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

  # Chat save_file with one pending and one delivered inbox note, using the
  # sibling scheme derived by the sanctioned scout-ai helpers.
  def fixture_chat_with_inbox
    chat = File.join(@dir, 'parent.chat')
    File.write(chat, "user: p\n")
    inbox = Chat.inbox_dir(chat)
    removed = Chat.inbox_removed_dir(chat)
    FileUtils.mkdir_p(inbox)
    FileUtils.mkdir_p(removed)
    File.write(File.join(inbox, 'a.md'), 'advice A')
    File.write(File.join(removed, 'old.md'), 'old advice')
    chat
  end

  # Materialize a fake running job (so `Chat.job_reference_candidate?` and
  # Chat.direct_job_chat_files see it) with chat logs in its files_dir.
  # Returns [step_dir, files_dir]. short_path must be relative to base.
  def fixture_delegated_job(base, short_path, chat_name, extra = {})
    job = File.join(base, short_path)
    files = job + '.files'
    FileUtils.mkdir_p(File.join(files, 'ask.society'))
    File.write(job, 'child answer')
    File.write(job + '.info', {dependencies: [], status: 'running',
                               pid: extra[:pid] || 999_999}.to_json)
    File.write(File.join(files, chat_name), "user: #{chat_name.sub(/\.chat\z/, '')}\n")
    [job, files]
  end

  # The `.jobs` sibling of a save_file, exactly as scout-ai writes it: the
  # same anchored `sub(/\.chat\z/,'') + '.jobs'` derivation, bare short_path
  # lines joined with "\n" and NO trailing newline.
  def write_jobs_file(save_file, short_paths)
    jobs_file = save_file.to_s.sub(/\.chat\z/, '') + '.jobs'
    Open.write(jobs_file, short_paths * "\n")
    jobs_file
  end

  # --- live_chats: provenance / glob sources (unchanged behavior) --------

  def test_live_chats_orders_newest_first_and_flags_active
    job = fixture_job_root
    result = ChatAnalyst.job(:live_chats, {file: job}).run

    # canonical absolute keys (the phase-3 fix: no ~/ shortening anywhere)
    paths = result.keys.collect { |k| ChatAnalyst::Ids.unescape_path(k) }
    assert_equal File.join(job + '.files', 'agent.chat'), paths.first
    assert paths.include?(File.join(job + '.files', 'ask.society', 'child.chat'))
    assert paths.include?(File.join(job + '.files', 'worker.chat'))
    assert paths.all? { |p| p.start_with?('/') && !p.include?('~') }
    assert result.keys.none? { |k| k.include?('#') }, 'escaped keys carry no raw #'

    # mtimes strictly non-increasing newest-first (iso8601(3) cells)
    mtimes = result.keys.collect { |k| row_for(result, k)['mtime'] }
    parsed = mtimes.collect { |m| Time.parse(m) }
    assert_equal parsed.sort.reverse, parsed
    assert mtimes.all? { |m| m.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/) }

    assert_equal 3, result.total
    assert_equal 'true', row_for(result, result.keys.first)['likely_active']
    assert result.keys[1..].none? { |k| row_for(result, k)['likely_active'] == 'true' }

    # every entry carries a source tag; ages are decimal strings, sizes int
    assert result.keys.all? { |k| %w[provenance glob jobs].include?(row_for(result, k)['source']) }
    entry = row_for(result, result.keys.first)
    assert entry['age_seconds'].match?(/\A\d+(\.\d+)?\z/)
    assert_equal File.size(File.join(job + '.files', 'agent.chat')).to_s, entry['size']

    # RECORDED SIMPLIFICATION (pinned): the JSON job-root status block is
    # gone; the root is addressable through chat_overview/job_overview.
    assert !result.respond_to?(:job), 'status block dropped'
    assert_equal 'Chat', result.key_field
    assert_equal %w[mtime age_seconds size likely_active source jobs_file], result.fields
    assert_nil result.options[:cast]
  end

  def test_live_chats_falls_back_to_glob_on_chat_without_files
    chat = File.join(@dir, 'bare.chat')
    File.write(chat, "user: alone\n")
    result = ChatAnalyst.job(:live_chats, {file: chat}).run

    paths = result.keys.collect { |k| ChatAnalyst::Ids.unescape_path(k) }
    assert result.keys.empty? || paths.first == chat
  end

  def test_live_chats_glob_fallback_finds_unsaved_logs
    # A damaged job (dependencies entry unreadable) is TOLERATED by the
    # compact graph (Phase C): `live` globs the files directory directly and
    # never depends on the dependencies, so the same logs physically on disk
    # are recovered and the dependency error becomes a warning, not a
    # traversal failure.  The recursive-glob fallback in the helper stays as
    # a defensive path for a root the compact graph cannot even open; this
    # fixture pins that damaged metadata no longer forces it.
    job = File.join(@dir, 'W', 'load', 'Damaged')
    files = job + '.files'
    FileUtils.mkdir_p(File.join(files, 'ask.society'))
    File.write(job, 'r')
    File.write(job + '.info', {dependencies: 'garbage', status: 'done'}.to_json)
    File.write(File.join(files, 'agent.chat'), "user: a\n")
    File.write(File.join(files, 'ask.society', 'child.chat'), "user: c\n")

    result = ChatAnalyst.job(:live_chats, {file: job}).run
    paths = result.keys.collect { |k| ChatAnalyst::Ids.unescape_path(k) }
    assert paths.include?(File.join(files, 'agent.chat'))
    assert paths.include?(File.join(files, 'ask.society', 'child.chat'))
    assert_equal paths.length, paths.uniq.length
    assert_equal 'true', row_for(result, result.keys.first)['likely_active']
  end

  def test_live_chats_chat_root_uses_sidecar_society_chats
    # A chat root keeps its own file plus society conversations from the
    # .files sidecar; core provenance only excludes a top-level file that is
    # byte-identical to the root conversation (this fixture has none), the
    # agent transcript sidecar itself is traversed (see the test below).
    chat = File.join(@dir, 'live.chat')
    File.write(chat, "user: live\n")
    files = File.join(@dir, 'live.chat.files')
    FileUtils.mkdir_p(File.join(files, 'ask.society'))
    File.write(File.join(files, 'ask.society', 'child.chat'), "user: c\n")
    FileUtils.touch(File.join(files, 'ask.society', 'child.chat'), mtime: Time.now - 3)

    result = ChatAnalyst.job(:live_chats, {file: chat}).run
    paths = result.keys.collect { |k| ChatAnalyst::Ids.unescape_path(k) }
    assert_equal [chat, File.join(files, 'ask.society', 'child.chat')], paths
    assert result.keys.all? { |k| row_for(result, k)['source'] == 'provenance' }
  end

  def test_live_chats_chat_root_follows_top_level_transcript_refs
    # The Lean regression: a session chat whose ROOT file carries no job
    # references keeps them in the top-level `.files/agent.chat` agent
    # transcript.  live_chats on the chat root must traverse that transcript,
    # reach the referenced job tree, and list exactly the same working set as
    # a sidecar-rooted run plus the root file itself.
    job = File.join(@dir, 'Planned', 'work', 'Default_w')
    job_files = job + '.files'
    FileUtils.mkdir_p(File.join(job_files, 'ask.society'))
    File.write(job, 'work answer')
    File.write(job + '.info', {dependencies: [], status: 'done'}.to_json)
    File.write(File.join(job_files, 'agent.chat'), "user: work\n")
    File.write(File.join(job_files, 'ask.society', 'worker_child.chat'), "user: child\n")

    chat = File.join(@dir, 'session.chat')
    File.write(chat, "user: hi\nassistant: done\n")
    files = chat + '.files'
    FileUtils.mkdir_p(files)
    # Transcript: not a copy of the root -- it carries the job reference.
    File.write(File.join(files, 'agent.chat'),
               "system: harness\nuser: hi\nassistant: done\n" \
               "user: go\nmeta: job=#{job}\nassistant: done\n")

    root_run = ChatAnalyst.job(:live_chats, {file: chat}).run
    root_paths = root_run.keys.collect { |k| ChatAnalyst::Ids.unescape_path(k) }

    transcript = File.join(files, 'agent.chat')
    assert_include root_paths, transcript,
                   'the top-level agent transcript must be listed from a chat root'
    assert_include root_paths, File.join(job_files, 'agent.chat'),
                   'the referenced job log chat must be reached'
    assert_include root_paths, File.join(job_files, 'ask.society', 'worker_child.chat'),
                   'the referenced job society chat must be reached'

    # Equivalence with the explicit-sidecar invocation: the sidecar-rooted
    # working set is unchanged by the core patch, and the chat-rooted set is
    # exactly that set plus the root file.
    sidecar_run = ChatAnalyst.job(:live_chats, fresh_id('sidecar-root'),
                                  {file: transcript}).run
    sidecar_paths = sidecar_run.keys.collect { |k| ChatAnalyst::Ids.unescape_path(k) }
    assert_equal root_paths.length, sidecar_paths.length + 1
    assert_equal (sidecar_paths + [chat]).sort, root_paths.sort
  end

  def test_live_chats_rejects_missing_file
    assert_raise(ParameterException) do
      ChatAnalyst.job(:live_chats, {file: File.join(@dir, 'nope.chat')}).run
    end
  end

  # --- live_chats: in-flight delegations through transient .jobs ---------

  def test_live_chats_finds_in_flight_jobs_with_source_jobs
    with_fixture_job_bases do |base|
      job = fixture_job_root
      files = job + '.files'
      save_file = File.join(files, 'agent.chat')

      child_short = 'Cortex/continue/Default_live_child'
      child, child_files = fixture_delegated_job(base, child_short, 'child_agent.chat')
      jobs_file = write_jobs_file(save_file, [child_short])
      # the writer's derivation: first '.chat' sub'd out + '.jobs'
      assert_equal File.join(files, 'agent.jobs'), jobs_file.sub(/\.chat\.jobs\z/, '') if false

      result = ChatAnalyst.job(:live_chats, fresh_id('inflight'), {file: job}).run

      child_chat = File.join(child_files, 'child_agent.chat')
      child_key = ChatAnalyst::Ids.chat_id(child_chat)
      assert result.keys.include?(child_key), "delegated child chat not found: #{result.keys.inspect}"
      entry = row_for(result, child_key)
      assert_equal 'jobs', entry['source']
      # jobs entries carry the transient marker they were found through
      assert_equal ChatAnalyst::Ids.escape_path(jobs_file), entry['jobs_file']
      # the parent's own chat is still the provenance-sourced entry
      parent_row = row_for(result, ChatAnalyst::Ids.chat_id(save_file))
      assert_equal 'provenance', parent_row['source']
      assert_equal '\\N', parent_row['jobs_file']
    end
  end

  def test_live_chats_jobs_file_written_without_trailing_newline_is_parsed
    with_fixture_job_bases do |base|
      chat = File.join(@dir, 'solo.chat')
      File.write(chat, "user: s\n")
      child_short = 'W/ask/Default_nl'
      _child, child_files = fixture_delegated_job(base, child_short, 'worker.chat')

      jobs_file = write_jobs_file(chat, [child_short])
      assert_no_match(/\n\z/, Open.read(jobs_file), 'writer emits no trailing newline')

      result = ChatAnalyst.job(:live_chats, fresh_id('nl'), {file: chat}).run
      paths = result.keys.collect { |k| ChatAnalyst::Ids.unescape_path(k) }
      assert paths.include?(File.join(child_files, 'worker.chat'))
      worker_key = result.keys.detect { |k| k.end_with?('worker.chat') }
      assert_equal 'jobs', row_for(result, worker_key)['source']
    end
  end

  def test_live_chats_follows_jobs_of_jobs_up_to_depth_two
    with_fixture_job_bases do |base|
      job = fixture_job_root
      files = job + '.files'
      save_file = File.join(files, 'agent.chat')

      child_short = 'Cortex/continue/Default_d1'
      _child, child_files = fixture_delegated_job(base, child_short, 'child_agent.chat')
      write_jobs_file(save_file, [child_short])

      # depth 2: the child chat is itself delegating (jobs-of-jobs)
      grand_short = 'ScoutCoder/plan/Default_d2'
      _grand, grand_files = fixture_delegated_job(base, grand_short, 'grand.chat')
      write_jobs_file(File.join(child_files, 'child_agent.chat'), [grand_short])

      # depth 3: the grand chat delegates further - must NOT be followed
      deep_short = 'Deep/ask/Default_d3'
      _deep, deep_files = fixture_delegated_job(base, deep_short, 'deep.chat')
      write_jobs_file(File.join(grand_files, 'grand.chat'), [deep_short])

      result = ChatAnalyst.job(:live_chats, fresh_id('depth'), {file: job}).run
      paths = result.keys.collect { |k| ChatAnalyst::Ids.unescape_path(k) }

      assert paths.include?(File.join(child_files, 'child_agent.chat')), 'depth 1 not followed'
      assert paths.include?(File.join(grand_files, 'grand.chat')), 'jobs-of-jobs (depth 2) not followed'
      assert !paths.include?(File.join(deep_files, 'deep.chat')), 'depth 3 must not be followed'

      jobs_keys = result.keys.select { |k| row_for(result, k)['source'] == 'jobs' }
      assert_equal 2, jobs_keys.length
      assert jobs_keys.all? { |k| ChatAnalyst::Ids.unescape_path(row_for(result, k)['jobs_file']).end_with?('.jobs') }
    end
  end

  def test_live_chats_jobs_failure_modes_never_raise
    with_fixture_job_bases do |base|
      job = fixture_job_root
      files = job + '.files'
      save_file = File.join(files, 'agent.chat')

      # a real child, to prove the good entry survives the broken siblings
      good_short = 'W/ask/Default_good'
      _good, good_files = fixture_delegated_job(base, good_short, 'good.chat')

      # missing job dir: reference to a job that never existed
      missing_short = 'Nowhere/None/Default_ghost'
      # unresolvable short_path: resolves to a base without .info/files
      FileUtils.mkdir_p(File.join(base, 'Broken', 'run'))
      broken_short = 'Broken/run/Default_bare'

      jobs_file = write_jobs_file(save_file, [good_short, missing_short, broken_short])

      result = ChatAnalyst.job(:live_chats, fresh_id('broken'), {file: job}).run
      paths = result.keys.collect { |k| ChatAnalyst::Ids.unescape_path(k) }
      assert paths.include?(File.join(good_files, 'good.chat')), 'good reference must survive'
      assert paths.none? { |p| p.include?('ghost') }, 'missing job dir must be skipped'
      assert paths.none? { |p| p.include?('Default_bare') }, 'non-candidate step must be skipped'

      # the .jobs file disappearing between discovery and read (it is
      # transient: removed in the ensure after Workflow.produce)
      File.delete(jobs_file)
      result2 = ChatAnalyst.job(:live_chats, fresh_id('vanished'), {file: job}).run
      assert result2.keys.none? { |k| row_for(result2, k)['source'] == 'jobs' }
    end
  end

  def test_live_chats_jobs_glob_seeding_finds_unreferenced_jobs_files
    with_fixture_job_bases do |base|
      job = fixture_job_root
      files = job + '.files'
      # a society chat carrying a .jobs file NOT derived from any save_file
      # in scope must still seed the walk through the files-dir glob
      child_short = 'W/ask/Default_globbed'
      _child, child_files = fixture_delegated_job(base, child_short, 'globbed.chat')
      society_chat = File.join(files, 'ask.society', 'child.chat')
      write_jobs_file(society_chat, [child_short])

      result = ChatAnalyst.job(:live_chats, fresh_id('glob-seed'), {file: job}).run
      key = result.keys.detect { |k| k.end_with?('globbed.chat') }
      assert_not_nil key, 'child of a society chat delegation not found'
      assert_equal 'jobs', row_for(result, key)['source']
    end
  end

  def test_live_chats_provenance_wins_over_jobs_for_same_chat
    with_fixture_job_bases do |base|
      # One session: parent job whose save chat lists a child job in flight;
      # the SAME child chat is also reachable by settled provenance because
      # its receipt (meta: job=...) already landed in the parent chat.
      job = fixture_job_root
      files = job + '.files'
      save_file = File.join(files, 'agent.chat')

      child_short = 'W/ask/Default_dup'
      child, child_files = fixture_delegated_job(base, child_short, 'dup.chat')

      # settled receipt: the child job is recorded in the parent transcript
      File.open(save_file, 'a') do |io|
        io.puts "meta: job=#{child_short}"
        io.puts "assistant: delegated"
      end

      write_jobs_file(save_file, [child_short])

      result = ChatAnalyst.job(:live_chats, fresh_id('precedence'), {file: job}).run

      dup_key = ChatAnalyst::Ids.chat_id(File.join(child_files, 'dup.chat'))
      assert result.keys.count(dup_key) == 1, 'the same chat must not be reported twice'
      assert_equal 'provenance', row_for(result, dup_key)['source'],
                   'a chat found by traversal is not duplicated as :jobs'
      assert_equal result.keys.length, result.keys.uniq.length
    end
  end

  # --- inbox_state ------------------------------------------------------

  def test_inbox_state_is_an_index_without_bodies
    chat = fixture_chat_with_inbox
    state = ChatAnalyst.job(:inbox_state, {file: chat}).run

    assert_equal 'Note', state.key_field
    assert_equal %w[state name mtime size], state.fields
    assert_nil state.options[:cast]

    # keys are the absolute ESCAPED note paths; root_path carries the
    # escaped save file
    assert_equal ChatAnalyst::Ids.escape_path(chat), state.root_path
    pending_key = ChatAnalyst::Ids.escape_path(File.join(Chat.inbox_dir(chat), 'a.md'))
    delivered_key = ChatAnalyst::Ids.escape_path(File.join(Chat.inbox_removed_dir(chat), 'old.md'))
    assert state.keys.include?(pending_key)
    assert state.keys.include?(delivered_key)

    pending = row_for(state, pending_key)
    assert_equal 'pending', pending['state']
    assert_equal 'a.md', pending['name']
    assert_equal 8, pending['size'].to_i
    assert Time.parse(pending['mtime'])
    assert pending['mtime'].match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/)

    delivered = row_for(state, delivered_key)
    assert_equal 'delivered', delivered['state']
    assert_equal 'old.md', delivered['name']

    # PIN (phase-3 behavior change): no note bodies anywhere in the table.
    # The bodies live in inbox_note now; the index never embeds them.
    assert state.to_s !~ /advice A/, 'pending body must not be embedded'
    assert state.to_s !~ /old advice/, 'delivered body must not be embedded'
  end

  def test_inbox_note_reads_bodies_and_round_trips
    chat = fixture_chat_with_inbox
    # pending body
    assert_equal 'advice A', ChatAnalyst.job(:inbox_note, {file: chat, name: 'a.md'}).run
    # delivered body
    assert_equal 'old advice', ChatAnalyst.job(:inbox_note, {file: chat, name: 'old.md'}).run

    # a posted note round-trips through the index + point read
    posted = ChatAnalyst.job(:post_inbox_advice,
                             {file: chat, message: 'round trip body', name: 'rt.md'}).run
    state = ChatAnalyst.job(:inbox_state, fresh_id('rt-index'), {file: chat}).run
    assert_equal ['rt.md'], state.keys.collect { |k| row_for(state, k)['name'] }
                              .select { |n| n == 'rt.md' }
    assert_equal 'round trip body', ChatAnalyst.job(:inbox_note, {file: chat, name: 'rt.md'}).run

    # error behaviour: missing note, path-like name, empty name
    assert_raise(ParameterException) do
      ChatAnalyst.job(:inbox_note, {file: chat, name: 'nope.md'}).run
    end
    assert_raise(ParameterException) do
      ChatAnalyst.job(:inbox_note, {file: chat, name: 'a/b.md'}).run
    end
    assert_raise(ParameterException) do
      ChatAnalyst.job(:inbox_note, {file: chat, name: '  '}).run
    end
    # a job root is rejected (point read of a chat save file's inbox)
    job = fixture_job_root
    assert_raise(ParameterException) do
      ChatAnalyst.job(:inbox_note, {file: job, name: 'a.md'}).run
    end
    posted
  end

  def test_inbox_state_per_save_file_inboxes_in_a_shared_files_dir
    # The inbox belongs to each SAVE FILE, not to the .files directory: two
    # agents writing in the same dir get two separate inboxes.
    files = File.join(@dir, 'conv.chat.files')
    FileUtils.mkdir_p(files)
    agent = File.join(files, 'agent.chat')
    worker = File.join(files, 'worker.chat')
    File.write(agent, "user: a\n")
    File.write(worker, "user: w\n")
    File.write(File.join(files, 'agent.inbox', 'only-agent.md') .tap { |p| FileUtils.mkdir_p(File.dirname(p)) }, 'for agent')
    File.write(File.join(files, 'worker.inbox', 'only-worker.md').tap { |p| FileUtils.mkdir_p(File.dirname(p)) }, 'for worker')

    agent_state = ChatAnalyst.job(:inbox_state, fresh_id('agent'), {file: agent}).run
    worker_state = ChatAnalyst.job(:inbox_state, fresh_id('worker'), {file: worker}).run

    agent_names = agent_state.keys.collect { |k| row_for(agent_state, k)['name'] }
    worker_names = worker_state.keys.collect { |k| row_for(worker_state, k)['name'] }
    assert_equal ['only-agent.md'], agent_names
    assert_equal ['only-worker.md'], worker_names
    assert_equal 'for agent',
                 ChatAnalyst.job(:inbox_note, {file: agent, name: 'only-agent.md'}).run
  end

  def test_inbox_state_multi_dot_and_extensionless_save_files
    # last extension only: a.b.chat -> a.b.inbox; extension-less stays whole
    multi = File.join(@dir, 'a.b.chat')
    File.write(multi, "user: m\n")
    File.write(File.join(@dir, 'a.b.inbox', 'n.md').tap { |p| FileUtils.mkdir_p(File.dirname(p)) }, 'multi')

    state = ChatAnalyst.job(:inbox_state, {file: multi}).run
    assert state.keys.include?(ChatAnalyst::Ids.escape_path(File.join(@dir, 'a.b.inbox', 'n.md')))
    assert_equal ['n.md'], state.keys.collect { |k| row_for(state, k)['name'] }
  end

  def test_inbox_state_missing_directories_are_empty
    chat = File.join(@dir, 'lonely.chat')
    File.write(chat, "user: l\n")
    state = ChatAnalyst.job(:inbox_state, {file: chat}).run

    assert_empty state.keys
    assert_equal 0, state.total
  end

  def test_inbox_state_rejects_job_root
    job = fixture_job_root
    assert_raise(ParameterException) do
      ChatAnalyst.job(:inbox_state, {file: job}).run
    end
  end

  def test_inbox_state_skips_a_note_consumed_between_listing_and_reading
    # The inbox is read while a live inference may consume it: a note that
    # disappears between the glob and the open is a race the report must
    # resolve by skipping the entry (guarded per-entry read), not by raising.
    chat = fixture_chat_with_inbox
    inbox = Chat.inbox_dir(chat)

    $inbox_race_armed = true
    ChatAnalyst.step_module.prepend(Module.new do
      define_method(:inbox_note_row) do |path, state|
        # simulate the consumer picking the second file up while the first
        # is being read (glob order is a.md, then race-*.md sorted after);
        # armed only inside this test so the prepend is inert afterwards
        target = File.join(File.dirname(path), 'z-vanishing.md')
        File.delete(target) if $inbox_race_armed && File.exist?(target)
        super(path, state)
      end
    end)

    File.write(File.join(inbox, 'z-vanishing.md'), 'will be consumed mid-report')
    begin
      state = ChatAnalyst.job(:inbox_state, fresh_id('race'), {file: chat}).run
    ensure
      $inbox_race_armed = false
    end

    pending_names = state.keys.collect { |k| row_for(state, k)['name'] }
                          .select { |name| row_for(state, state.keys.detect { |kk| row_for(state, kk)['name'] == name })['state'] == 'pending' }
    assert_equal ['a.md'], pending_names,
                  'the vanished note is skipped, not reported and not fatal'
  end

  # --- post_inbox_advice ------------------------------------------------

  def test_post_creates_note_and_it_appears_pending
    chat = fixture_chat_with_inbox
    posted = ChatAnalyst.job(:post_inbox_advice,
                             {file: chat, message: 'check the temp files', name: 'n1.md'}).run

    assert_equal 'Posted', posted.key_field
    assert_equal %w[name save_file inbox_dir size], posted.fields
    assert_equal 1, posted.total

    target = File.join(Chat.inbox_dir(chat), 'n1.md')
    assert_equal [ChatAnalyst::Ids.escape_path(target)], posted.keys
    row = row_for(posted, posted.keys.first)
    assert_equal 'n1.md', row['name']
    assert_equal ChatAnalyst::Ids.escape_path(chat), row['save_file']
    assert_equal ChatAnalyst::Ids.escape_path(Chat.inbox_dir(chat)), row['inbox_dir']
    assert_equal 'check the temp files'.length.to_s, row['size']
    assert File.file?(target)
    assert_equal 'check the temp files', Open.read(target)

    state = ChatAnalyst.job(:inbox_state, fresh_id('after-post'), {file: chat}).run
    names = state.keys.collect { |k| row_for(state, k)['name'] }
    assert names.include?('n1.md')
    assert_equal 'check the temp files',
                 ChatAnalyst.job(:inbox_note, {file: chat, name: 'n1.md'}).run
  end

  def test_post_default_name_is_timestamped
    chat = fixture_chat_with_inbox
    posted = ChatAnalyst.job(:post_inbox_advice, {file: chat, message: 'auto named'}).run
    name = row_for(posted, posted.keys.first)['name']
    assert_match(/\A\d{8}-\d{6}-advice\.md\z/, name)
    assert File.file?(File.join(Chat.inbox_dir(chat), name))
  end

  def test_post_rejects_bad_inputs
    chat = fixture_chat_with_inbox
    assert_raise(ParameterException) do
      ChatAnalyst.job(:post_inbox_advice, {file: chat, message: '   '}).run
    end
    assert_raise(ParameterException) do
      ChatAnalyst.job(:post_inbox_advice, {file: chat, message: 'x', name: 'a/b.md'}).run
    end
    assert_raise(ParameterException) do
      ChatAnalyst.job(:post_inbox_advice, {file: chat, message: 'already there', name: 'a.md'}).run
    end
  end

  def test_post_rejects_reserved_abort_name
    chat = fixture_chat_with_inbox
    # 'abort' is INBOX_ABORT_FILE: consuming it aborts the live inference
    # and its content never reaches the model, so advice must not use it.
    assert_equal 'abort', Chat::INBOX_ABORT_FILE

    error = assert_raise(ParameterException) do
      ChatAnalyst.job(:post_inbox_advice, {file: chat, message: 'please stop', name: 'abort'}).run
    end
    assert_match(/reserved/i, error.message)
    assert error.message.include?('abort')
    assert !File.exist?(File.join(Chat.inbox_dir(chat), 'abort')),
           'rejection happens before anything is written'
  end

  def test_post_into_a_save_file_sidecar_inbox
    # posting targets the inbox of the SAVE FILE passed, sibling of it in
    # its own directory (agent.chat -> agent.inbox)
    files = File.join(@dir, 'conv.chat.files')
    FileUtils.mkdir_p(files)
    agent = File.join(files, 'agent.chat')
    File.write(agent, "user: a\n")

    posted = ChatAnalyst.job(:post_inbox_advice,
                             {file: agent, message: 'watch the glob', name: 'note.md'}).run
    assert_equal [ChatAnalyst::Ids.escape_path(File.join(files, 'agent.inbox', 'note.md'))],
                 posted.keys

    state = ChatAnalyst.job(:inbox_state, fresh_id('sidecar'), {file: agent}).run
    assert_equal ['note.md'], state.keys.collect { |k| row_for(state, k)['name'] }
  end

  # --- end to end against scout-ai itself -------------------------------

  def test_end_to_end_post_delivers_through_chat_inbox
    chat = File.join(@dir, 'e2e.chat')
    File.write(chat, "user: start\n")

    advice = 'stop repeating the same probe; check the save_file shape'
    posted = ChatAnalyst.job(:post_inbox_advice, {file: chat, message: advice}).run
    posted_name = row_for(posted, posted.keys.first)['name']

    # still pending before the real inference
    before = ChatAnalyst.job(:inbox_state, fresh_id('before'), {file: chat}).run
    assert_equal [posted_name], before.keys.collect { |k| row_for(before, k)['name'] }

    # the strategy: same call scout-ai makes on every real inference
    prepared = Chat.inbox([{role: 'user', content: 'x'}], save_file: chat)

    # the posted content was appended as a user message, after the transcript
    injected = prepared.select { |m| m[:role] == 'user' && m[:content] == advice }
    assert_equal 1, injected.length
    assert_equal 'x', prepared.first[:content]

    # the note moved into the sibling .inbox_removed (delivery record, name kept)
    assert !File.exist?(File.join(Chat.inbox_dir(chat), posted_name))
    removed = File.join(Chat.inbox_removed_dir(chat), posted_name)
    assert File.file?(removed)
    assert_equal advice, Open.read(removed)

    after = ChatAnalyst.job(:inbox_state, fresh_id('after'), {file: chat}).run
    after_states = after.keys.collect { |k| row_for(after, k)['state'] }
    assert_empty after_states & ['pending']
    assert_equal [posted_name], after.keys.collect { |k| row_for(after, k)['name'] }
    assert_equal advice, ChatAnalyst.job(:inbox_note, {file: chat, name: posted_name}).run

    # consume-once: a second real inference appends nothing new
    second = Chat.inbox([{role: 'user', content: 'y'}], save_file: chat)
    assert second.none? { |m| m[:content] == advice }
  end

  def test_end_to_end_delivery_never_persists_into_the_transcript
    chat = File.join(@dir, 'e2e-transcript.chat')
    File.write(chat, "user: start\n")

    ChatAnalyst.job(:post_inbox_advice,
                    {file: chat, message: 'injected only', name: 't.md'}).run
    Chat.inbox([{role: 'user', content: 'q'}], save_file: chat)

    # the save_file (transcript) keeps exactly what it had: the injected
    # advice lives only in the returned prompt and the .inbox_removed record
    transcript = Open.read(chat)
    assert_equal "user: start\n", transcript
    assert transcript !~ /injected only/
  end

  def test_end_to_end_delivery_of_save_file_inbox_in_sidecar
    # the agent save_file inside a .files sidecar: delivery consumes from
    # agent.inbox and records into agent.inbox_removed, per save file
    files = File.join(@dir, 'conv.chat.files')
    FileUtils.mkdir_p(files)
    agent = File.join(files, 'agent.chat')
    File.write(agent, "user: a\n")

    posted = ChatAnalyst.job(:post_inbox_advice,
                             {file: agent, message: 'sidecar advice', name: 's.md'}).run

    prepared = Chat.inbox([{role: 'user', content: 'base'}], save_file: agent)
    assert prepared.any? { |m| m[:role] == 'user' && m[:content] == 'sidecar advice' }

    assert !File.exist?(File.join(files, 'agent.inbox', 's.md'))
    removed = File.join(files, 'agent.inbox_removed', 's.md')
    assert File.file?(removed)
    assert_equal 'sidecar advice', Open.read(removed)

    state = ChatAnalyst.job(:inbox_state, fresh_id('e2e-sidecar'), {file: agent}).run
    assert_empty state.keys.collect { |k| row_for(state, k)['state'] } & ['pending']
    assert_equal ['s.md'], state.keys.collect { |k| row_for(state, k)['name'] }
  end
end
