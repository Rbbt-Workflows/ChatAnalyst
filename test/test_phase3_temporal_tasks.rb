$LOAD_PATH.unshift '.'
require 'test/test_helper'
require 'test/scout/agent_meta_fixtures'
require 'stringio'

# Phase 3 bout 4 (plan steps 4-5): the temporal/provenance TSV surface.
# Covers every task converted or landed this bout against the frozen
# contract (research/phase3-contract.md as amended C1-C3):
#   chat_overview / chat_messages / chat_range / chat_message / job_overview /
#   chat_references / job_dependencies / job_dependencies_recursive /
#   chat_role_counts / chat_inferences / chat_activity_clusters /
#   chat_activity_cluster
# plus the chat_timeline retirement pin (TaskNotFound) and the
# raw-input-retired behavior pin for chat_range.
#
# Per-task checks: output type and #: metadata (key_field, fields, cast,
# annotations incl. pagination), key uniqueness (build_table raises),
# FK resolution (message ids parse back and index in range; cluster ids
# equal their cluster's first inference id; job paths canonical),
# pagination semantics (page beyond end -> empty rows; total counts the
# unpaginated universe; filters do not change totals), and absence of
# text payloads (no message/reasoning/argument content in any cell).
class TestPhase3TemporalTasks < Test::Unit::TestCase
  include ChatAnalystFixtures

  TS = ChatAnalyst::TSVBase
  IDS = ChatAnalyst::Ids

  def setup
    # Test::Unit setup blocks run in definition order; the harness block in
    # test_helper (which creates @__test_dir) runs first, but defining ANY
    # setup method in a subclass REPLACES the inherited block-list contract
    # in this suite's usage, so create the directory defensively here too.
    @__test_dir ||= File.expand_path(Scout.tmp.chatanalyst_test.to_s)
    FileUtils.mkdir_p(@__test_dir)
    # One deterministic fixture tree shared by the task tests: a chat-typed
    # Worker job (result file IS a chat carrying a timestamped inference
    # meta), a parent chat (user, ask call, output with a job= receipt,
    # parent meta with timestamp, assistant), and a later chat importing the
    # parent. The pre-meta ask call is unassociated by the pinned EMITTER
    # rule; a second Worker job (non-chat result) serves job_overview.
    @dir = File.join(@__test_dir, 'tree')
    FileUtils.mkdir_p(@dir)

    # chat-typed Worker job: its RESULT file is itself a chat (type 'chat'
    # in .info), so the overview follows it and its inference meta joins the
    # tree-wide universe (the same shape as the n2 job-root fixture).
    @worker_chat = write_chat(@dir, 'Worker/ask/Default_w.chat',
                              "user: work\n" \
                              "meta: pt=100 ct=50 tt=150 inference_id=w1 reas=worker thought about it timestamp=2026-02-03T11:00:00.000Z\n" \
                              "assistant: delegated answer\n")
    File.write(@worker_chat + '.info', {dependencies: [], type: 'chat'}.to_json)
    # non-chat Worker job (log chats only, unreachable result) for the
    # job_overview/job_dependencies surface
    @worker = make_job(@dir, 'Worker/ask/Default_w2', force_info: true,
                       logs: {'agent.chat' => "user: w\nmeta: pt=1\nassistant: d\n"})
    receipt = meta_receipt("job=#{@worker_chat} pt=1 ct=1 tt=2 inference_id=p1")
    output = {name: 'ask', content: 'child answer', id: 'a1', meta: [receipt]}.to_json
    # canonical persisted layout (bout-3 pin): the inference meta precedes
    # the response segment it accounts for — META, [assistant], [calls],
    # [outputs] — so the ask call at index 2 is EMITTED by the meta at
    # index 1 (the pinned ownership rule gives it a positive owner).
    @parent = write_chat(@dir, 'parent.chat',
                         "user: Run the worker\n" \
                         "meta: pt=3 ct=2 tt=6 inference_id=p1 reas=parent reasoning happened timestamp=2026-02-03T11:00:05.000Z\n" \
                         'function_call: ' + %({"name":"ask","arguments":{"agent":"Worker"},"id":"a1"}) + "\n" \
                         "function_call_output: #{output}\n" \
                         "assistant: done\n")
    @second = write_chat(@dir, 'second.chat',
                         "import: #{@parent}\n" +
                         "user: later\n" +
                         "meta: pt=1 ct=1 tt=2 inference_id=s1 timestamp=2026-02-03T19:00:00.000Z\n" +
                         "assistant: later done\n")
  end

  # ---- shared assertions ---------------------------------------------------

  # :list rows are Arrays; index by field name for readable assertions
  def row_for(table, key)
    fields = table.fields
    values = table[key]
    fields.each_with_index.to_h { |f, i| [f, values[i]] }
  end

  def assert_no_payload(table)
    table.each do |key, values|
      ([key] + values).each do |cell|
        next if cell.nil?
        refute_includes cell.to_s, 'Run the worker'
        refute_includes cell.to_s, 'delegated answer'
        refute_includes cell.to_s, 'child answer'
        refute_includes cell.to_s, 'worker thought'
        refute_includes cell.to_s, 'parent reasoning'
      end
    end
  end

  def assert_message_fk(id, chat_path)
    path, index = IDS.parse_message_id(id)
    assert_equal chat_path, path
    chat = Chat.load(chat_path)
    assert_operator index, :<, chat.length, "#{id} indexes in range"
  end

  # ---- A. chat_overview ----------------------------------------------------

  def test_chat_overview_tsv_shape_and_annotations
    result = ChatAnalyst.job(:chat_overview, {file: @parent}).run
    assert_equal :list, result.type
    assert_equal 'Chat', result.key_field
    assert_equal %w[messages references warnings], result.fields
    # the parent chat + the chat-typed worker result chat (2 rows)
    assert_equal 2, result.length

    key = IDS.chat_id(@parent)
    assert_equal ['5', '2', '0'], result[key]

    options = result.options
    assert_equal IDS.escape_path(@parent), options[:root_path]
    assert_equal 2, options[:total]
    assert_equal 2, options[:chats]
    assert_equal 1, options[:jobs]
    assert_equal 1, options[:delegations]
    assert_no_payload(result)
  end

  def test_chat_overview_counts_job_references_and_delegations_not_relationships
    result = ChatAnalyst.job(:chat_overview, {file: @second}).run
    # second.chat imports parent.chat (relationship reference, NOT counted)
    # and has no job references or delegations of its own
    row = result[IDS.chat_id(@second)]
    assert_equal '0', row_for(result, IDS.chat_id(@second))['references']
    assert_equal 0, result.options[:jobs]
  end

  # ---- A. job_overview / job_dependencies / job_dependencies_recursive -----

  def test_job_overview_rows_and_annotations
    result = ChatAnalyst.job(:job_overview, {file: @parent}).run
    assert_equal 'Job', result.key_field
    assert_equal %w[result_chat dependency_count live_log_count], result.fields
    assert_equal 1, result.length

    key = IDS.job_id(@worker_chat)
    assert_equal [TS.path(@worker_chat), '0', '0'], result[key]
    assert_equal IDS.escape_path(@parent), result.options[:root_path]
    assert_equal 1, result.options[:total]
  end

  def test_job_overview_job_root_included_when_root_is_job
    result = ChatAnalyst.job(:job_overview, {file: @worker}).run
    keys = result.keys
    assert_includes keys, IDS.job_id(@worker), 'job root is a row when the root is a job'
  end

  def test_job_dependencies_direct_edges
    dep = make_job(@dir, 'Dep/load/Default_1')
    File.write(@worker_chat + '.info', {dependencies: [dep], type: 'chat'}.to_json)
    result = ChatAnalyst.job(:job_dependencies, {file: @parent}).run
    assert_equal 'Dependency', result.key_field
    assert_equal %w[owner_job dependency position], result.fields

    owner = IDS.job_id(@worker_chat)
    dependency = IDS.job_id(dep)
    expected_key = [owner, dependency, '1'] * '#'
    assert_equal [owner, TS.path(dep), '1'], result[expected_key]
    assert_equal 1, result.options[:total]
  end

  def test_job_dependencies_recursive_chain_diamond_and_cycle
    a = make_job(@dir, 'Rec/A/Default_1')
    b = make_job(@dir, 'Rec/B/Default_1', dependencies: [a])
    c = make_job(@dir, 'Rec/C/Default_1', dependencies: [b])
    d = make_job(@dir, 'Rec/D/Default_1', dependencies: [c, b])
    # close the cycle: A -> D
    File.write(a + '.info', {dependencies: [d]}.to_json)

    result = ChatAnalyst.job(:job_dependencies_recursive, {file: d}).run
    assert_equal 'Dependency', result.key_field
    assert_equal %w[dependency depth via_owner], result.fields

    # every dependency appears exactly once, at its SMALLEST depth, keyed
    # dependency#depth; cycle terminates
    assert_equal 3, result.length, "closure rows: #{result.keys.inspect}"
    c_key = [TS.path(c), '1'] * '#'
    b_key = [TS.path(b), '1'] * '#'
    a_key = [TS.path(a), '2'] * '#'
    assert_equal [TS.path(c), '1', TS.path(d)], result[c_key]
    assert_equal [TS.path(b), '1', TS.path(d)], result[b_key], 'B via D at depth 1 (declared order), not via C at depth 2'
    assert_equal [TS.path(a), '2', TS.path(b)], result[a_key], 'A via B at depth 2'
    # D itself never appears as a row even though A -> D closes the cycle
    refute result.keys.any? { |key| IDS.parse_composite(key, 2).first == TS.path(d) }
    refute_includes result.keys, [TS.path(d), '1'] * '#'
  end

  # The CHAT-root seeding path (rehearsal chain 3, bout 7): a chat root seeds
  # from the root chat's job references; the pre-fix spelling called
  # Array(hash).values and raised NoMethodError for every chat root.
  def test_job_dependencies_recursive_chat_root_seeding
    dep = make_job(@dir, 'Seed/A/Default_1')
    dep2 = make_job(@dir, 'Seed/B/Default_1', dependencies: [dep])
    worker_chat = write_chat(@dir, 'Seed/worker.chat',
                             "user: seed work\n" \
                             "meta: pt=1 inference_id=sw1\n" \
                             "assistant: seeded\n")
    File.write(worker_chat + '.info', {dependencies: [dep2], type: 'chat'}.to_json)
    receipt = meta_receipt("job=#{worker_chat} pt=1 ct=1 tt=2 inference_id=sp1")
    output = {name: 'ask', content: 'seeded answer', id: 's1', meta: [receipt]}.to_json
    parent = write_chat(@dir, 'Seed/parent.chat',
                        "user: Run the seeder\n" \
                        "meta: pt=3 ct=2 tt=6 inference_id=sp1\n" \
                        'function_call: ' + %({"name":"ask","arguments":{"agent":"Seed"},"id":"s1"}) + "\n" \
                        "function_call_output: #{output}\n")

    result = ChatAnalyst.job(:job_dependencies_recursive, {file: parent}).run
    # the parent chat references the worker job (seed, depth 0); its
    # dependency dep2 is depth 1; dep is depth 2; the seed itself never rows
    assert_equal 2, result.length, "chat-root closure rows: #{result.keys.inspect}"
    depths = result.values.collect { |row| row[1] }
    assert_equal %w[1 2], depths.sort
    refute result.keys.any? { |key| key.include?('worker') }, 'seed job never becomes a row'
  end

  def test_job_dependencies_recursive_max_depth_cap
    a = make_job(@dir, 'Cap/A/Default_1')
    b = make_job(@dir, 'Cap/B/Default_1', dependencies: [a])
    c = make_job(@dir, 'Cap/C/Default_1', dependencies: [b])
    d = make_job(@dir, 'Cap/D/Default_1', dependencies: [c])

    result = ChatAnalyst.job(:job_dependencies_recursive, {file: d, max_depth: 1}).run
    assert_equal 1, result.length
    assert_equal ['1'], result.values.collect { |row| row[1] }.uniq
    assert_equal 'Cap/C/Default_1', IDS.unescape_path(result.keys.first.split('#').first)
                     .split('/')[-3..].join('/'), "first closure row is C (D's only dependency): #{result.keys.inspect}"

    assert_raise(ParameterException) do
      ChatAnalyst.job(:job_dependencies_recursive, {file: d, max_depth: 0}).run
    end
  end

  # ---- A. chat_references ---------------------------------------------------

  def test_chat_references_rows_and_occurrence_keys
    result = ChatAnalyst.job(:chat_references, {file: @parent}).run
    assert_equal 'Reference', result.key_field
    assert_equal %w[source_message_id reference_type target_kind target_id resolved unresolved_reason], result.fields

    delegation_key = [IDS.message_id(@parent, 2), 'delegation', '1'] * '#'
    assert_equal [IDS.message_id(@parent, 2), 'delegation', 'agent', 'Worker#default', 'true', '\N'],
                 result[delegation_key]

    job_key = [IDS.message_id(@parent, 3), 'job_reference', '1'] * '#'
    assert_equal [IDS.message_id(@parent, 3), 'job_reference', 'job', TS.path(@worker_chat), 'true', '\N'],
                 result[job_key]
    assert_equal 2, result.options[:total]
    assert_no_payload(result)
  end

  def test_chat_references_relationship_types_and_unresolved
    result = ChatAnalyst.job(:chat_references, {file: @second}).run
    # the import: message resolves to parent.chat
    import_key = [IDS.message_id(@second, 0), 'import', '1'] * '#'
    row = row_for(result, import_key)
    assert_equal 'chat', row['target_kind']
    assert_equal 'true', row['resolved']
    assert_equal '\N', row['unresolved_reason']

    # a missing local import target stays listed with reason missing
    missing = write_chat(@dir, 'missing.chat', "import: /nonexistent/path.chat\nuser: x\n")
    result = ChatAnalyst.job(:chat_references, {file: missing}).run
    key = [IDS.message_id(missing, 0), 'import', '1'] * '#'
    missing_row = row_for(result, key)
    assert_equal ['false', 'missing'], missing_row.values_at('resolved', 'unresolved_reason')
  end

  # ---- A. chat_role_counts ---------------------------------------------------

  def test_chat_role_counts_composite_keys_and_native_cast
    result = ChatAnalyst.job(:chat_role_counts, {file: @parent}).run
    assert_equal 'ChatRole', result.key_field
    assert_equal %w[count], result.fields
    assert_equal :to_i, result.options[:cast]

    parent_row = result[[IDS.chat_id(@parent), 'user'] * '#']
    # the in-process build_table table holds plain Strings; the :to_i cast
    # applies when the persisted file is re-opened (TSV.open of job text)
    assert_equal '1', parent_row.first

    job = ChatAnalyst.job(:chat_role_counts, {file: @parent})
    job.run
    reopened = TSV.open(job.path)
    assert_equal 1, reopened[[IDS.chat_id(@parent), 'user'] * '#'].first
    assert_equal 1, reopened[[IDS.chat_id(@parent), 'meta'] * '#'].first
    assert Integer === reopened.values.first.first, "native :to_i cast on read-back: #{reopened.values.first.inspect}"
    # parent (5 messages: user/meta/call/output/assistant) + worker chat (3)
    assert_equal 8, reopened.values.collect { |row| row.first }.sum, reopened.to_h.inspect
  end

  # ---- B. chat_messages -------------------------------------------------------

  def test_chat_messages_tsv_shape_and_fk_resolution
    result = ChatAnalyst.job(:chat_messages, {file: @parent}).run
    assert_equal 'Message', result.key_field
    assert_equal %w[role characters timestamp large], result.fields

    assert_equal ['user', '14', '\N', 'false'], result[IDS.message_id(@parent, 0)]
    meta_row = result[IDS.message_id(@parent, 1)]
    assert_equal '2026-02-03T11:00:05.000Z', row_for(result, IDS.message_id(@parent, 1))['timestamp']

    result.keys.each { |id| assert_message_fk(id, @parent) }
    assert_no_payload(result)
    assert_equal 5, result.options[:total]
  end

  def test_chat_messages_pagination_and_role_filter
    all = ChatAnalyst.job(:chat_messages, {file: @parent}).run
    paged = ChatAnalyst.job(:chat_messages, {file: @parent, page: 1, per_page: 2}).run
    assert_equal 2, paged.length
    assert_equal 5, paged.options[:total], 'total counts the unpaginated universe'
    assert_equal 3, paged.options[:total_pages]
    assert_equal 2, paged.options[:next_page]

    beyond = ChatAnalyst.job(:chat_messages, {file: @parent, page: 99}).run
    assert_equal 0, beyond.length
    assert_equal 5, beyond.options[:total], 'out-of-range page: empty rows, total unchanged'

    only_user = ChatAnalyst.job(:chat_messages, {file: @parent, role: 'user'}).run
    assert_equal 1, only_user.length
    # the role filter narrows the LIST only; total counts the raw chat
    assert_equal 5, only_user.options[:total]
  end

  # ---- B. chat_message / chat_range (:chat outputs) ---------------------------

  def test_chat_message_returns_one_byte_exact_message
    id = IDS.message_id(@parent, 0)
    result = ChatAnalyst.job(:chat_message, {message_id: id}).run
    reloaded = Chat.parse(result)
    assert_equal 1, reloaded.length
    assert_equal 'user', reloaded.first[:role].to_s
    assert_equal 'Run the worker', reloaded.first[:content]

    single = ChatAnalyst.job(:chat_message, {message_id: IDS.message_id(@parent, 4)}).run
    assert_equal 1, Chat.parse(single).length
  end

  def test_chat_message_errors
    assert_raise(ParameterException) do
      ChatAnalyst.job(:chat_message, {message_id: @parent + '#999'}).run
    end
    assert_raise(ParameterException) do
      ChatAnalyst.job(:chat_message, {message_id: 'not-a-message-id'}).run
    end
  end

  def test_chat_range_chat_output_byte_exactness_and_cap
    result = ChatAnalyst.job(:chat_range, {file: @parent, first: 0, last: 1}).run
    reloaded = Chat.parse(result)
    assert_equal 2, reloaded.length
    assert_equal 'Run the worker', reloaded.first[:content]

    # single-message slice: first == last
    single = ChatAnalyst.job(:chat_range, {file: @parent, first: 4, last: 4}).run
    assert_equal 1, Chat.parse(single).length

    # byte-exactness: the slice equals Chat.print of the same messages
    chat = Chat.load(@parent)
    assert_equal Chat.print([chat[0], chat[1]]), result

    # the raw INPUT is retired: passing raw raises (unknown input ignored or
    # error) and the output is ALWAYS the exact text (no envelope)
    refute result.is_a?(Hash), ':chat output carries no JSON envelope'

    # cap boundary
    big_text = (0...300).collect { |i| "user: m#{i}\n" }.join
    big = write_chat(@dir, 'big.chat', big_text)
    at_cap = ChatAnalyst.job(:chat_range, {file: big, first: 0, last: 199}).run
    assert_equal 200, Chat.parse(at_cap).length

    error = assert_raise(ParameterException) do
      ChatAnalyst.job(:chat_range, {file: big, first: 0, last: 200}).run
    end
    assert_match(/at most 200/, error.message)
  end

  def test_chat_range_rejects_job_roots
    # a persisted Step root (.info sidecar) is a JOB root: range addressing
    # is chat-file-only, so the job root is rejected even though its file
    # exists
    error = assert_raise(ParameterException) do
      ChatAnalyst.job(:chat_range, {file: @worker, first: 0, last: 1}).run
    end
    assert_match(/chat file root/, error.message)
  end

  def test_chat_range_addressing_lives_in_job_inputs
    # the :chat-metadata gap resolution (contract 1f amendment): a :chat
    # output carries no '#:' line, so the slice addressing (file/first/last)
    # lives in the persisted JOB INPUTS (step.info pairs inputs with
    # input_names), recoverable by any consumer of the job
    job = ChatAnalyst.job(:chat_range, {file: @parent, first: 1, last: 2})
    job.run
    step = Step.load(job.path)
    inputs = step.info[:input_names].zip(step.info[:inputs]).to_h
    assert_equal @parent, inputs['file']
    assert_equal 1, inputs['first']
    assert_equal 2, inputs['last']

    message_job = ChatAnalyst.job(:chat_message, {message_id: IDS.message_id(@parent, 3)})
    message_job.run
    message_step = Step.load(message_job.path)
    message_inputs = message_step.info[:input_names].zip(message_step.info[:inputs]).to_h
    assert_equal IDS.message_id(@parent, 3), message_inputs['message_id']
  end

  # ---- B. chat_inferences ------------------------------------------------------

  def test_chat_inferences_root_scoped_fields_and_fk
    result = ChatAnalyst.job(:chat_inferences, {file: @parent}).run
    assert_equal 'Inference', result.key_field
    assert_equal %w[timestamp reasoning_present reasoning_characters
                    first_message_id last_message_id trigger_message_id
                    assistant_message_id activity_cluster_id tool_call_count],
                 result.fields

    # two inferences tree-wide: parent meta (11:00:05) + worker log meta
    # (11:00:00), chronological order (worker first)
    assert_equal 2, result.length
    assert_equal IDS.message_id(@worker_chat, 1), result.keys.first

    worker_row = result.values.first
    assert_equal '2026-02-03T11:00:00.000Z', row_for(result, result.keys.first)['timestamp']
    assert_equal 'true', row_for(result, result.keys.first)['reasoning_present']
    assert row_for(result, result.keys.first)['reasoning_characters'].to_i > 0

    # FK columns parse back and index in range in their own chats
    result.each do |_key, row|
      by_name = row_for(result, _key)
      assert_message_fk(by_name['first_message_id'], IDS.unescape_path(by_name['first_message_id'].split('#').first))
      assert_message_fk(by_name['last_message_id'], IDS.unescape_path(by_name['last_message_id'].split('#').first))
    end
    assert_no_payload(result)
    assert_equal 120, result.options[:max_gap_seconds]
  end

  def test_chat_inferences_chat_filter_narrows_only
    all = ChatAnalyst.job(:chat_inferences, {file: @parent}).run
    filtered = ChatAnalyst.job(:chat_inferences, {file: @parent, chat: @parent}).run
    assert_equal 2, all.length
    assert_equal 1, filtered.length
    assert_equal 2, filtered.options[:total], 'filter narrows the list; total counts the filtered list'

    paged = ChatAnalyst.job(:chat_inferences, {file: @parent, page: 1, per_page: 1}).run
    assert_equal 1, paged.length
    assert_equal 2, paged.options[:total]
  end

  # ---- C. chat_activity_clusters / chat_activity_cluster ------------------------

  def test_activity_clusters_compact_index
    result = ChatAnalyst.job(:chat_activity_clusters, {file: @parent}).run
    assert_equal 'Cluster', result.key_field
    assert_equal %w[first_timestamp last_timestamp duration_seconds inference_count
                    chats tool_call_count delegation_count], result.fields

    # the two inferences are 5s apart -> ONE cluster spanning both chats
    assert_equal 1, result.length
    cluster_id = result.keys.first
    row = row_for(result, cluster_id)
    assert_equal IDS.message_id(@worker_chat, 1), cluster_id, 'cluster id = first inference id'
    assert_equal '2026-02-03T11:00:00.000Z', row['first_timestamp']
    assert_equal '2026-02-03T11:00:05.000Z', row['last_timestamp']
    assert_equal '5.0', row['duration_seconds']
    assert_equal '2', row['inference_count']
    assert_equal 2, TS.unmulti(row['chats']).length
    assert_equal '1', row['tool_call_count'], 'the ask call belongs to the emitting parent inference'
    assert_equal '1', row['delegation_count']

    options = result.options
    assert_equal 1, options[:clusters]
    assert_equal 2, options[:inferences]
    assert_equal 0, options[:unclustered]
    assert_equal 120, options[:max_gap_seconds]
    # COMPACT INDEX ONLY: no member lists anywhere
    result.each { |_key, values| refute values.any? { |v| v.include?('#0,') || v.include?('member') } }
  end

  def test_activity_clusters_gap_creates_two_clusters_and_undated_stays_out
    # a tiny max_gap splits the 5s-spaced pair into two clusters
    result = ChatAnalyst.job(:chat_activity_clusters, {file: @parent, max_gap_seconds: 2}).run
    cluster_ids = result.keys
    assert_equal 2, cluster_ids.length, 'the 5s gap exceeds max_gap 2: two clusters'
    assert_equal 2, result.options[:clusters]
    assert_equal 2, result.options[:inferences]

    # second.chat is its OWN universe (imports are relationship references
    # the provenance traversal never follows)
    second_result = ChatAnalyst.job(:chat_activity_clusters, {file: @second}).run
    assert_equal 1, second_result.length
    assert_equal 1, second_result.options[:inferences]

    # an undated inference joins no cluster
    undated = write_chat(@dir, 'undated.chat',
                         "user: no time\nmeta: pt=1 ct=1 tt=2 inference_id=u1\nassistant: done\n")
    unclustered = ChatAnalyst.job(:chat_activity_clusters, {file: undated}).run
    assert_equal 0, unclustered.length
    assert_equal 1, unclustered.options[:unclustered]
    assert_equal 1, unclustered.options[:inferences]
  end

  def test_activity_cluster_detail_uses_dependency_on_same_index_job
    index_job = ChatAnalyst.job(:chat_activity_clusters, {file: @parent})
    index_job.run
    cluster_id = index_job.run.keys.first

    detail_job = ChatAnalyst.job(:chat_activity_cluster, {file: @parent, cluster_id: cluster_id})
    detail_job.run

    # the DEP pattern: the detail task's dependency IS the same cluster
    # index job (same inputs -> same jobname), so the SAME computation
    # produced index and members
    dependency = detail_job.dependencies.first
    assert_equal :chat_activity_clusters, dependency.task_name
    assert_equal index_job.path, dependency.path, 'dep reuses the standalone index job'

    detail = detail_job.run
    assert_equal 2, detail.length
    assert detail.keys.include?(cluster_id)
    detail.keys.each do |inference_id|
      assert_equal cluster_id, row_for(detail, inference_id)['activity_cluster_id']
    end
    assert_equal detail.keys, detail.keys.sort_by { |id| row_for(detail, id)['timestamp'] }, 'chronological order'

    # field list identical to chat_inferences
    inferences = ChatAnalyst.job(:chat_inferences, {file: @parent}).run
    assert_equal inferences.fields, detail.fields
  end

  def test_activity_cluster_unknown_id_raises
    assert_raise(ParameterException) do
      ChatAnalyst.job(:chat_activity_cluster, {file: @parent, cluster_id: '/nope/chat.chat#42'}).run
    end
  end

  def test_chat_timeline_retired
    error = assert_raise(TaskNotFound) do
      ChatAnalyst.job(:chat_timeline, {file: @parent}).run
    end
    assert_match(/chat_timeline/, error.message)
    refute ChatAnalyst.tasks.key?(:chat_timeline)
  end

  private
end
