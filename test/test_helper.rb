require 'test/unit'
require 'tmpdir'
require 'json'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'timeout'

$LOAD_PATH.unshift(File.expand_path(File.join(File.dirname(__FILE__), '..')))
require 'workflow'

class Test::Unit::TestCase
  # Clean, deterministic Scout state per test: no progress bars, an isolated
  # Workflow job directory, and a clean persistence layer so ChatAnalyst tasks
  # never read or write outside the test tmpdir.
  setup do
    @__test_dir = Dir.mktmpdir('chatanalyst-test')
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
