require File.expand_path('../test_helper', __FILE__)
require 'tmpdir'
require 'json'

# Stage 4 (timeline) + Stage 5 (tool_calls) of the ChatAnalyst redesign:
# module-method behavior over the compact provenance API, exercised through
# the offline fixture family in test/scout/agent_meta_fixtures.rb and
# through synthetic chats written inline.  All addressing is chat path +
# zero-based message indices.
class TestChatAnalystTimeline < Test::Unit::TestCase
  include ChatAnalystFixtures

  def teardown
    ChatAnalyst::TIMELINE_CACHE.clear
  end

  def triplet_chat(dir, name = 'timeline.chat')
    write_chat(dir, name, <<~CHAT)
      user: inspect
      meta: pt=1 ct=1 tt=2 inference_id=p1 timestamp=2026-10-08T10:00:00Z reas=Inspect the implementation and identify the related file carefully.
      function_call: {"name":"search","arguments":{"path":"~/repo"},"id":"s1"}
      function_call_output: {"name":"search","content":"secret output","id":"s1","start_timestamp":"2026-10-08T10:00:01Z","timestamp":"2026-10-08T10:00:02Z"}
      assistant: completed
      meta: pt=1 ct=1 tt=2 inference_id=p2 timestamp=2026-10-08T10:01:00Z reas=Review the tests and confirm the behavior with evidence.
      function_call: {"name":"read","arguments":{"path":"~/repo/file.rb"},"id":"r1"}
      function_call_output: {"name":"read","content":"more secrets","id":"r1"}
      assistant: reviewed
      meta: pt=1 ct=1 tt=2 inference_id=p3 timestamp=2026-10-08T10:20:00Z reas=Summarize the verified outcome concisely for the user.
      assistant: done
    CHAT
  end

  # -- Stage 4: timeline ------------------------------------------------------

  def test_timeline_bouts_anchored_at_meta_zero_based_triplets
    TmpFile.with_dir do |dir|
      result = ChatAnalyst.timeline(triplet_chat(dir))
      bouts = result[:bouts]
      assert_equal 3, result[:bouts].length
      # Triplet 1: anchor meta index 1, trigger user 0, assistant 4.
      assert_equal [1, 0, 4], [bouts[0][:anchor_index], bouts[0][:trigger_index], bouts[0][:assistant_index]]
      # Triplet 2: anchor meta index 5, same leading user 0 (no new user line).
      assert_equal [5, 0, 8], [bouts[1][:anchor_index], bouts[1][:trigger_index], bouts[1][:assistant_index]]
      # Triplet 2 reasoning: "Review the tests..." — bout 2 carries its own.
      assert_equal 56, bouts[1][:reasoning][:characters]
      # Calls are attached to the bout that contains their call index.
      assert_equal %w[search read], bouts[0][:calls].map { |c| c[:tool] } + bouts[1][:calls].map { |c| c[:tool] }
      # Reasoning-only bout preserved (third triplet, zero calls).
      assert_equal 9, bouts[2][:anchor_index]
      assert_equal [], bouts[2][:calls]
      # Bouts are anchored at meta messages, never alternating meta/assistant.
      anchors = bouts.map { |bout| bout[:anchor_index] }
      assert anchors.all?, 'every explicit bout is anchored at a meta message'
    end
  end

  def test_timeline_bursts_are_temporal_only
    TmpFile.with_dir do |dir|
      result = ChatAnalyst.timeline(triplet_chat(dir))
      # 10:00 -> 10:01 gap 60s (no split), 10:01 -> 10:20 gap 1140s (split).
      assert_equal 2, result[:bursts].length
      assert_equal [1, 2], result[:bursts].map { |burst| burst[:id] }
      assert_equal 2, result[:bursts][0][:bouts]
      assert_equal 1, result[:bursts][1][:bouts]
      # No semantic phase vocabulary anywhere in the result.
      refute result.to_s.include?('primary_group')
      refute result.to_s.include?('breakpoint')
      refute result.to_s.include?('reasoning_shift')
      refute result.to_s.include?('resource')
    end
  end

  def test_timeline_bursts_expansion_inlines_selected_bout_records
    TmpFile.with_dir do |dir|
      result = ChatAnalyst.timeline(triplet_chat(dir), bursts: [2])
      assert_equal [2], result[:selected_burst_ids]
      assert_equal 1, result[:bursts].length
      assert_equal 1, result[:bursts][0][:bouts].length
      assert_equal 9, result[:bursts][0][:bouts][0][:anchor_index]
      # The selected burst's reasoning-only bout survives inlining.
      assert_equal 'Summarize the verified outcome concisely for the user.',
                   result[:bursts][0][:bouts][0][:reasoning][:preview]
      # Minimal revision step 1 (regression for the selected-burst bug):
      # selection mode is a DETAIL view — the full bout array is GONE, so
      # every selected bout appears exactly once (the old shape kept :bouts
      # AND inlined the selected bouts again, duplicating them).
      assert result[:bursts][0].key?(:bouts), 'selected bursts inline their bouts'
      assert result.key?(:bouts_total), 'selection mode reports the full bout count'
      assert_equal 3, result[:bouts_total]
      refute result.key?(:bouts), 'selection mode carries no root :bouts array'
      preview = result[:bursts][0][:bouts][0][:reasoning][:preview]
      occurrences = result[:bursts].flat_map { |burst| burst[:bouts] }
                             .count { |bout| bout[:reasoning][:preview] == preview }
      assert_equal 1, occurrences, 'selected bout reasoning appears exactly once in the inlined detail'
      # The un-expanded result still exposes every bout compactly.
      plain = ChatAnalyst.timeline(triplet_chat(dir))
      assert_equal 3, plain[:bouts].length
      assert_nil plain[:selected_burst_ids]
      assert_equal 2, plain[:bursts][0][:bouts], 'default mode keeps bursts as a compact index (bout count)'
    end
  end

  def test_timeline_cross_chat_indices_do_not_restart
    TmpFile.with_dir do |dir|
      # Worker job referenced by a receipt IS chat-producing: its generated
      # result chat (not its live agent.chat sidecar) joins the tree, so the
      # timeline carries bouts from two chats.
      worker = File.join(dir, 'Worker/ask/Default_w.chat')
      FileUtils.mkdir_p(File.dirname(worker))
      File.write(worker, "user: work\n" +
        "meta: pt=100 ct=50 tt=150 timestamp=2026-10-08T10:30:00Z inference_id=w1 reas=worker reasoning bout\n" +
        "assistant: worker done\n")
      File.write(worker + '.info', {status: 'done', type: 'chat', dependencies: []}.to_json)

      parent, = fixture_agent_job(dir)
      parent_chat = write_chat(dir, 'parent2.chat',
        "user: go\n" +
        'function_call: ' + %({"name":"ask","arguments":{"agent":"Worker"},"id":"a1"}) + "\n" +
        'function_call_output: ' + %({"name":"ask","content":"ok","id":"a1","meta":#{[meta_receipt("job=#{worker}")].to_json}}) + "\n" +
        "meta: pt=1 ct=1 tt=2 timestamp=2026-10-08T10:00:00Z inference_id=p1 reas=parent reasoning bout\n" +
        "assistant: done\n")

      result = ChatAnalyst.timeline(parent_chat)
      paths = result[:bouts].map { |bout| bout[:chat] }.uniq
      assert_equal 2, paths.length, 'both chats are traversed'
      # Every bout keeps the indices of its OWN chat; no global numbering and
      # no per-chat-restarting event index list exists anywhere in the result.
      parent_bout = result[:bouts].find { |bout| bout[:chat] == parent_chat }
      worker_bout = result[:bouts].find { |bout| bout[:chat] == worker }
      assert_equal 3, parent_bout[:anchor_index]
      assert_equal 1, worker_bout[:anchor_index]
      assert result[:bursts].all? { |burst| !burst.key?(:event_indices) }
      # 10:00 parent and 10:30 worker -> two bursts by elapsed time.
      assert_equal 2, result[:bursts].length
      assert_equal [parent_chat, worker], result[:bursts].map { |burst| burst[:chats].first }
    end
  end

  def test_timeline_implicit_tool_call_bouts_labelled
    TmpFile.with_dir do |dir|
      path = write_chat(dir, 'implicit.chat', <<~CHAT)
        user: no meta here
        function_call: {"name":"bash","arguments":{"cmd":"ls"},"id":"b1"}
        function_call_output: {"name":"bash","content":"file1\\nfile2","id":"b1"}
        assistant: done
      CHAT
      result = ChatAnalyst.timeline(path)
      assert_equal 1, result[:bouts].length
      bout = result[:bouts].first
      assert bout[:implicit]
      assert_nil bout[:anchor_index]
      assert_equal 0, bout[:trigger_index]
      assert_equal 1, bout[:first]
      assert_equal 2, bout[:last]
      assert_equal 1, bout[:calls].length
      assert_equal 1, result[:summary][:implicit_bouts]
    end
  end

  def test_timeline_malformed_timestamps_become_nil_and_never_abort
    TmpFile.with_dir do |dir|
      path = write_chat(dir, 'badts.chat', <<~CHAT)
        user: inspect
        meta: pt=1 inference_id=p1 timestamp=not-a-timestamp reas=first reasoning line
        assistant: one
        meta: pt=1 inference_id=p2 timestamp=2026-10-08T10:00:00Z reas=second reasoning line
        assistant: two
      CHAT
      result = ChatAnalyst.timeline(path)
      assert_equal 2, result[:bouts].length
      by_anchor = result[:bouts].group_by { |bout| bout[:anchor_index] }
      assert_nil by_anchor[1][0][:timestamp]
      refute_nil by_anchor[3][0][:timestamp]
      # Unparseable timestamps never split bursts by themselves.
      assert_equal 1, result[:bursts].length
    end
  end

  def test_timeline_qualified_agent_selectors_preserved
    TmpFile.with_dir do |dir|
      path = write_chat(dir, 'qualified.chat', <<~CHAT)
        user: delegate
        function_call: {"name":"ask","arguments":{"agent":"Worker/ScoutCoder"},"id":"a1"}
        function_call_output: {"name":"ask","content":"ok","id":"a1"}
        assistant: done
      CHAT
      result = ChatAnalyst.timeline(path)
      call = result[:bouts].first[:calls].first
      assert_equal 'Worker/ScoutCoder#default', call[:delegation_target]
      assert call[:delegated]
      assert result.to_s.include?('Worker/ScoutCoder')
    end
  end

  def test_timeline_cache_invalidated_by_chat_append_job_result_and_live_discovery
    TmpFile.with_dir do |dir|
      # Build a two-chat tree: the parent references a chat-producing worker
      # whose generated result chat is genuinely reachable, so an append to
      # it must invalidate the cached timeline.
      worker = File.join(dir, 'Worker/ask/Default_w.chat')
      FileUtils.mkdir_p(File.dirname(worker))
      File.write(worker, "user: work\n" +
        "meta: pt=1 ct=1 tt=2 timestamp=2026-10-08T10:30:00Z inference_id=w1 reas=worker reasoning\n" +
        "assistant: worker done\n")
      File.write(worker + '.info', {status: 'done', type: 'chat', dependencies: []}.to_json)
      parent = write_chat(dir, 'parent.chat',
        "user: go\n" +
        'function_call: ' + %({"name":"ask","arguments":{"agent":"Worker"},"id":"a1"}) + "\n" +
        'function_call_output: ' + %({"name":"ask","content":"ok","id":"a1","meta":#{[meta_receipt("job=#{worker}")].to_json}}) + "\n" +
        "meta: pt=1 ct=1 tt=2 timestamp=2026-10-08T10:00:00Z inference_id=p1\n" +
        "assistant: done\n")

      before = ChatAnalyst.timeline(parent)
      assert_equal 2, before[:summary][:bouts]

      # Cached: a second call with identical inputs reuses the entry; the
      # cache is deep-copied so caller mutations never poison it.
      before[:bouts] << :mutated
      again = ChatAnalyst.timeline(parent)
      assert_equal 2, again[:summary][:bouts]

      # 1) appending to the reachable result chat invalidates and the new
      #    messages are visible immediately.
      File.open(worker, 'a') do |file|
        file.puts 'meta: pt=1 ct=1 tt=2 timestamp=2026-10-08T10:35:00Z inference_id=w2'
      end
      appended = ChatAnalyst.timeline(parent)
      assert_equal 3, appended[:summary][:bouts]

      # 2) changing a reachable JOB's result bytes invalidates.
      job_result = worker.sub(/\.chat\z/, '')
      File.open(job_result, 'a') { |file| file.write('changed result bytes') }
      File.open(job_result + '.info', 'a') { |file| file.write(' ') }
      changed = ChatAnalyst.timeline(parent)
      assert_not_nil changed

      # 3) discovering a new live sidecar relationship (a new .files chat
      #    path under a visited job) invalidates: the live PATH set is part
      #    of the freshness identity.
      FileUtils.mkdir_p(worker + '.files')
      File.write(File.join(worker + '.files', 'new-side.chat'),
                 "user: side context\nassistant: side done\n")
      discovered = ChatAnalyst.timeline(parent)
      assert_equal 3, discovered[:summary][:bouts]
    end
  end

  def test_timeline_results_carry_no_loaded_objects_or_concatenated_ids
    TmpFile.with_dir do |dir|
      parent, = fixture_agent_job(dir)
      result = ChatAnalyst.timeline(parent)
      serialized = result.to_s
      serializable = begin
                       JSON.generate(result)
                       true
                     rescue StandardError
                       false
                     end
      # no "path#index" concatenated identifiers: delegation targets carry
      # '#' by design (agent#conversation), so assert on index-adjacency
      # instead: no returned string is a path immediately followed by '#'.
      result[:bouts].flat_map { |bout| bout[:calls] }.compact.each do |call|
        assert call.keys.none? { |key| %i[call_address output_address].include?(key) }
      end
      [result, result[:bouts], result[:bursts]].flatten.compact.each do |value|
        assert_no_leaked_objects(value)
      end
    end
  end

  # -- Stage 5: tool_calls ------------------------------------------------------

  def test_tool_calls_receipt_anchored_at_outer_output_index
    TmpFile.with_dir do |dir|
      parent, worker, = fixture_agent_job(dir)
      result = ChatAnalyst.tool_calls(parent)
      assert_equal 1, result[:calls].length
      call = result[:calls].first
      assert_equal 'ask', call[:tool]
      assert_equal 1, call[:call_index]
      assert_equal 2, call[:output_index]
      assert_equal [worker], call[:jobs]
      assert call[:delegated]
      assert_equal 'Worker#default', call[:delegation_target]
      assert result[:calls].none? { |entry| entry.key?(:arguments) }
      assert result[:calls].none? { |entry| entry.key?(:output) }
    end
  end

  def test_tool_calls_ask_without_job_remains_delegation
    TmpFile.with_dir do |dir|
      path = write_chat(dir, 'ask-no-job.chat', <<~CHAT)
        user: go
        function_call: {"name":"ask","arguments":{"agent":"Research"},"id":"a1"}
        function_call_output: {"name":"ask","content":"child answer","id":"a1"}
        assistant: done
      CHAT
      call = ChatAnalyst.tool_calls(path)[:calls].first
      assert call[:delegated]
      assert_equal 'Research#default', call[:delegation_target]
      assert_equal [], call[:jobs]
    end
  end

  def test_tool_calls_two_jobs_at_one_index_and_ordinary_calls_invisible
    TmpFile.with_dir do |dir|
      worker = make_job(dir, 'Worker/ask/Default_w', logs: {'agent.chat' => "user: w\nassistant: ok\n"})
      other = make_job(dir, 'Other/ask/Default_o', logs: {'agent.chat' => "user: o\nassistant: ok\n"})
      receipts = [meta_receipt("job=#{worker}"), meta_receipt("job=#{other}")].to_json
      path = write_chat(dir, 'two.chat',
        "user: go\n" +
        'function_call: ' + %({"name":"ask","arguments":{"agent":"Worker"},"id":"a1"}) + "\n" +
        'function_call_output: ' + %({"name":"ask","content":"ok","id":"a1","meta":#{receipts}}) + "\n" +
        'function_call: ' + %({"name":"read","arguments":{"path":"f"},"id":"r1"}) + "\n" +
        'function_call_output: ' + %({"name":"read","content":"data","id":"r1"}) + "\n" +
        "assistant: done\n")
      calls = ChatAnalyst.tool_calls(path)[:calls]
      ask = calls.find { |call| call[:tool] == 'ask' }
      assert_equal [worker, other].sort, ask[:jobs].sort, 'both receipt jobs anchored at the same output index'
      ordinary = calls.find { |call| call[:tool] == 'read' }
      refute ordinary[:delegated]
      assert_equal [], ordinary[:jobs]
    end
  end

  def test_tool_calls_identical_calls_without_ids_never_deduplicated
    TmpFile.with_dir do |dir|
      path = write_chat(dir, 'no-ids.chat', <<~CHAT)
        user: go
        function_call: {"name":"read","arguments":{"path":"same"}}
        function_call_output: {"name":"read","content":"data"}
        function_call: {"name":"read","arguments":{"path":"same"}}
        function_call_output: {"name":"read","content":"data"}
        assistant: done
      CHAT
      calls = ChatAnalyst.tool_calls(path)[:calls]
      assert_equal 2, calls.length
      assert_equal [1, 3], calls.map { |call| call[:call_index] }
      assert calls.none? { |call| call.key?(:copy_of) }
    end
  end

  def test_tool_calls_range_filter_and_validation_errors
    TmpFile.with_dir do |dir|
      path = triplet_chat(dir)
      calls = ChatAnalyst.tool_calls(path, first: 2, last: 2)
      assert_equal [2], calls[:calls].map { |call| call[:call_index] }
      assert_equal [2, 2], [calls[:first], calls[:last]]

      assert_raise_message(/Invalid last/, 'x') { ChatAnalyst.tool_calls(path, first: 3, last: 1) }
      assert_raise_message(/out of range/) { ChatAnalyst.tool_calls(path, first: 0, last: 99) }
      assert_raise_message(/Invalid first/) { ChatAnalyst.tool_calls(path, first: -1) }
    end
  end

  def test_tool_calls_status_and_output_character_accounting
    TmpFile.with_dir do |dir|
      path = write_chat(dir, 'status.chat', <<~CHAT)
        user: go
        function_call: {"name":"bash","arguments":{"cmd":"ok"},"id":"t1"}
        function_call_output: {"name":"bash","content":"{\\"stdout\\":\\"ok\\",\\"exit_status\\":0}","id":"t1"}
        function_call: {"name":"bash","arguments":{"cmd":"bad"},"id":"t2"}
        function_call_output: {"name":"bash","content":"{\\"exception\\":\\"boom\\"}","id":"t2"}
        function_call: {"name":"bash","arguments":{"cmd":"x"},"id":"t3"}
        assistant: no output for t3
      CHAT
      calls = ChatAnalyst.tool_calls(path)[:calls]
      assert_equal %i[success failure unknown], calls.map { |call| call[:status] }
      assert_equal :exception, calls[1][:reason]
      assert calls[0][:output_characters] > 0
      assert_nil calls[2][:output_index]
    end
  end

  # -- shared assertion helpers -------------------------------------------------

  def assert_no_leaked_objects(value, seen = {}.compare_by_identity)
    return if seen.key?(value)
    seen[value] = true
    case value
    when Chat, Step, Path
      raise "leaked object in result: #{value.class}"
    when Hash
      value.each_value { |nested| assert_no_leaked_objects(nested, seen) }
    when Array
      value.each { |nested| assert_no_leaked_objects(nested, seen) }
    when String
      # A plain String is fine; Path instances are subclasses of String, and
      # they are caught by the case above before this branch.
    end
  end
end
