$LOAD_PATH.unshift '.'
require 'test/test_helper'
require 'test/scout/agent_meta_fixtures'

# One fail-fast pin per retired adapter name (work order 5c), separate from
# the suites that already pin chat_report/message_index/message_content.
class TestRetiredAdaptersFailFast < Test::Unit::TestCase
  include ChatAnalystFixtures
  def test_extract_chat_range_is_gone
    Dir.mktmpdir do |dir|
      chat = write_chat(dir, 'a.chat', "user: x\nassistant: y\n")
      error = assert_raise(TaskNotFound) do
        ChatAnalyst.job(:extract_chat_range, {file: chat, start: 0, end: 0}).run
      end
      assert_match(/extract_chat_range/, error.message)
    end
  end
end
