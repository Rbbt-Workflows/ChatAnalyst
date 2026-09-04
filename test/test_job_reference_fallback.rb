$LOAD_PATH.unshift '.'
require File.expand_path(File.join(File.dirname(__FILE__), 'test_helper'))

# rev3 step 2: Chat.load_job_reference must accept Scout's own jobs base
# (~/.scout/var/jobs, i.e. Scout.var.jobs) as a fallback resolution base after
# Step.load and after the classic ~/.rbbt/var/jobs base, so receipt references
# written by Scout workflows (Cortex/continue, Planned/...) resolve even when
# the analysis runs outside the workflow directory.  These tests are hermetic:
# the fallback base list is pointed at a tmp fixture tree, never at the real
# ~/.scout or ~/.rbbt.  On pre-fix core code every test except the graceful
# nonexistence one must fail (demonstrated in tmp/rev3/step2/suite-pre.log).
class TestJobReferenceFallbackBases < Test::Unit::TestCase
  def with_fixture_bases
    rbbt_base = File.join(@__test_dir, 'rbbt-jobs')
    scout_base = File.join(@__test_dir, 'scout-jobs')
    FileUtils.mkdir_p(rbbt_base)
    FileUtils.mkdir_p(scout_base)

    original = (Chat.method(:job_reference_fallback_bases) rescue nil)
    Chat.singleton_class.class_eval do
      define_method(:job_reference_fallback_bases) do
        [File.expand_path(rbbt_base), File.expand_path(scout_base)]
      end
    end

    Dir.chdir(@__test_dir) { yield }
  ensure
    if original
      # restore the shipped definition by re-binding the captured method
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

  def test_returns_rbbt_and_scout_bases_in_order
    bases = Chat.job_reference_fallback_bases
    assert_include bases, File.expand_path('~/.rbbt/var/jobs')
    assert_include bases, Scout.var.jobs.find.to_s
    assert_equal File.expand_path('~/.rbbt/var/jobs'), bases.first,
                 'Step.load must be tried first, then ~/.rbbt/var/jobs, then the Scout base'
  end

  def test_resolves_reference_only_present_in_scout_base
    with_fixture_bases do
      ref = 'Fake/continue/Child_chatref_1.chat'
      path = File.join(@__test_dir, 'scout-jobs', ref)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "# fake child payload\n")

      step = Chat.load_job_reference(ref)
      assert_not_nil step, 'reference present only in the Scout base must resolve'
      assert step.path.to_s.end_with?(ref), "expected resolution under the scout base, got #{step.path}"
      assert File.exist?(step.path.to_s), "resolved path must exist: #{step.path}"
    end
  end

  def test_resolves_chat_extension_and_info_only_references
    with_fixture_bases do
      ref = 'Fake/continue/Child_chatref_2.chat'
      path = File.join(@__test_dir, 'scout-jobs', ref)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path + '.info', "# info-only job sidecar\n")

      step = Chat.load_job_reference(ref)
      assert_not_nil step, 'info-only reference must resolve through the Scout base'
      assert File.exist?(step.path.to_s + '.info'),
             "info-only reference must be accepted: #{step.path}"
    end
  end

  def test_nonexistent_reference_stays_unresolved_without_raising
    with_fixture_bases do
      ref = 'Fake/continue/Nosuch_chatref_9.chat'
      step = nil
      assert_nothing_raised do
        step = Chat.load_job_reference(ref)
      end
      assert !(step && File.exist?(step.path.to_s)),
             'nonexistent reference must never resolve to an existing path'
    end
  end

  def test_rbbt_base_keeps_priority_over_scout_base
    with_fixture_bases do
      ref = 'Fake/continue/Child_chatref_1.chat'
      rbbt_path = File.join(@__test_dir, 'rbbt-jobs', ref)
      scout_path = File.join(@__test_dir, 'scout-jobs', ref)
      [rbbt_path, scout_path].each do |p|
        FileUtils.mkdir_p(File.dirname(p))
        File.write(p, "# copy at #{p}\n")
      end

      step = Chat.load_job_reference(ref)
      assert_not_nil step
      assert step.path.to_s.start_with?(File.join(@__test_dir, 'rbbt-jobs')),
             "rbbt base must win when both hold the ref, got #{step.path}"
    end
  end
end
