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
      result = ChatAnalyst.job(:chat_timeline, {file: fixture(dir), bursts: ["2"]}).run
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
      result = ChatAnalyst.job(:chat_timeline, {file: path, bursts: ['120']}).run
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
      result = ChatAnalyst.job(:chat_timeline, {file: path, bursts: ['1']}).run
      assert_equal :detail, result[:mode]
      assert_equal 1, result[:bursts].length
      assert_equal 2, result[:bursts].first[:segments].first[:calls].length
      refute result.to_s.include?('repo/private')
      refute result.to_s.include?('repo/Worker')
      assert result.to_s.include?('ResearchThread')
      assert result.to_s.include?('Worker')
    end
  end

  # Freshness semantics (user ground truth, recorded 2026-10): `:file`/`:path`
  # inputs are content-hashed into the job hash, and the ONLY genuine
  # freshness gap is reachable children, which the dep-block `closure_identity`
  # input closes. In-process `Persist.memory` memoization legitimately
  # short-circuits `Task#job` BEFORE the dep block re-runs, so a same-shape
  # in-process repeat returns the memoized (pre-edit) Step. We do not fight
  # the memo: the updated computation is requested with a distinct job id —
  # a genuinely different job address — so the dep block re-runs against the
  # edited closure and the observable output updates. There is no adapter
  # override; `ChatAnalyst.tasks[:chat_timeline]` IS the public task, so this
  # also proves direct `.job` calls inherit the dep-block freshness.
  def test_reachable_child_edit_changes_timeline_identity_but_unrelated_edit_does_not
    TmpFile.with_dir do |dir|
      root, worker, = fixture_agent_job(dir)
      before = ChatAnalyst.job(:chat_timeline, {file: root}).run
      before_identity = ChatAnalyst.helper(:timeline_closure_identity, root)
      # The dep block derives the index job from exactly these inputs, so this
      # reproduces the index job path the public job consumed.
      index_path = lambda do |identity|
        ChatAnalyst.job(:timeline_index,
                        {file: root, closure_identity: identity,
                         groups: nil, burst_gap: 120}).path.to_s
      end
      before_index_path = index_path.call(before_identity)

      unrelated = write_chat(dir, 'unrelated.chat', "user: unrelated\\n")
      File.write(unrelated, "user: unrelated edit\\n")
      unrelated_identity = ChatAnalyst.helper(:timeline_closure_identity, root)
      assert_equal before_identity, unrelated_identity
      assert_equal before_index_path, index_path.call(unrelated_identity)

      child_chat = File.join(worker + '.files', 'agent.chat')
      File.open(child_chat, 'a') { |file| file.puts('meta: pt=1 ct=1 tt=2 inference_id=timeline-edit') }
      after_identity = ChatAnalyst.helper(:timeline_closure_identity, root)
      refute_equal before_identity, after_identity
      refute_equal before_index_path, index_path.call(after_identity)

      after = ChatAnalyst.tasks[:chat_timeline].job('after-child-edit', {file: root}).run
      assert_operator after[:summary][:segments], :>, before[:summary][:segments]
    end
  end

  # Identity-level only for the mutations above; the observable-output half
  # for reachable-child edits lives in the test above (distinct job id, so
  # the dep block re-runs). Here we additionally prove the mutation also
  # moves the index job path — the identity change is not cosmetic.
  def test_reachable_job_result_and_info_mutations_change_closure_identity
    TmpFile.with_dir do |dir|
      root, worker, dependency = fixture_agent_job(dir)
      index_path = lambda do |identity|
        ChatAnalyst.job(:timeline_index,
                        {file: root, closure_identity: identity,
                         groups: nil, burst_gap: 120}).path.to_s
      end

      initial = ChatAnalyst.helper(:timeline_closure_identity, root)
      initial_index_path = index_path.call(initial)

      File.open(dependency.to_s, 'a') { |file| file.write('changed result bytes') }
      result_changed = ChatAnalyst.helper(:timeline_closure_identity, root)
      refute_equal initial, result_changed
      refute_equal initial_index_path, index_path.call(result_changed)

      File.open(dependency.to_s + '.info', 'a') { |file| file.write(' ') }
      info_changed = ChatAnalyst.helper(:timeline_closure_identity, root)
      refute_equal result_changed, info_changed
      refute_equal index_path.call(result_changed), index_path.call(info_changed)
    end
  end

  def test_new_reachable_log_chat_and_relation_changes_invalidate_closure
    TmpFile.with_dir do |dir|
      root, worker, = fixture_agent_job(dir)
      initial = ChatAnalyst.helper(:timeline_closure_identity, root)
      added_chat = File.join(worker + '.files', 'additional.chat')
      File.write(added_chat, "user: added worker context\nassistant: done\n")
      with_chat = ChatAnalyst.helper(:timeline_closure_identity, root)
      refute_equal initial, with_chat

      info_path = worker + '.info'
      info = JSON.parse(File.read(info_path))
      info['dependencies'] = []
      File.write(info_path, info.to_json)
      without_dependency = ChatAnalyst.helper(:timeline_closure_identity, root)
      refute_equal with_chat, without_dependency
    end
  end

  def test_overview_and_details_share_index_across_selected_subsets
    TmpFile.with_dir do |dir|
      path = fixture(dir)
      original_builder = ChatAnalyst.helpers[:timeline_build_segments]
      original_step_module = ChatAnalyst.instance_variable_get(:@_m)
      invocations = 0
      ChatAnalyst.helpers[:timeline_build_segments] = lambda do |*args, **kwargs|
        invocations += 1
        instance_exec(*args, **kwargs, &original_builder)
      end
      ChatAnalyst.instance_variable_set(:@_m, nil)
      begin
        overview = ChatAnalyst.job(:chat_timeline, {file: path}).run
        detail_one = ChatAnalyst.job(:chat_timeline, {file: path, bursts: ['1']}).run
        detail_two = ChatAnalyst.job(:chat_timeline, {file: path, bursts: ['2']}).run
      ensure
        ChatAnalyst.helpers[:timeline_build_segments] = original_builder
        ChatAnalyst.instance_variable_set(:@_m, original_step_module)
      end
      assert_equal 1, invocations, 'timeline index body should be computed once for overview and multiple detail subsets'
      assert_equal :overview, overview[:mode]
      assert_equal :detail, detail_one[:mode]
      assert_equal :detail, detail_two[:mode]

      identity = ChatAnalyst.helper(:timeline_closure_identity, path)
      index_inputs = {file: path, closure_identity: identity, groups: nil, burst_gap: 120}
      index_one = ChatAnalyst.job(:timeline_index, index_inputs)
      index_two = ChatAnalyst.job(:timeline_index, index_inputs)
      assert_equal index_one.path.to_s, index_two.path.to_s
      assert index_one.done?
    end
  end

  def test_unknown_burst_ids_return_empty_details
    TmpFile.with_dir do |dir|
      result = ChatAnalyst.job(:chat_timeline, {file: fixture(dir), bursts: ["999"]}).run
      assert_equal :detail, result[:mode]
      assert_equal [], result[:bursts]
    end
  end

  def test_reasoning_shift_fires_publicly_and_in_burst_counts_without_leaking_raw_text
    TmpFile.with_dir do |dir|
      # Two consecutive explicit work segments in the same chat, inside one
      # burst (60s apart, below the 120s burst gap), with deliberately
      # disjoint reasoning vocabularies: 8 distinct words of >= 3 characters
      # each (TIMELINE_MIN_REASONING_WORDS), Jaccard similarity 0.0, well
      # below TIMELINE_REASONING_SHIFT_THRESHOLD (0.12).
      path = write_chat(dir, 'reasoning_shift.chat', <<~CHAT)
        user: inspect
        meta: pt=1 ct=1 tt=2 inference_id=p1 timestamp=2026-10-08T10:00:00Z reas=alpha bravo charlie delta echo foxtrot golf hotel
        function_call: {"name":"search","arguments":{"path":"~/repo"},"id":"s1"}
        function_call_output: {"name":"search","content":"first output","id":"s1"}
        assistant: first
        meta: pt=1 ct=1 tt=2 inference_id=p2 timestamp=2026-10-08T10:01:00Z reas=india juliet kilo lima mike november oscar papa
        function_call: {"name":"read","arguments":{"path":"~/repo/file.rb"},"id":"r1"}
        function_call_output: {"name":"read","content":"second output","id":"r1"}
        assistant: second
      CHAT

      result = ChatAnalyst.job(:chat_timeline, {file: path}).run
      assert_equal :overview, result[:mode]
      assert_equal 1, result[:bursts].length

      # The reasoning_shift signal must be observable in the public output.
      signals = result[:bursts].first[:breakpoint_signals]
      # Replayed job data carries string keys inside nested arrays; use
      # indifferent access so the assertion holds for fresh and replayed runs.
      shift = Array(signals).find { |signal| (signal[:type] || signal['type']).to_s == 'reasoning_shift' }
      assert shift, 'expected a reasoning_shift signal in the public overview breakpoint_signals'
      assert_operator (shift[:similarity] || shift['similarity']), :<, 0.12

      # The containing burst's aggregated reasoning_shifts count must be
      # non-zero (signals are attached before burst finalization).
      identity = ChatAnalyst.helper(:timeline_closure_identity, path)
      index_inputs = {file: path, closure_identity: identity, groups: nil, burst_gap: 120}
      index_step = ChatAnalyst.job(:timeline_index, index_inputs)
      index_step.run
      index_json = File.read(index_step.path)
      index = JSON.parse(index_json)
      burst = Array(index['bursts']).first
      assert burst, 'expected at least one burst in the persisted index'
      assert_operator burst['reasoning_shifts'].to_i, :>=, 1,
                      'burst-level reasoning_shifts must aggregate the segment signal'

      # Hard constraint: raw reasoning text never reaches the persisted index
      # nor any public projection (only fingerprint/characters/words survive).
      raw_first = 'alpha bravo charlie delta echo foxtrot golf hotel'
      raw_second = 'india juliet kilo lima mike november oscar papa'
      refute index_json.include?(raw_first)
      refute index_json.include?(raw_second)
      serialized = result.to_s
      refute serialized.include?(raw_first)
      refute serialized.include?(raw_second)
    end
  end

  def test_public_cache_key_sequence_overview_detail_groups_and_gap
    TmpFile.with_dir do |dir|
      path = write_chat(dir, "cache_key_sequence.chat", <<~CHAT)
        user: inspect
        meta: pt=1 ct=1 tt=2 inference_id=p1 timestamp=2026-10-08T10:00:00Z reas=alpha bravo charlie delta echo foxtrot golf hotel
        function_call: {"name":"search","arguments":{"path":"~/repo"},"id":"s1"}
        function_call_output: {"name":"search","content":"output one","id":"s1"}
        assistant: first
        meta: pt=1 ct=1 tt=2 inference_id=p2 timestamp=2026-10-08T10:05:00Z reas=india juliet kilo lima mike november oscar papa
        function_call: {"name":"read","arguments":{"path":"~/repo/file.rb"},"id":"r1"}
        function_call_output: {"name":"read","content":"output two","id":"r1"}
        assistant: second
        meta: pt=1 ct=1 tt=2 inference_id=p3 timestamp=2026-10-08T10:10:00Z reas=quebec romeo sierra tango uniform victor whiskey xray
        function_call: {"name":"bash","arguments":{"cmd":"echo three"},"id":"b1"}
        function_call_output: {"name":"bash","content":"output three","id":"b1"}
        assistant: third
        meta: pt=1 ct=1 tt=2 inference_id=p4 timestamp=2026-10-08T10:15:00Z reas=zulu one two three four five six seven
        function_call: {"name":"write","arguments":{"path":"~/repo/out.rb"},"id":"w1"}
        function_call_output: {"name":"write","content":"output four","id":"w1"}
        assistant: fourth
      CHAT

      # 1. Overview: default gap 120 splits the four 300s-apart segments into
      # four single-segment bursts, one tool call each.
      overview = ChatAnalyst.job(:chat_timeline, {file: path}).run
      assert_equal :overview, overview[:mode]
      assert_equal [1, 2, 3, 4], overview[:bursts].map { |burst| burst[:id] }
      assert_equal %w[search read execute write], overview[:bursts].map { |burst| burst[:primary_group] }
      assert overview[:bursts].all? { |burst| burst[:segments] == 1 && burst[:calls] == 1 }
      assert overview[:bursts].none? { |burst| burst.key?(:selected_burst_ids) }

      # 2. Detail for burst 1: search-only content, fingerprint of reasoning p1.
      detail1 = ChatAnalyst.job(:chat_timeline, {file: path, bursts: ["1"]}).run
      assert_equal :detail, detail1[:mode]
      assert_equal ["1"], detail1[:selected_burst_ids]
      assert_equal 1, detail1[:bursts].length
      segment1 = detail1[:bursts].first[:segments].first
      assert_equal %w[search], segment1[:calls].map { |call| call[:tool] }
      assert_equal 's1', segment1[:calls].first[:call_id]

      # 3. Detail for burst 3: bash-only content, must not replay burst 1's job.
      detail3 = ChatAnalyst.job(:chat_timeline, {file: path, bursts: ["3"]}).run
      assert_equal :detail, detail3[:mode]
      assert_equal ["3"], detail3[:selected_burst_ids]
      assert_equal 1, detail3[:bursts].length
      segment3 = detail3[:bursts].first[:segments].first
      assert_equal %w[bash], segment3[:calls].map { |call| call[:tool] }
      assert_equal 'b1', segment3[:calls].first[:call_id]
      assert_equal 1, detail1[:bursts].first[:id]
      assert_equal 3, detail3[:bursts].first[:id]
      refute_equal segment1[:calls], segment3[:calls]

      # 4. Overview again after the detail calls: not polluted by them.
      overview_again = ChatAnalyst.job(:chat_timeline, {file: path}).run
      assert_equal :overview, overview_again[:mode]
      assert_equal [1, 2, 3, 4], overview_again[:bursts].map { |burst| burst[:id] }
      assert_equal %w[search read execute write], overview_again[:bursts].map { |burst| burst[:primary_group] }
      # Overview bursts carry a segment COUNT, never per-segment detail arrays.
      assert overview_again[:bursts].all? { |burst| Integer === burst[:segments] }

      # 5. Changed groups: read calls relabeled; primary_group per burst shifts.
      regrouped = ChatAnalyst.job(:chat_timeline, {file: path, groups: 'search=search;read=read,write'}).run
      assert_equal :overview, regrouped[:mode]
      assert_equal [1, 2, 3, 4], regrouped[:bursts].map { |burst| burst[:id] }
      assert_equal %w[search read execute read], regrouped[:bursts].map { |burst| burst[:primary_group] }
      assert_equal %w[search read execute write], overview_again[:bursts].map { |burst| burst[:primary_group] }

      # 6. Changed burst_gap: 1200s swallows all four segments into one burst.
      wide = ChatAnalyst.job(:chat_timeline, {file: path, burst_gap: 1200.0}).run
      assert_equal :overview, wide[:mode]
      assert_equal 1, wide[:bursts].length
      assert_equal 4, wide[:bursts].first[:segments]
      assert_equal 4, wide[:bursts].first[:calls]

      # 7. Default overview once more: still the four-burst default view.
      final = ChatAnalyst.job(:chat_timeline, {file: path}).run
      assert_equal :overview, final[:mode]
      assert_equal [1, 2, 3, 4], final[:bursts].map { |burst| burst[:id] }
      assert_equal %w[search read execute write], final[:bursts].map { |burst| burst[:primary_group] }
    end
  end
end
