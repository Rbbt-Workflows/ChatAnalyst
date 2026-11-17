require File.expand_path('../test_helper', __FILE__)
require 'tmpdir'
require 'json'

# Phase 3, plan step 3: the inference / activity-cluster model over the
# pinned span/ownership semantics (lib/ChatAnalyst/inferences.rb; contract
# 1h/2B/2C as amended C1-C3).  Fixtures reuse the offline family in
# test/scout/agent_meta_fixtures.rb.  No reasoning content ever leaves the
# API beyond presence/characters - asserted below.
#
# LAYOUT PIN (see lib/ChatAnalyst/inferences.rb header): scout-ai UNSHIFTS
# each inference meta BEFORE its response segment.  Persisted per inference:
# META, [assistant text], [its tool calls], [outputs].  The fixtures below
# are written in that pinned shape - meta BEFORE the calls it accounts for.
class TestChatAnalystInferences < Test::Unit::TestCase
  include ChatAnalystFixtures

  def teardown
    ChatAnalyst::INFERENCE_CACHE.clear
  end

  # Pinned layout: request, META(i1), two calls+outputs, assistant text;
  # META(i2, reasoning-only round, no covered messages), then a chained
  # call; new user request, META(i3) with no calls; trailing UNASSOCIATED
  # call after the last meta.
  def chain_chat(dir, name = 'chain.chat')
    write_chat(dir, name, [
      'user: inspect everything',
      'meta: pt=1 ct=1 tt=2 inference_id=i1 timestamp=2026-10-08T10:00:00Z',
      'function_call: {"name":"search","arguments":{"path":"~/repo"},"id":"s1"}',
      'function_call_output: {"name":"search","content":"hit","id":"s1"}',
      'function_call: {"name":"read","arguments":{"path":"~/repo/f"},"id":"r1"}',
      'function_call_output: {"name":"read","content":"body","id":"r1"}',
      'assistant: summarized',
      'meta: pt=1 ct=1 tt=2 inference_id=i2 timestamp=2026-10-08T10:01:00Z reas=Second look',
      'function_call: {"name":"write","arguments":{"path":"~/repo/out"},"id":"w1"}',
      'function_call_output: {"name":"write","content":"saved","id":"w1"}',
      'user: second request',
      'meta: pt=1 ct=1 tt=2 inference_id=i3 timestamp=2026-10-08T10:02:00Z',
      'assistant: answered',
      'function_call: {"name":"bash","arguments":{"cmd":"ls"},"id":"b1"}',
      'function_call_output: {"name":"bash","content":"files","id":"b1"}'
    ].join("\n") + "\n")
  end

  def test_one_inference_record_per_meta_message
    TmpFile.with_dir do |dir|
      path = chain_chat(dir)
      records = ChatAnalyst.inferences(path)
      metas = Chat.load(path).each_with_index.count do |message, _|
        message[:role].to_s == 'meta' && !Chat.parse_meta(message[:content].to_s).key?('job')
      end
      assert_equal 3, metas
      assert_equal 3, records.length, 'exactly one record per inference meta'
      ids = records.map { |record| record[:inference_id] }
      chat_prefix = ChatAnalyst::Ids.chat_id(path) + '#'
      assert ids.all? { |id| id.start_with?(chat_prefix) }
      assert_equal %w[1 7 11].map { |i| chat_prefix + i }, ids
    end
  end

  def test_inference_boundaries_multiple_inferences_one_user_request
    TmpFile.with_dir do |dir|
      path = chain_chat(dir)
      records = ChatAnalyst.inferences(path)
      id = ChatAnalyst::Ids.chat_id(path)
      i1, i2, i3 = records
      # i1: span 0..1 (chat first message through the meta), trigger user@0,
      # no assistant (the meta's successor is a function_call).
      assert_equal "#{id}#0", i1[:first_message_id]
      assert_equal "#{id}#1", i1[:last_message_id]
      assert_equal "#{id}#0", i1[:trigger_message_id]
      assert_nil i1[:assistant_message_id], 'meta@1 successor is a call, not assistant text'
      assert_equal 2, i1[:tool_call_count], 's1 and r1 were EMITTED by i1'
      # i2: span 2..7 (after i1's meta, through i2's meta - it covers i1's
      # response segment), trigger = nearest preceding non-meta = assistant@6
      # (i1's response), reas carried, owns w1.
      assert_equal "#{id}#2", i2[:first_message_id]
      assert_equal "#{id}#7", i2[:last_message_id]
      assert_equal "#{id}#6", i2[:trigger_message_id],
                   'reasoning-only round reacts to the preceding assistant message'
      assert_equal 1, i2[:tool_call_count], 'w1 emitted by i2'
      assert i2[:reasoning_present]
      assert_equal 11, i2[:reasoning_characters], 'reas=Second look (11 chars)'
      # i3: new user request at 10 -> span 8..11, trigger 10, assistant 12
      # immediately after the meta.
      assert_equal "#{id}#8", i3[:first_message_id]
      assert_equal "#{id}#11", i3[:last_message_id]
      assert_equal "#{id}#10", i3[:trigger_message_id]
      assert_equal "#{id}#12", i3[:assistant_message_id],
                   'assistant immediately after the meta is the inference response'
      assert_equal 1, i3[:tool_call_count], 'b1@13 emitted by i3 (trailing call)' 
    end
  end

  # Under the PINNED emitter rule, a call is unassociated exactly when NO
  # inference meta precedes it in its chat (opening unaccounted call, legacy
  # chats); a trailing call after the last meta BELONGS to that meta.  This is
  # the inverted-scenario deviation from the work order's draft rule.
  def test_unassociated_call_before_first_meta_and_no_synthetic_inference
    TmpFile.with_dir do |dir|
      path = write_chat(dir, 'opening.chat', [
        'function_call: {"name":"legacy","arguments":{"q":"1"},"id":"l0"}',
        'function_call_output: {"name":"legacy","content":"x","id":"l0"}',
        'meta: pt=1 ct=1 tt=2 inference_id=o1 timestamp=2026-10-08T10:00:00Z',
        'function_call: {"name":"search","arguments":{"path":"~/repo"},"id":"s1"}',
        'function_call_output: {"name":"search","content":"hit","id":"s1"}'
      ].join("\n") + "\n")
      records = ChatAnalyst.inferences(path)
      # Exactly one inference (the meta); NO synthetic inference for the
      # opening call.
      assert_equal 1, records.length
      assert_equal 1, records.first[:tool_call_count], 'o1 emitted search@3; the PRE-meta legacy call is not counted'
      calls = ChatAnalyst.tool_calls(path)[:calls]
      legacy = calls.find { |call| call[:tool] == 'legacy' }
      assert_equal 0, legacy[:call_index]
      assert_nil legacy[:inference_id], 'opening call is unassociated'
      assert_equal :primary, legacy[:source_kind]
      search = calls.find { |call| call[:tool] == 'search' }
      assert_equal "#{ChatAnalyst::Ids.chat_id(path)}#2", search[:inference_id],
                   's1 emitted by o1 (preceding meta)'
      # And the chain fixture's trailing bash call belongs to the LAST meta.
      chain = chain_chat(dir)
      chain_calls = ChatAnalyst.tool_calls(chain)[:calls]
      trailing = chain_calls.find { |call| call[:tool] == 'bash' }
      assert_equal "#{ChatAnalyst::Ids.chat_id(chain)}#11", trailing[:inference_id],
                   'trailing call is emitted by the last preceding meta'
      assert ChatAnalyst.inferences(chain).none? { |record| record[:first_message_id].end_with?('#13') }
    end
  end

  def test_opening_projection_marker_owns_nothing_and_opening_call_is_unassociated
    TmpFile.with_dir do |dir|
      # The pinned real-chat opening shape: job marker meta, inference meta,
      # then a call - the call belongs to the inference meta (its emitter).
      path = write_chat(dir, 'search_like.chat', [
        'meta: job=Planned/search/Default_x.chat',
        'meta: pt=1 tt=2 inference_id=q1 timestamp=2026-10-08T10:00:00Z',
        'function_call: {"name":"cortex_list","arguments":{"limit":50},"id":"c1"}',
        'function_call_output: {"name":"cortex_list","content":"entries","id":"c1"}'
      ].join("\n") + "\n")
      records = ChatAnalyst.inferences(path)
      assert_equal 1, records.length, 'job marker owns nothing'
      id = ChatAnalyst::Ids.chat_id(path)
      assert_equal "#{id}#1", records.first[:inference_id]
      # Span of the first inference starts at the chat's first message (the
      # job marker is inside the span), trigger nil (nothing non-meta
      # precedes the meta).
      assert_equal "#{id}#0", records.first[:first_message_id]
      assert_equal "#{id}#1", records.first[:last_message_id]
      assert_nil records.first[:trigger_message_id]
      calls = ChatAnalyst.tool_calls(path)[:calls]
      assert_equal "#{id}#1", calls.first[:inference_id], 'call emitted by q1'
    end
  end

  def test_undated_inference_unclustered_and_never_bridges
    TmpFile.with_dir do |dir|
      path = write_chat(dir, 'undated.chat', [
        'user: a',
        'meta: pt=1 ct=1 tt=2 inference_id=u1 timestamp=2026-10-08T10:00:00Z',
        'meta: pt=1 ct=1 tt=2 inference_id=u2',
        'meta: pt=1 ct=1 tt=2 inference_id=u3 timestamp=2026-10-08T17:00:00Z'
      ].join("\n") + "\n")
      records = ChatAnalyst.inferences(path)
      u2 = records.find { |record| record[:inference_id].end_with?('#2') }
      assert_nil u2[:activity_cluster_id], 'undated inference joins no cluster'
      assert_nil u2[:timestamp]
      clusters = ChatAnalyst.activity_clusters(path)
      # 7-hour counterexample: two timestamped inferences split into TWO
      # clusters (max_gap 120s); the undated one bridges nothing.
      assert_equal 2, clusters[:clusters].length
      assert_equal 2, clusters[:summary][:clusters]
      assert_equal 1, clusters[:summary][:unclustered]
      assert_equal 3, clusters[:summary][:inferences]
      first, second = clusters[:clusters]
      assert_equal '2026-10-08T10:00:00Z', first[:first_timestamp]
      assert_equal '2026-10-08T17:00:00Z', second[:first_timestamp]
    end
  end

  def test_clusters_span_chats_and_id_is_first_inference_id
    TmpFile.with_dir do |dir|
      worker = File.join(dir, 'Worker/ask/Default_w.chat')
      FileUtils.mkdir_p(File.dirname(worker))
      File.write(worker, "user: work\n" +
        "meta: pt=1 ct=1 tt=2 inference_id=w1 timestamp=2026-10-08T10:01:00Z\n")
      File.write(worker + '.info', {status: 'done', type: 'chat', dependencies: []}.to_json)

      parent = write_chat(dir, 'parent.chat',
        "user: go\n" +
        'function_call: ' + %({"name":"ask","arguments":{"agent":"Worker"},"id":"a1"}) + "\n" +
        'function_call_output: ' + %({"name":"ask","content":"ok","id":"a1","meta":#{[meta_receipt("job=#{worker}")].to_json}}) + "\n" +
        "meta: pt=1 ct=1 tt=2 inference_id=p1 timestamp=2026-10-08T10:00:00Z\n")

      clusters = ChatAnalyst.activity_clusters(parent)
      assert_equal 1, clusters[:clusters].length, 'parent 10:00 and worker 10:01 share one cluster'
      cluster = clusters[:clusters].first
      assert_equal "#{ChatAnalyst::Ids.chat_id(parent)}#3", cluster[:cluster_id],
                   'cluster id is the FIRST (chronological) inference message id'
      assert_equal 2, cluster[:inference_count]
      expected = [ChatAnalyst::Ids.chat_id(parent), ChatAnalyst::Ids.chat_id(worker)]
      assert_equal expected.sort, cluster[:chats].sort, 'chats list carries both chats'
      assert cluster[:chats].is_a?(Array), 'chats is the identifier list'
      assert !cluster.key?(:chat_count), 'no redundant chat_count field exists'
      # Both inferences carry the same cluster id.
      records = ChatAnalyst.inferences(parent)
      assert records.all? { |record| record[:activity_cluster_id] == cluster[:cluster_id] }
      # Members lookup returns exactly the chronological members.
      members = ChatAnalyst.activity_cluster(parent, cluster[:cluster_id])
      assert_equal 2, members.length
      assert_equal [cluster[:cluster_id], "#{ChatAnalyst::Ids.chat_id(worker)}#1"],
                   members.map { |record| record[:inference_id] }
      # Unknown/foreign ids raise ArgumentError (task layer maps ParameterException).
      assert_raise(ArgumentError) { ChatAnalyst.activity_cluster(parent, 'nope#1') }
      foreign = write_chat(dir, 'foreign.chat',
        "user: elsewhere\nmeta: pt=1 tt=2 inference_id=f1 timestamp=2026-10-08T10:00:10Z\n")
      File.write(foreign + '.info', {status: 'done', type: 'chat', dependencies: []}.to_json)
      # A foreign-tree inference id is unknown under this root.
      assert_raise(ArgumentError) { ChatAnalyst.activity_cluster(parent, "#{ChatAnalyst::Ids.chat_id(foreign)}#1") }
      # Same id under a different gap: the first inference still heads its
      # singleton cluster, so the id remains VALID - no error, different members.
      split = ChatAnalyst.activity_cluster(parent, cluster[:cluster_id], max_gap_seconds: 1)
      assert_equal 1, split.length, 'gap 1s splits parent/worker into singletons'
    end
  end

  def test_tool_call_record_fields_inference_target_and_source_kind
    TmpFile.with_dir do |dir|
      worker = make_job(dir, 'Worker/ask/Default_w')
      parent = write_chat(dir, 'parent.chat',
        "user: go\n" +
        'meta: pt=1 ct=1 tt=2 inference_id=p1 timestamp=2026-10-08T10:00:00Z' + "\n" +
        'function_call: ' + %({"name":"ask","arguments":{"agent":"Worker","conversation":"review"},"id":"a1"}) + "\n" +
        'function_call_output: ' + %({"name":"ask","content":"ok","id":"a1","meta":#{[meta_receipt("job=#{worker}")].to_json}}) + "\n")
      calls = ChatAnalyst.tool_calls(parent)[:calls]
      call = calls.first
      assert_equal 'Worker', call[:target_agent], 'target split from agent#conversation'
      assert_equal 'review', call[:target_conversation]
      assert call[:delegated]
      assert call[:delegation_target] == 'Worker#review'
      # ownership (pinned): the ask call FOLLOWS the p1 meta -> emitted by p1.
      assert_equal "#{ChatAnalyst::Ids.chat_id(parent)}#1", call[:inference_id]
      # copy identity: same call id + tool + arguments earlier in the chat.
      copy_chat = write_chat(dir, 'copy.chat', [
        'user: x',
        'meta: pt=1 tt=2 inference_id=c0',
        'function_call: {"name":"bash","arguments":{"cmd":"ls"},"id":"c1"}',
        'function_call_output: {"name":"bash","content":"a","id":"c1"}',
        'function_call: {"name":"bash","arguments":{"cmd":"ls"},"id":"c1"}',
        'function_call_output: {"name":"bash","content":"a","id":"c1"}'
      ].join("\n") + "\n")
      copies = ChatAnalyst.tool_calls(copy_chat)[:calls]
      assert_equal 2, copies.length
      assert_equal :primary, copies[0][:source_kind]
      assert_equal :copy, copies[1][:source_kind]
      assert_equal copies[0][:call_index], copies[1][:copy_of]
      assert_equal "#{ChatAnalyst::Ids.chat_id(copy_chat)}#1", copies[1][:inference_id],
                   'both copies emitted by the same preceding meta'
    end
  end

  def test_inferences_are_tree_wide_and_chronological
    TmpFile.with_dir do |dir|
      path = chain_chat(dir)
      records = ChatAnalyst.inferences(path)
      assert_equal %w[2026-10-08T10:00:00Z 2026-10-08T10:01:00Z 2026-10-08T10:02:00Z],
                   records.map { |record| record[:timestamp] }
      # Undated inferences sort last, deterministically.
      undated = write_chat(dir, 'u2.chat', "user: z\nmeta: pt=1 tt=2 inference_id=z1\n")
      File.write(undated + '.info', {status: 'done', type: 'chat', dependencies: []}.to_json)
      # Not referenced by path - link it through a job reference instead:
      linked = write_chat(dir, 'linked.chat',
        "user: go\n" +
        'function_call: ' + %({"name":"ask","arguments":{"agent":"U"},"id":"k1"}) + "\n" +
        'function_call_output: ' + %({"name":"ask","content":"ok","id":"k1","meta":#{[meta_receipt("job=#{undated}")].to_json}}) + "\n" +
        "meta: pt=1 ct=1 tt=2 inference_id=l1 timestamp=2026-10-08T10:00:30Z\n")
      records = ChatAnalyst.inferences(linked)
      # l1@10:00:30 dated, z1 undated -> z1 last.
      assert records.last[:timestamp].nil?
      assert records.first[:timestamp] == '2026-10-08T10:00:30Z'
    end
  end

  def test_reasoning_never_leaves_as_content
    TmpFile.with_dir do |dir|
      path = write_chat(dir, 'reason.chat',
        "user: q\nmeta: pt=1 tt=2 inference_id=r1 reas=" + 'X' * 500 + "\n")
      records = ChatAnalyst.inferences(path)
      record = records.first
      assert record[:reasoning_present]
      assert_equal 500, record[:reasoning_characters]
      assert_nil record[:reasoning], 'no reasoning text in the record'
      flattened = JSON.generate(record)
      assert !flattened.include?('XXXX'), 'no reasoning content leaked into any field'
    end
  end

  def test_max_gap_validation_and_cache_reuse
    TmpFile.with_dir do |dir|
      path = chain_chat(dir)
      assert_raise(ArgumentError) { ChatAnalyst.inferences(path, max_gap_seconds: 0) }
      assert_raise(ArgumentError) { ChatAnalyst.inferences(path, max_gap_seconds: 'x') }
      a = ChatAnalyst.activity_clusters(path)
      assert ChatAnalyst::INFERENCE_CACHE.any?, 'computation cached'
      b = ChatAnalyst.activity_clusters(path)
      assert_equal a, b, 'second call is a deep-copied cache hit'
      # Mutating the returned records must not corrupt the cache.
      b[:clusters].first[:inference_count] = 99_999
      c = ChatAnalyst.activity_clusters(path)
      assert_equal a[:clusters].first[:inference_count], c[:clusters].first[:inference_count]
      # Different max_gap_seconds is a different computation (cluster of one).
      tight = ChatAnalyst.activity_clusters(path, max_gap_seconds: 30)
      assert_equal 3, tight[:summary][:clusters], 'one-minute gaps split under max_gap 30'
    end
  end

  def test_chronological_cluster_field_sums
    TmpFile.with_dir do |dir|
      path = chain_chat(dir)
      clusters = ChatAnalyst.activity_clusters(path)
      cluster = clusters[:clusters].first
      # All three inferences within 120s -> one cluster, 3 inferences,
      # 3 calls (2 from i1, 1 from i2), 0 delegated in this fixture.
      assert_equal 1, clusters[:summary][:clusters]
      assert_equal 3, cluster[:inference_count]
      assert_equal 4, cluster[:tool_call_count], 's1+r1 (i1) + w1 (i2) + b1 (i3)'
      assert_equal 0, cluster[:delegation_count]
      assert_equal 120.0, cluster[:duration_seconds]
    end
  end
end
