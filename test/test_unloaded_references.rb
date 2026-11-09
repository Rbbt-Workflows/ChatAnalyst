$LOAD_PATH.unshift '.'
require 'test/test_helper'

# Minimal revision phase 2 (plan step 6): unloaded_references enrichment.
# Entries are {kind, path, error, via} where via records the reference that
# enqueued the failing node ({from_kind, from_path, context}); the root
# itself carries via: nil.  Both overview and timeline share the traversal
# shape, so the pin covers both surfaces.
#
# Fixture rationale (verified by probe tmp/rev-phase2/probe_unload13.rb):
# a chat-typed referenced job whose result file is unreadable (mode 000)
# makes the JOB branch raise EACCES inside the traversal while the parent
# chat still loads — the minimal deterministic broken reference.
class TestUnloadedReferencesEnrichment < Test::Unit::TestCase
  def setup
    @dir = Dir.mktmpdir('chat_analyst_unloaded')
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  # A referenced chat-typed job whose result file cannot be read: the parent
  # chat's graph discovers the reference, the job node then fails to load.
  def chat_with_broken_job_reference
    job = File.join(@dir, 'J', 'ask', 'Default_j')
    FileUtils.mkdir_p(File.dirname(job))
    File.write(job, "user: u\nassistant: a\n")
    File.write(job + '.info', {type: 'chat', status: 'done'}.to_json)
    File.chmod(0o000, job)
    chat = File.join(@dir, 'root.chat')
    File.write(chat, "user: x\nmeta: job=#{job}\nassistant: y\n")
    [chat, job]
  end

  def restore(job)
    File.chmod(0o644, job) if File.exist?(job)
  end

  def test_overview_unloaded_reference_carries_kind_and_via
    chat, job = chat_with_broken_job_reference
    begin
      overview = ChatAnalyst.overview(chat)

      entries = overview[:unloaded_references]
      assert entries, 'the unloadable job must be reported'
      entry = entries.find { |candidate| candidate[:path] == job }
      assert entry, "entry for the broken job: #{entries.inspect[0, 200]}"
      assert_equal :job, entry[:kind]
      assert_match(/Permission denied|Error/, entry[:error].to_s)
      assert_equal({from_kind: :chat, from_path: chat, context: 'job reference'},
                   entry[:via].slice(:from_kind, :from_path, :context))

      # The chat that carried the reference still loaded fine.
      assert overview[:chats].find { |record| record[:path] == chat }
    ensure
      restore(job)
    end
  end

  def test_timeline_unloaded_reference_carries_kind_and_via
    chat, job = chat_with_broken_job_reference
    begin
      timeline = ChatAnalyst.timeline(chat)

      entry = timeline[:unloaded_references].find { |candidate| candidate[:path] == job }
      assert entry
      assert_equal :job, entry[:kind]
      assert_equal({from_kind: :chat, from_path: chat, context: 'job reference'},
                   entry[:via].slice(:from_kind, :from_path, :context))
    ensure
      restore(job)
    end
  end

  def test_unloadable_root_reports_nil_via
    # The ROOT job node itself fails: same unreadable-result fixture used
    # directly as the root, so the failure has no originating reference.
    job = File.join(@dir, 'R', 'ask', 'Default_r')
    FileUtils.mkdir_p(File.dirname(job))
    File.write(job, "user: u\nassistant: a\n")
    File.write(job + '.info', {type: 'chat', status: 'done'}.to_json)
    File.chmod(0o000, job)
    begin
      overview = ChatAnalyst.overview(job)
      entries = overview[:unloaded_references]
      assert entries, 'the corrupt root must be reported'
      assert_nil entries.first[:via], 'the root has no originating reference'
      assert_equal :job, entries.first[:kind]
      assert_empty overview[:chats]
      assert_empty overview[:jobs]
    ensure
      restore(job)
    end
  end
end
