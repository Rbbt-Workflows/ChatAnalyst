require 'test/unit'
$LOAD_PATH.unshift(File.expand_path(File.join(File.dirname(__FILE__), '..', 'lib')))
$LOAD_PATH.unshift(File.expand_path(File.dirname(__FILE__)))
# Load the project workflow so source files that declare Workflow DSL tasks
# can be required directly by tests using the repository test convention.
require File.expand_path('../workflow', __dir__)

require_relative 'scout/agent_meta_fixtures'

class Test::Unit::TestCase
  include ChatAnalystFixtures
  # Clean, deterministic Scout state per test: no progress bars, an isolated
  # Workflow job directory, and a clean persistence layer so ChatAnalyst tasks
  # never read or write outside the test tmpdir.
  setup do
    @__test_dir = Scout.tmp.chatanalyst_test
    Log::ProgressBar.default_severity = 0
    Persist.cache_dir = File.join(@__test_dir, 'cache')
    Persist::MEMORY_CACHE.clear
    Open.remote_cache_dir = File.join(@__test_dir, 'remote-cache')
    TmpFile.tmpdir = File.join(@__test_dir, 'tmpfiles')
    Workflow.directory = Path.setup(File.join(@__test_dir, 'var', 'jobs'))
  end

  teardown do
    Open.rm_rf @__test_dir if @__test_dir
  end
end

