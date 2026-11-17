$LOAD_PATH.unshift '.'
require 'test/test_helper'
require 'fileutils'
require 'json'

# Bout 6 acceptance: chat_live_report (contract 2F, NEW task) - serializes
# ChatAnalyst.live (the fail-soft wrapper), all four kinds pinned on real
# fixtures, KEPT SEPARATE from live_chats file discovery, no exception text.
class TestChatLiveReport < Test::Unit::TestCase
  include ChatAnalystFixtures

  def setup
    @__test_dir ||= File.expand_path(Scout.tmp.chatanalyst_test.to_s)
    FileUtils.mkdir_p(@__test_dir)
    @dir = File.join(@__test_dir, 'live_report')
    FileUtils.mkdir_p(@dir)
  end

  def wdir
    Workflow.directory.respond_to?(:find) ? Workflow.directory.find.to_s : Workflow.directory.to_s
  end

  # A running chat-typed job in the workflow jobs tree (the sidecar sees it
  # and step.type == 'chat', so kind=inference).
  def running_chat_job(short)
    job = File.join(wdir, short)
    FileUtils.mkdir_p(File.dirname(job))
    File.write(job, "user: child q\nassistant: child a\n")
    File.write(job + '.info', {status: 'running', pid: Process.pid, type: 'chat'}.to_json)
    job
  end

  # A running wrapper job (no type => chat_task false => workload_context).
  def running_wrapper_job(short)
    job = File.join(wdir, short)
    FileUtils.mkdir_p(File.dirname(job))
    File.write(job, 'x')
    File.write(job + '.info', {status: 'running', pid: Process.pid}.to_json)
    job
  end

  def test_serializes_the_wrapper_and_its_kinds
    save = write_chat(@dir, 'live.chat', "user: go\n")
    inference = running_chat_job('W/chatwork/Default_b6i')
    File.write(save.sub(/\.chat\z/, '') + '.jobs', "W/chatwork/Default_b6i\n")

    report = ChatAnalyst.job(:chat_live_report, 'b6r1', {file: save}).run
    assert_equal 'Entry', report.key_field
    assert_equal %w[kind path state status chat_task agent conversation source], report.fields
    assert_nil report.options[:cast]
    assert report.total >= 2

    # agreement with the module wrapper (cross-consumer pattern): the task
    # rows are exactly ChatAnalyst.live's entries, one per entry
    live = ChatAnalyst.live(save)
    assert_equal live[:entries].length, report.keys.length

    # the inference row: chat-typed running job, sidecar source
    inf_key = report.keys.detect { |k| k.include?('Default_b6i') }
    inf = report[inf_key]
    assert_equal 'inference', inf['kind']
    assert_equal 'running', inf['state']
    assert_equal 'running', inf['status']
    assert_equal 'true', inf['chat_task']
    assert_equal 'sidecar', inf['source']
    assert_equal ChatAnalyst::Ids.escape_path(inference), inf['path']

    # the agent-activity row: keyed by the ESCAPED path (empty reference)
    act_key = report.keys.detect { |k| ChatAnalyst::Ids.unescape_path(k).end_with?('live.chat') }
    act = report[act_key]
    assert_equal 'agent_activity', act['kind']
    assert_equal '\N', act['state']
    assert_equal '\N', act['status']
    assert_equal '\N', act['chat_task']
    assert_equal 'agent_view', act['source']

    # every row's kind is one of the four contract values
    assert report.keys.all? { |k| %w[inference workload_context agent_activity dangling_job].include?(report[k]['kind']) }

    # no-payload: no exception text rides along in state/status cells
    assert report.keys.all? { |k| %w[running waiting crashed finished \N].include?(report[k]['state']) }

    # root_path annotation carries the escaped root
    assert_equal ChatAnalyst::Ids.escape_path(save), report.root_path
  end

  def test_workload_context_and_dangling_job_kinds
    save = write_chat(@dir, 'w.chat', "user: q\n")
    wrapper = running_wrapper_job('W/wrap/Default_b6w')
    File.write(save.sub(/\.chat\z/, '') + '.jobs', "W/wrap/Default_b6w\n")

    report = ChatAnalyst.job(:chat_live_report, 'b6r2', {file: save}).run
    w = report[report.keys.detect { |k| k.include?('Default_b6w') }]
    assert_equal 'workload_context', w['kind']
    assert_equal 'false', w['chat_task']
    assert_equal ChatAnalyst::Ids.escape_path(wrapper), w['path']

    # dangling: the transcript carries the receipt but NO .jobs sidecar, so
    # the reference dangles in the agent view (job still running)
    save2 = write_chat(@dir, 'd.chat', "user: q\nmeta: job=#{wrapper}\nassistant: partial\n")
    report2 = ChatAnalyst.job(:chat_live_report, 'b6r3', {file: save2}).run
    dangling = report2.keys.detect do |k|
      report2[k]['kind'] == 'dangling_job'
    end
    assert_not_nil dangling, report2.keys.collect { |k| report2[k]['kind'] }.inspect
    row = report2[dangling]
    assert_equal 'running', row['state']
    assert row['source'].split('|').all? { |s| %w[sidecar agent_view society].include?(s) }
  end

  def test_kept_separate_from_live_chats_discovery
    # live_chats walks FILES (provenance traversal); chat_live_report walks
    # LIVE state. A running wrapper job with no chat log on disk appears in
    # chat_live_report and NOT in live_chats: the two surfaces stay separate.
    save = write_chat(@dir, 'sep.chat', "user: s\n")
    wrapper = running_wrapper_job('W/sep/Default_b6sep')
    File.write(save.sub(/\.chat\z/, '') + '.jobs', "W/sep/Default_b6sep\n")

    report = ChatAnalyst.job(:chat_live_report, 'b6s1', {file: save}).run
    chats = ChatAnalyst.job(:live_chats, 'b6s2', {file: save}).run

    report_refs = report.keys.collect { |k| ChatAnalyst::Ids.unescape_path(k) }
    assert report_refs.any? { |p| p.include?('Default_b6sep') }
    chat_paths = chats.keys.collect { |k| ChatAnalyst::Ids.unescape_path(k) }
    assert chat_paths.none? { |p| p.include?('Default_b6sep') },
           'live_chats must not absorb live-report entries into provenance traversal'
    assert chat_paths.any? { |p| p.end_with?('sep.chat') }
  end

  def test_fail_soft_and_missing_root
    # fail-soft: a bare save file with no sidecar/agents is an empty report,
    # not an error
    quiet = write_chat(@dir, 'quiet.chat', "user: hi\nassistant: done\n")
    report = ChatAnalyst.job(:chat_live_report, 'b6q', {file: quiet}).run
    assert report.keys.all? { |k| %w[agent_activity workload_context].include?(report[k]['kind']) }

    # missing root raises at the module layer (ChatAnalyst.live's
    # ArgumentError; the task surfaces it as the job error)
    assert_raise(ArgumentError) do
      ChatAnalyst.live(File.join(@dir, 'nope.chat'))
    end
  end
end
