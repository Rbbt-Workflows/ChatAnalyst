# Stage 5 tests: ChatAnalyst.tool_calls — call/output pairing, association to
# job and delegation references through the compact provenance graph, strict
# dedup identity, and range filtering.  Fixtures from test/scout/agent_meta_fixtures.rb.

require 'test_helper'

class TestChatAnalystToolCalls < Test::Unit::TestCase
  include ChatAnalystFixtures

  def teardown
    ChatAnalyst::TIMELINE_CACHE.clear
  end

  def test_calls_pair_by_index_with_tool_name_and_status
    TmpFile.with_dir do |dir|
      # Single-quoted squiggly heredoc: bytes pass through verbatim, so the
      # nested exit_status JSON inside `content` keeps its \" escaping in the
      # written chat file (an unquoted heredoc would eat the backslashes).
      path = write_chat(dir, 'pair.chat', <<~'CHAT')
        user: go
        function_call: {"name":"bash","arguments":{"cmd":"ls"},"id":"b1"}
        function_call_output: {"name":"bash","content":"ok","id":"b1"}
        function_call: {"name":"read","arguments":{"path":"x"},"id":"r1"}
        function_call_output: {"name":"read","content":"{\"exit_status\": 2, \"stderr\": \"not found\"}","id":"r1"}
        function_call: {"name":"ruby","arguments":{"code":"raise"},"id":"q1"}
        assistant: done
      CHAT
      result = ChatAnalyst.tool_calls(path)
      calls = result[:calls]
      assert_equal 3, calls.length
      assert_equal [1, 3, 5], calls.map { |call| call[:call_index] }
      assert_equal [2, 4, nil], calls.map { |call| call[:output_index] }
      assert_equal %w[bash read ruby], calls.map { |call| call[:tool] }
      assert calls[0][:status] != :error
      assert_equal :failure, calls[1][:status]
      assert_equal :unknown, calls[2][:status], 'call without any output is unknown, not error'
      # output character count, never the content itself
      assert_equal 2, calls[0][:output_characters]
    end
  end

  def test_timestamp_taken_from_output_when_available
    TmpFile.with_dir do |dir|
      path = write_chat(dir, 'ts.chat', <<~CHAT)
        user: go
        function_call: {"name":"bash","arguments":{"cmd":"ls"},"id":"b1"}
        function_call_output: {"name":"bash","content":"ok","id":"b1","start_timestamp":"2026-10-08T10:00:01Z","timestamp":"2026-10-08T10:00:02Z"}
        assistant: done
      CHAT
      call = ChatAnalyst.tool_calls(path)[:calls].first
      assert_equal '2026-10-08T10:00:02Z', call[:timestamp]
    end
  end

  def test_receipt_job_reference_anchored_at_outer_output_index
    TmpFile.with_dir do |dir|
      worker = make_job(dir, 'Worker/ask/Default_w', logs: {'agent.chat' => "user: work\nassistant: done\n"})
      parent = write_chat(dir, 'parent.chat',
        receipt_chat_text('a1' => [meta_receipt("job=#{worker}")]))
      calls = ChatAnalyst.tool_calls(parent)[:calls]
      assert_equal 1, calls.length
      call = calls.first
      assert_equal 'ask', call[:tool]
      assert_equal 2, call[:output_index], 'receipt ref anchors at the outer function_call_output'
      assert_equal [worker], call[:jobs]
      # ask delegation name is recorded AND the materialized job stays a path:
      # the two relations are kept distinct on the same call record.
      assert_equal 'Worker#default', call[:delegation_target]
      assert call[:delegated]
    end
  end

  def test_ask_without_job_is_a_valid_delegation_entry
    TmpFile.with_dir do |dir|
      parent = write_chat(dir, 'parent.chat',
        receipt_chat_text('a1' => [meta_receipt('pt=1 ct=1 tt=2 inference_id=w1')]))
      call = ChatAnalyst.tool_calls(parent)[:calls].first
      assert_equal 'Worker#default', call[:delegation_target]
      assert_equal [], call[:jobs]
      assert call[:delegated]
    end
  end

  def test_delegation_with_job_keeps_both_relations
    TmpFile.with_dir do |dir|
      parent, worker = fixture_cortex_continue(dir)
      calls = ChatAnalyst.tool_calls(parent)[:calls]
      assert_equal 1, calls.length
      call = calls.first
      assert_equal [worker], call[:jobs]
      assert_equal 'Worker#c1', call[:delegation_target]
      assert call[:delegated]
    end
  end

  def test_multiple_jobs_and_delegations_at_one_index
    TmpFile.with_dir do |dir|
      w1 = make_job(dir, 'W1/ask/Default_1')
      w2 = make_job(dir, 'W2/ask/Default_2')
      parent = write_chat(dir, 'parent.chat',
        receipt_chat_text('a1' => [meta_receipt("job=#{w1}"),
                                   meta_receipt("job=#{w2}"),
                                   meta_receipt('pt=1 inference_id=w3')]))
      call = ChatAnalyst.tool_calls(parent)[:calls].first
      assert_equal [w1, w2], call[:jobs].sort
      assert_equal 'Worker#default', call[:delegation_target]
      assert call[:delegated]
    end
  end

  def test_ordinary_response_creates_neither
    TmpFile.with_dir do |dir|
      path = write_chat(dir, 'plain.chat', "user: hi\nmeta: pt=1\nassistant: hello\n")
      calls = ChatAnalyst.tool_calls(path)[:calls]
      assert calls.empty?
    end
  end

  def test_two_identical_calls_without_ids_are_not_deduplicated
    TmpFile.with_dir do |dir|
      path = write_chat(dir, 'noid.chat', <<~CHAT)
        user: go twice
        function_call: {"name":"bash","arguments":{"cmd":"ls"}}
        function_call_output: {"name":"bash","content":"ok"}
        function_call: {"name":"bash","arguments":{"cmd":"ls"}}
        function_call_output: {"name":"bash","content":"ok"}
        assistant: done
      CHAT
      calls = ChatAnalyst.tool_calls(path)[:calls]
      assert_equal 2, calls.length, 'identical tool+arguments with NO call id stay two independent calls'
      assert_equal [1, 3], calls.map { |call| call[:call_index] }
    end
  end

  def test_two_identical_calls_with_same_id_marked_as_copies
    TmpFile.with_dir do |dir|
      path = write_chat(dir, 'copy.chat', <<~CHAT)
        user: go twice
        function_call: {"name":"bash","arguments":{"cmd":"ls"},"id":"b1"}
        function_call_output: {"name":"bash","content":"ok","id":"b1"}
        function_call: {"name":"bash","arguments":{"cmd":"ls"},"id":"b1"}
        function_call_output: {"name":"bash","content":"ok","id":"b1"}
        assistant: done
      CHAT
      calls = ChatAnalyst.tool_calls(path)[:calls]
      assert_equal 2, calls.length
      assert calls[1][:copy_of] == calls[0][:call_index], 'same tool+id+arguments marks the later one a copy'
      refute calls[0][:copy_of]
    end
  end

  def test_range_filtering
    TmpFile.with_dir do |dir|
      path = write_chat(dir, 'range.chat', <<~CHAT)
        user: go
        function_call: {"name":"bash","arguments":{"cmd":"ls"},"id":"b1"}
        function_call_output: {"name":"bash","content":"ok","id":"b1"}
        function_call: {"name":"read","arguments":{"path":"x"},"id":"r1"}
        function_call_output: {"name":"read","content":"ok","id":"r1"}
        assistant: done
      CHAT
      result = ChatAnalyst.tool_calls(path, first: 3, last: 3)
      assert_equal 1, result[:calls].length
      assert_equal 'read', result[:calls].first[:tool]
      assert_equal({first: 3, last: 3}, result.slice(:first, :last))

      assert_raises(ArgumentError) { ChatAnalyst.tool_calls(path, first: 9, last: 9) }
    end
  end

  def test_qualified_delegation_selectors_preserved
    TmpFile.with_dir do |dir|
      path = write_chat(dir, 'qual.chat', <<~CHAT)
        user: go
        function_call: {"name":"ask","arguments":{"agent":"Worker/ScoutCoder"},"id":"q1"}
        function_call_output: {"name":"ask","content":"ok","id":"q1","meta":#{[meta_receipt('pt=1 ct=1 tt=2 inference_id=q1')].to_json}}
        assistant: done
      CHAT
      call = ChatAnalyst.tool_calls(path)[:calls].first
      assert_equal 'Worker/ScoutCoder#default', call[:delegation_target]
    end
  end

  def test_no_loaded_objects_or_concatenated_identifiers_in_results
    TmpFile.with_dir do |dir|
      parent, = fixture_agent_job(dir)
      result = ChatAnalyst.tool_calls(parent)
      serializable = begin
                       JSON.generate(result)
                       true
                     rescue StandardError
                       false
                     end
      assert serializable, 'result is JSON-serializable'
      assert result[:calls].all? { |call| call[:jobs].nil? || call[:jobs].all? { |p| p.is_a?(String) } }
      assert result[:calls].none? { |call| call.key?(:call_address) || call.key?(:output_address) }
    end
  end
end
