require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\\1')

class TestChatTimeline < Test::Unit::TestCase
  def fixture(dir)
    write_chat(dir, 'timeline.chat', <<~CHAT)
      user: inspect
      meta: pt=1 ct=1 tt=2 inference_id=p1 timestamp=2026-10-08T10:00:00Z reas=Inspect the implementation and identify the related file carefully.
      function_call: {"name":"search","arguments":{"path":"~/repo"},"id":"s1"}
      function_call_output: {"name":"search","content":"private output must not appear","id":"s1"}
      assistant: completed
      meta: pt=1 ct=1 tt=2 inference_id=p2 timestamp=2026-10-08T10:01:00Z reas=Review the tests and confirm the behavior with evidence.
      function_call: {"name":"read","arguments":{"path":"~/repo/file.rb"},"id":"r1"}
      function_call_output: {"name":"read","content":"secret output","id":"r1"}
      assistant: reviewed
      meta: pt=1 ct=1 tt=2 inference_id=p3 timestamp=2026-10-08T10:20:00Z reas=Summarize the verified outcome concisely for the user.
      function_call: {"name":"bash","arguments":{"cmd":"echo secret"},"id":"b1"}
      function_call_output: {"name":"bash","content":"secret stdout","id":"b1"}
      assistant: done
    CHAT
  end

  def test_default_is_compact_overview_and_only_elapsed_gap_splits_bursts
    TmpFile.with_dir do |dir|
      result = ChatAnalyst.job(:chat_timeline, {file: fixture(dir)}).run
      assert_equal :overview, result[:mode]
      assert_equal 2, result[:bursts].length
      assert_equal 3, result[:summary][:tool_events]
      refute result.key?(:segments)
      refute result.key?(:events)
      refute result.key?(:phases)

      refute result.to_s.include?('secret')
      refute result.to_s.include?('/var/jobs/')
      refute result.to_s.include?('~/repo')
      refute result.to_s.include?('~/repo/file.rb')
      assert result[:bursts].all? { |burst| burst[:breakpoint_signals].is_a?(Array) }
    end
  end

  def test_detail_returns_only_requested_bursts_with_navigation_metadata
    TmpFile.with_dir do |dir|
      result = ChatAnalyst.job(:chat_timeline, {file: fixture(dir), burst_ids: ["2"]}).run
      assert_equal :detail, result[:mode]
      assert_equal ["2"], result[:selected_burst_ids]
      assert_equal [2], result[:bursts].map { |burst| burst[:id] }
      segment = result[:bursts].first[:segments].first
      assert segment[:calls].first[:call_address].include?('#')
      assert segment[:reasoning].key?(:fingerprint)
      assert segment[:resources].all? { |resource| resource[:kind] == :path && !resource.key?(:value) }
      refute segment[:reasoning].key?(:preview)
      refute result.to_s.include?('secret')
      refute result.to_s.include?('/var/jobs/')
      refute result.to_s.include?('~/repo')
      refute result.to_s.include?('~/repo/file.rb')
      refute result.key?(:phases)
    end
  end

  def test_path_like_conversation_is_not_exposed_but_opaque_id_is_preserved
    TmpFile.with_dir do |dir|
      path = write_chat(dir, 'conversation.chat', <<~CHAT)
        user: delegate
        function_call: {"name":"cortex_continue","arguments":{"conversation":"~/repo/file.rb"},"id":"c1"}
        function_call_output: {"name":"cortex_continue","content":"done","id":"c1"}
        function_call: {"name":"cortex_continue","arguments":{"conversation":"ResearchThread"},"id":"c2"}
        function_call_output: {"name":"cortex_continue","content":"done","id":"c2"}
      CHAT
      result = ChatAnalyst.job(:chat_timeline, {file: path, burst_ids: ['120']}).run
      serialized = result.to_s
      refute serialized.include?('~/repo/file.rb')
      # Opaque IDs survive the same filter used for conversation selectors.
      assert_equal 'ResearchThread', ChatAnalyst.helper(:timeline_public_identifier, 'ResearchThread')
    end
  end

  def test_rendered_detail_sanitizes_path_like_selector_values_but_keeps_opaque_ids
    TmpFile.with_dir do |dir|
      path = write_chat(dir, 'selectors.chat', <<~CHAT)
        user: delegate
        function_call: {"name":"cortex_continue","arguments":{"agent":"repo/Worker","conversation":"repo/private"},"id":"c1"}
        function_call_output: {"name":"cortex_continue","content":"done","id":"c1"}
        function_call: {"name":"cortex_continue","arguments":{"agent":"Worker","conversation":"ResearchThread"},"id":"c2"}
        function_call_output: {"name":"cortex_continue","content":"done","id":"c2"}
      CHAT
      result = ChatAnalyst.job(:chat_timeline, {file: path, burst_ids: ['1']}).run
      assert_equal :detail, result[:mode]
      assert_equal 1, result[:bursts].length
      assert_equal 2, result[:bursts].first[:segments].first[:calls].length
      refute result.to_s.include?('repo/private')
      refute result.to_s.include?('repo/Worker')
      assert result.to_s.include?('ResearchThread')
      assert result.to_s.include?('Worker')
    end
  end

  def test_unknown_burst_ids_return_empty_details
    TmpFile.with_dir do |dir|
      result = ChatAnalyst.job(:chat_timeline, {file: fixture(dir), burst_ids: ["999"]}).run
      assert_equal :detail, result[:mode]
      assert_equal [], result[:bursts]
    end
  end
end
