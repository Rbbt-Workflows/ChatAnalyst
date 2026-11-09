$LOAD_PATH.unshift '.'
require File.expand_path(File.join(File.dirname(__FILE__), 'test_helper'))
require 'test/scout/n2_job_root_fixture'
require 'ChatAnalyst/api'
require 'tmpdir'
require 'fileutils'
require 'json'

# Bout 2 (Stage 1 skeleton + Stage 2 overview + Stage 3 retrieval) of the
# ChatAnalyst redesign: the public Ruby API in lib/ChatAnalyst/api.rb.
#
# These tests pin the API contract against the offline fixture family in
# test/scout/agent_meta_fixtures.rb plus local scenario layouts:
# - overview: one Chat.provenance_graph call per node, visited keyed on
#   (type, canonical path), job roots contribute only the generated output
#   chat, live listed never traversed, dependencies with order/owner,
#   cycles and repeated references terminate.
# - message_index/message/range: zero-based, inclusive ranges, single-chat
#   loading, useful errors, character counts only (no bodies in the index).
# - all nine methods are implemented and raise no stage-labeled stubs.
# - no Chat/Step/Path instance appears anywhere in a public result.
class TestChatAnalystApi < Test::Unit::TestCase
  def setup
    @dir = Dir.mktmpdir('chat_analyst_api')
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  # -- Phase A canary: gem-shadowing trap ---------------------------------------
  #
  # scout-ai doc/developer/Provenance.md: the installed scout-ai 2.0.0 gem
  # predates provenance_graph/live_report, so every run must resolve the
  # checkout explicitly (-I<scout-ai-checkout>/lib).  Fail loudly here when
  # the gem shadows the checkout instead of failing obscurely downstream.
  def test_scout_ai_core_provides_the_compact_provenance_api
    assert Chat.respond_to?(:provenance_graph),
           'Chat.provenance_graph missing: the scout-ai 2.0.0 gem shadowed the checkout (run with -I<scout-ai-checkout>/lib)'
    assert Chat.respond_to?(:provenance_token_events),
           'Chat.provenance_token_events missing: gem shadowing'
    assert Chat.respond_to?(:live_report),
           'Chat.live_report missing: gem shadowing'
  end

  # -- Stage 1: signatures and stubs -----------------------------------------

  def test_nine_public_methods_exist_with_exact_signatures
    %w[overview timeline message_index message range tool_calls tokens
       relationships live].each do |name|
      assert ChatAnalyst.respond_to?(name), "#{name} must be a public module method"
    end

    # Exact signatures: (root, root_type:) / (root, bursts:, burst_gap:) /
    # (chat_path) / (chat_path, index) / (chat_path, first, last) /
    # (chat_path, first:, last:) / (root) / (chat_path) / (root).
    parameters = ChatAnalyst.method(:overview).parameters
    assert_equal %i[req key], parameters.collect(&:first), 'overview(root, root_type: nil)'
    assert_equal :root_type, parameters[1][1]

    parameters = ChatAnalyst.method(:timeline).parameters
    assert_equal %i[req key key], parameters.collect(&:first), 'timeline(root, bursts:, burst_gap:)'

    assert_equal %i[req], ChatAnalyst.method(:message_index).parameters.collect(&:first)
    assert_equal %i[req req], ChatAnalyst.method(:message).parameters.collect(&:first)
    assert_equal %i[req req req], ChatAnalyst.method(:range).parameters.collect(&:first)

    parameters = ChatAnalyst.method(:tool_calls).parameters
    assert_equal %i[req key key], parameters.collect(&:first), 'tool_calls(chat_path, first:, last:)'

    assert_equal %i[req], ChatAnalyst.method(:tokens).parameters.collect(&:first)
    assert_equal %i[req], ChatAnalyst.method(:relationships).parameters.collect(&:first)
    assert_equal %i[req], ChatAnalyst.method(:live).parameters.collect(&:first)
  end

  def test_all_nine_methods_are_implemented
    # Phase C implemented tokens, relationships and live (Stage 6); no stub
    # remains, so the surface may not regress to stage-labeled errors.  A
    # nonexistent path raises ArgumentError (from resolve/load), never
    # NotImplementedError.
    {tokens: ['/nonexistent.chat'],
     relationships: ['/nonexistent.chat'],
     live: ['/nonexistent.chat']}.each do |method, args|
      error = assert_raise(ArgumentError) { ChatAnalyst.public_send(method, *args) }
      refute_match(/NotImplementedError/, error.class.to_s)
    end
  end

  # -- Stage 2: overview ------------------------------------------------------

  def test_triplet_chat_overview_anchors_meta_zero_based
    chat = write_chat(@dir, 'triplet.chat', "user: q\n" +
      "meta: pt=1 ct=1 tt=2 inference_id=p1 timestamp=2026-10-08T10:00:00Z\n" +
      "assistant: done\n")
    overview = ChatAnalyst.overview(chat)

    assert_equal :chat, overview[:root][:type]
    assert_equal chat, overview[:root][:path]
    assert_equal 1, overview[:chats].length
    record = overview[:chats].first
    assert_equal chat, record[:path]
    assert_equal 3, record[:messages]
    assert_equal({'user' => 1, 'meta' => 1, 'assistant' => 1}, record[:roles])
    assert_empty record[:job_references]
    assert_empty record[:delegation_references]
    assert_empty overview[:jobs]

    # The meta message sits at zero-based index 1.
    message = ChatAnalyst.message(chat, 1)
    assert_equal 'meta', message[:role]
    assert_equal '2026-10-08T10:00:00Z', ChatAnalyst.message_index(chat)[1][:timestamp]
  end

  def test_standalone_meta_job_reference
    parent, worker = fixture_receipt_plus_log(@dir + '/plus_log')
    overview = ChatAnalyst.overview(parent)

    record = overview[:chats].find { |c| c[:path] == parent }
    assert_equal({4 => worker}, record[:job_references],
                 'standalone meta: job= anchored at its own message index 4')
    assert_equal({1 => 'Worker#default'}, record[:delegation_references])

    # The referenced job is enqueued and reported with its canonical path;
    # its sidecar agent.chat is listed as live and NEVER traversed.
    job = overview[:jobs].find { |j| j[:path] == worker }
    assert job, 'referenced job must appear as a job node'
    assert_empty job[:dependencies]
    live = job[:live].first
    assert live.end_with?('Worker/ask/Default_w.files/agent.chat')
    assert_nil overview[:chats].find { |c| c[:path] == live },
               'live sidecar chat must not become a chat node'
  end

  def test_receipt_reference_anchored_at_outer_function_call_output
    parent, worker, dep = fixture_agent_job(@dir + '/agent_job')
    overview = ChatAnalyst.overview(parent)

    record = overview[:chats].find { |c| c[:path] == parent }
    # Messages: 0 user, 1 function_call, 2 function_call_output, 3 meta,
    # 4 assistant.  The receipt job reference is anchored at index 2 (the
    # OUTER function_call_output), never at the function_call index 1.
    assert_equal({2 => worker}, record[:job_references])
    assert_equal({1 => 'Worker#default'}, record[:delegation_references])
  end

  def test_ask_without_job_is_valid_delegation
    parent = fixture_receipt_only(@dir + '/receipt_only')
    overview = ChatAnalyst.overview(parent)

    record = overview[:chats].first
    assert_empty record[:job_references], 'no job reference: ask without a job'
    assert_equal({1 => 'Worker#default'}, record[:delegation_references],
                 'the ask call is still a delegation relationship')
    assert_empty overview[:jobs]
  end

  def test_delegation_with_job_keeps_both_relations
    parent, worker, dep = fixture_agent_job(@dir + '/agent_job2')
    overview = ChatAnalyst.overview(parent)
    record = overview[:chats].find { |c| c[:path] == parent }

    assert_equal({2 => worker}, record[:job_references])
    assert_equal({1 => 'Worker#default'}, record[:delegation_references])
    assert overview[:jobs].any? { |j| j[:path] == worker }
  end

  def test_two_job_references_at_one_index_merge_into_array
    dir = @dir + '/two_refs'
    j1 = make_job(dir, 'J1/ask/Default_1', result: 'one')
    j2 = make_job(dir, 'J2/ask/Default_2', result: 'two')
    text = "user: go\n" +
      'function_call: ' + %({"name":"ask","arguments":{"agent":"Worker"},"id":"z1"}) + "\n" +
      'function_call_output: ' + %({"name":"ask","content":"ok","id":"z1","meta":#{[meta_receipt("job=#{j1}"), meta_receipt("job=#{j2}")].to_json}}) + "\n" +
      "assistant: done\n"
    chat = write_chat(dir, 'two.chat', text)

    overview = ChatAnalyst.overview(chat)
    record = overview[:chats].first
    assert_equal({2 => [j1, j2]}, record[:job_references],
                 'two refs at one index merge into an Array at that index')
    assert_equal [j1, j2].sort, overview[:jobs].collect { |j| j[:path] }.sort
  end

  def test_ordinary_response_creates_neither_reference
    chat = write_chat(@dir, 'plain.chat', "user: go\n" +
      'function_call: ' + %({"name":"search","arguments":{"path":"."},"id":"s1"}) + "\n" +
      'function_call_output: ' + %({"name":"search","content":"[]","id":"s1"}) + "\n" +
      "assistant: done\n")
    overview = ChatAnalyst.overview(chat)

    record = overview[:chats].first
    assert_empty record[:job_references]
    assert_empty record[:delegation_references]
    assert_empty overview[:jobs]
  end

  def test_job_root_counts_output_chat_and_not_input_chat
    root, child = fixture_job_root_with_delegation(@dir + '/n2')
    overview = ChatAnalyst.overview(root)

    # Exactly one chat node: the generated output chat (the job's result,
    # 3 messages, inference rr1).  The agent.chat sidecar carrying the
    # input-context transcript is listed as live and never traversed.
    assert_equal :job, overview[:root][:type]
    assert_equal 1, overview[:chats].length
    output = overview[:chats].first
    assert_equal root, output[:path]
    assert_equal 3, output[:messages]
    assert_equal({'user' => 1, 'meta' => 1, 'assistant' => 1}, output[:roles])
    assert_equal 1, overview[:jobs].length
    assert_equal root, overview[:jobs].first[:path]

    live = overview[:jobs].first[:live]
    assert live.any? { |p| p.end_with?('.files/agent.chat') }
    assert_nil overview[:chats].find { |c| live.include?(c[:path]) },
               'no live sidecar may appear as a chat node'
  end

  def test_job_and_chat_root_distinction_on_the_same_path
    root, = fixture_job_root_with_delegation(@dir + '/n2_distinct')
    as_job = ChatAnalyst.overview(root)
    as_chat = ChatAnalyst.overview(root, root_type: :chat)

    assert_equal :job, as_job[:root][:type]
    assert_equal 1, as_job[:jobs].length, 'default detection reads the .info sidecar'
    assert_equal 1, as_job[:chats].length, 'job root enqueues its generated output chat'

    assert_equal :chat, as_chat[:root][:type]
    assert_empty as_chat[:jobs], 'root_type: :chat bypasses job detection'
    assert_equal [root], as_chat[:chats].collect { |c| c[:path] }
  end

  def test_direct_dependencies_preserve_declared_order_and_owner
    dir = @dir + '/deps'
    d1 = make_job(dir, 'D1/load/Default_1')
    d2 = make_job(dir, 'D2/load/Default_2')
    worker = make_job(dir, 'W/ask/Default_w', dependencies: [d2, d1],
                                         logs: {'agent.chat' => "user: w\nassistant: done\n"})
    parent = write_chat(dir, 'parent.chat',
                        receipt_chat_text('a1' => [meta_receipt("job=#{worker}")]))
    overview = ChatAnalyst.overview(parent)

    owner = overview[:jobs].find { |j| j[:path] == worker }
    assert owner, 'the referenced job owns its dependency list'
    assert_equal [d2, d1], owner[:dependencies],
                 'declared order preserved; each dependency attributed to its owner record'
    assert_equal [], overview[:jobs].find { |j| j[:path] == d1 }[:dependencies]
    assert_equal [], overview[:jobs].find { |j| j[:path] == d2 }[:dependencies]
  end

  def test_cyclic_references_terminate
    dir = @dir + '/cycle'
    a = File.join(dir, 'A/ask/Default_a.chat')
    b = File.join(dir, 'B/ask/Default_b.chat')
    [a, b].each { |p| FileUtils.mkdir_p(File.dirname(p)) }
    File.write(a, "user: x\nmeta: job=#{b}\nassistant: a done\n")
    File.write(a + '.info', {type: 'chat', dependencies: [], status: 'done'}.to_json)
    File.write(b, "user: y\nmeta: job=#{a}\nassistant: b done\n")
    File.write(b + '.info', {type: 'chat', dependencies: [], status: 'done'}.to_json)

    overview = ChatAnalyst.overview(a)
    assert_equal 2, overview[:jobs].length, 'each job visited once (job identity)'
    assert_equal 2, overview[:chats].length, 'each transcript visited once (chat identity)'
  end

  def test_repeated_references_enqueue_once
    parent, worker = fixture_two_receipts_one_job(@dir + '/two_receipts')
    overview = ChatAnalyst.overview(parent)

    record = overview[:chats].find { |c| c[:path] == parent }
    assert_equal({2 => worker, 4 => worker}, record[:job_references])
    assert_equal 1, overview[:jobs].length, 'the same job referenced twice is enqueued once'
  end

  def test_live_listed_never_traversed_and_missing_live_tolerated
    parent, worker = fixture_receipt_plus_log(@dir + '/live')
    live = File.join(worker + '.files', 'agent.chat')

    first = ChatAnalyst.overview(parent)
    assert first[:jobs].first[:live].include?(live)
    assert_nil first[:chats].find { |c| c[:path] == live }

    # A live file that vanishes between calls is not an error and produces
    # no warning spam: the second overview simply stops listing it.
    FileUtils.rm(live)
    second = ChatAnalyst.overview(parent)
    assert_empty second[:jobs].first[:live]
    assert_nil second[:jobs].first[:warnings].find { |w| w.to_s.include?(live) }
  end

  def test_unresolved_job_reference_is_reported_not_raised
    missing = File.join(@dir, 'gone/ask/Default_gone')
    chat = write_chat(@dir, 'broken.chat', "user: x\nmeta: job=#{missing}\nassistant: y\n")
    overview = ChatAnalyst.overview(chat)

    record = overview[:chats].first
    assert_empty record[:job_references]
    assert(record[:warnings].any? { |w| w.to_s.include?('unresolved_job_reference') },
           'the core graph reports the unresolved reference')
  end

  # -- Stage 3: message index and retrieval -----------------------------------

  def test_message_index_reports_role_size_timestamp_never_bodies
    parent, = fixture_agent_job(@dir + '/agent_job_idx')
    index = ChatAnalyst.message_index(parent)

    assert_equal 5, index.length
    expected = %w[user function_call function_call_output meta assistant]
    expected.each_with_index do |role, position|
      record = index[position]
      assert_equal position, record[:index]
      assert_equal role, record[:role],
                   "role at zero-based index #{position} must be #{role.inspect}"
      assert record.keys.none? { |k| %i[content body].include?(k) },
             'the index never carries message bodies'
      assert Integer === record[:characters]
      assert(record[:characters] >= 0)
      assert(record[:timestamp].nil? || String === record[:timestamp])
    end
  end

  def test_message_index_loads_only_the_addressed_chat
    parent, worker, dep = fixture_agent_job(@dir + '/agent_job_single')
    # Dangling references must not matter: indexing one chat touches nothing else.
    FileUtils.rm_rf(worker + '.info')
    FileUtils.rm_rf(File.dirname(dep))

    index = ChatAnalyst.message_index(parent)
    assert_equal 5, index.length

    assert_equal 5, ChatAnalyst.range(parent, 0, 4)[:messages].length
  end

  def test_message_returns_exact_single_message
    content = receipt_output('a1', [meta_receipt('pt=1 ct=2 tt=3 inference_id=w1')])
    chat = write_chat(@dir, 'exact.chat', "user: go\n" +
      'function_call: ' + %({"name":"ask","arguments":{"agent":"Worker"},"id":"a1"}) + "\n" +
      'function_call_output: ' + content + "\n" +
      "assistant: done\n")

    message = ChatAnalyst.message(chat, 2)
    assert_equal 2, message[:index]
    assert_equal 'function_call_output', message[:role]
    assert_equal content, message[:content], 'exact body, zero-based index 2'
    assert_equal chat, message[:chat]
  end

  def test_range_is_inclusive_at_both_ends
    chat = write_chat(@dir, 'range.chat', "user: a\nuser: b\nuser: c\nuser: d\n")
    result = ChatAnalyst.range(chat, 1, 2)

    assert_equal chat, result[:chat]
    assert_equal 1, result[:first]
    assert_equal 2, result[:last]
    assert_equal %w[b c], result[:messages].collect { |m| m[:content] }
    assert_equal [1, 2], result[:messages].collect { |m| m[:index] }

    single = ChatAnalyst.range(chat, 3, 3)
    assert_equal ['d'], single[:messages].collect { |m| m[:content] }, 'first == last is valid'
  end

  def test_large_message_indexed_not_inlined
    big = 'x' * 150_000
    chat = write_chat(@dir, 'large.chat', "user: small\nassistant: #{big}\n")
    index = ChatAnalyst.message_index(chat)

    assert_equal 150_000, index[1][:characters], 'size reported by character count'
    assert_nil(index.find { |r| r[:content] }, 'no body inlined regardless of size')
  end

  def test_useful_errors_name_path_index_and_range
    chat = write_chat(@dir, 'errors.chat', "user: a\nuser: b\nuser: c\n")

    error = assert_raise(ArgumentError) { ChatAnalyst.message(chat, -1) }
    assert_match(/-1.*#{Regexp.escape(chat)}.*0\.\.2/, error.message)

    error = assert_raise(ArgumentError) { ChatAnalyst.message(chat, 3) }
    assert_match(/3 out of range.*#{Regexp.escape(chat)}.*0\.\.2.*3 messages/, error.message)

    error = assert_raise(ArgumentError) { ChatAnalyst.range(chat, 2, 1) }
    assert_match(/range end 1.*>= first \(2\)/, error.message)

    error = assert_raise(ArgumentError) { ChatAnalyst.range(chat, 0, 3) }
    assert_match(/0\.\.3 out of range.*#{Regexp.escape(chat)}.*0\.\.2/, error.message)

    error = assert_raise(ArgumentError) { ChatAnalyst.range(chat, -1, 2) }
    assert_match(/range start -1.*non-negative/, error.message)

    error = assert_raise(ArgumentError) { ChatAnalyst.message_index(chat + '.missing') }
    assert_match(/Chat not found/, error.message)
  end

  def test_returned_paths_are_directly_usable
    parent, = fixture_agent_job(@dir + '/agent_job_reuse')
    overview = ChatAnalyst.overview(parent)

    path = overview[:chats].first[:path]
    assert_equal String, path.class
    assert_equal 5, ChatAnalyst.message_index(path).length, 'no translation needed'

    job_path = overview[:jobs].first[:path]
    assert Step.load(job_path).is_a?(Step), 'job paths are Step.load-able as returned'
  end

  # -- serializer discipline ---------------------------------------------------

  def test_no_chat_or_step_instances_in_public_results
    parent, worker, dep = fixture_agent_job(@dir + '/agent_job_serial')
    results = {
      overview: ChatAnalyst.overview(parent),
      overview_job_root: ChatAnalyst.overview(worker, root_type: :job),
      message_index: ChatAnalyst.message_index(parent),
      message: ChatAnalyst.message(parent, 2),
      range: ChatAnalyst.range(parent, 0, 1)
    }

    results.each do |name, result|
      assert JSON.generate(result), "#{name} must be JSON-serializable"
      offenders = []
      walk_plain(result) do |node, trail|
        case node
        when Hash, Array, String, Integer, Float, TrueClass, FalseClass, NilClass, Symbol
          offenders << [trail, Path] if Path === node
        else
          offenders << [trail, node.class]
        end
      end
      assert_empty offenders.map { |t, c| "#{c} at #{t}" },
                   "#{name} leaked non-plain objects: #{offenders.inspect[0, 300]}"
    end
  end

  private

  # Recursive walk collecting every leaf and container; yields (node, trail).
  def walk_plain(node, trail = '$', &block)
    block.call(node, trail)
    case node
    when Hash
      node.each { |key, value| walk_plain(value, "#{trail}[#{key.inspect}]", &block) }
    when Array
      node.each_with_index { |value, i| walk_plain(value, "#{trail}[#{i}]", &block) }
    end
  end
end
