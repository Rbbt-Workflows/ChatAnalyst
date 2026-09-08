# Offline chat/job fixtures for ChatAnalyst tests.  These build the same
# persisted-layout family used by the Scout-AI agent_meta tests (tmpdir +
# persisted chat text + job directories with log chats), so the whole suite
# runs with no providers and no network.
#
# The fixture text intentionally reuses the same receipt envelope shape as
# Scout-AI's AgentMetaFixtures (kept local so this repository stays
# standalone), but all semantics under test are read through the ChatAnalyst
# tasks, which in turn only call the Scout-AI core APIs.

module ChatAnalystFixtures
  # Write persisted-style chat text and return its absolute path.
  def write_chat(dir, name, text)
    path = File.expand_path(File.join(dir, name))
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    path
  end

  def meta_receipt(content)
    {role: 'meta', content: content}
  end

  def receipt_output(call_id, agent_meta, name: 'ask', content: 'child answer')
    {name: name, content: content, id: call_id, agent_meta: agent_meta}.to_json
  end

  # Persisted chat text with one paired agent-oriented call per receipt entry.
  # Message indexes after Chat.parse: 0 user, 1 user, then per receipt a
  # function_call + function_call_output pair.
  def receipt_chat_text(receipts = nil, extra: nil, **keywords)
    lines = ['user: Run the worker']
    # A brace-less Hash first argument is folded into keywords by Ruby 3;
    # treat it as the receipts payload and pull `extra` out of it.
    if receipts.nil? && !keywords.empty?
      extra = keywords['extra'] || keywords[:extra] if extra.nil?
      receipts = keywords.reject { |key, _| key.to_s == 'extra' }
    end
    receipts = {} unless Hash === receipts
    receipts.each do |call_id, agent_meta|
      lines << 'function_call: ' + %({"name":"ask","arguments":{"agent":"Worker"},"id":"#{call_id}"})
      lines << 'function_call_output: ' + receipt_output(call_id, agent_meta)
    end
    lines.concat(Array(extra)) if extra
    lines << 'assistant: done'
    lines * "\n" + "\n"
  end

  # Create a job layout for a relative reference: result file, optional .info
  # sidecar with dependencies, and log chats under <job>.files/log/<name>.
  def make_job(dir, ref, result: 'answer', dependencies: [], logs: {})
    path = File.expand_path(File.join(dir, ref))
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, result)
    File.write(path + '.info', {dependencies: dependencies}.to_json) if dependencies.any?
    logs.each do |name, text|
      log_path = File.join(path + '.files', 'log', name)
      FileUtils.mkdir_p(File.dirname(log_path))
      File.write(log_path, text)
    end
    path
  end

  # --- Named scenario layouts -------------------------------------------

  # 0) Resolved cortex_continue delegation: receipt job= reference to a child
  # job whose own log chat carries the delegated token event. Current layout:
  # job chats sit directly under <job>.files/ with an .info sidecar.
  # Resolved cortex_continue delegation: receipt job= reference to a child job
  # whose own log chat carries the delegated token event.
  def fixture_cortex_continue(dir)
    worker = File.join(dir, 'Cortex/continue/Default_1')
    worker_chat = "user: run worker\n" +
                  "meta: pt=100 ct=50 tt=150 inference_id=c1\n" +
                  "assistant: delegated answer\n"
    FileUtils.mkdir_p(worker + '.files')
    File.write(worker + '.files/agent.chat', worker_chat)
    File.write(worker, 'delegated answer')
    File.write(worker + '.info', {status: 'done', dependencies: []}.to_json)
    parent = File.join(dir, 'parent.chat')
    File.write(parent, "user: go\n" +
      'function_call: ' + %({"name":"cortex_continue","arguments":{"agent":"Worker","conversation":"c1"},"id":"a1"}) + "\n" +
      'function_call_output: ' + %({"name":"cortex_continue","content":"delegated answer","id":"a1","agent_meta":[{"role":"meta","content":"job=#{worker}"}]}) + "\n" +
      "meta: pt=3 ct=2 tt=6 inference_id=p1\n" +
      "assistant: done\n")
    [parent, worker]
  end

  # 1) Receipt-only socialized delegation: the parent holds two direct child
  # events in agent_meta and no Worker chat/log/job exists anywhere.
  def fixture_receipt_only(dir)
    write_chat(dir, 'parent.chat',
               receipt_chat_text({'a1' => [meta_receipt('pt=100 ct=50 tt=150 inference_id=w1'),
                                           meta_receipt('pt=20 ct=10 tt=30 inference_id=w2')]},
                                 extra: ['meta: pt=1 ct=1 tt=2 inference_id=p1']))
  end

  # 2) Receipt plus saved Worker log: the same two inference ids exist in the
  # Worker agent.chat log AND in the parent receipt, plus one extra log-only
  # event w3.
  def fixture_receipt_plus_log(dir)
    worker_log = "user: work\n" +
                 "meta: pt=100 ct=50 tt=150 inference_id=w1\n" +
                 "meta: pt=20 ct=10 tt=30 inference_id=w2\n" +
                 "meta: pt=5 ct=5 tt=10 inference_id=w3\n" +
                 "assistant: done\n"
    worker = make_job(dir, 'Worker/ask/Default_w', logs: {'agent.chat' => worker_log})
    parent = write_chat(dir, 'parent.chat',
                        receipt_chat_text('a1' => [meta_receipt('pt=100 ct=50 tt=150 inference_id=w1'),
                                                   meta_receipt('pt=20 ct=10 tt=30 inference_id=w2')],
                                          extra: ['meta: pt=60 ct=40 tt=100 inference_id=p1',
                                                  "meta: job=#{worker}"]))
    [parent, worker]
  end

  # 3) Receipt job= reference leading to a Worker chat_task producer: the
  # parent receipt points at the Worker job (agent_job edge), whose log holds
  # the real direct events, and the Worker job has one dependency.
  def fixture_agent_job(dir)
    dep = make_job(dir, 'Dep/load/Default_1')
    worker_log = "user: work\n" +
                 "meta: pt=100 ct=50 tt=150 inference_id=w1\n" +
                 "meta: pt=20 ct=10 tt=30 inference_id=w2\n" +
                 "assistant: done\n"
    worker = make_job(dir, 'Worker/ask/Default_w',
                      dependencies: [dep], logs: {'agent.chat' => worker_log})
    parent = write_chat(dir, 'parent.chat',
                        receipt_chat_text('a1' => [meta_receipt("job=#{worker}")],
                                          extra: ['meta: pt=1 ct=1 tt=2 inference_id=p1']))
    [parent, worker, dep]
  end

  # 4) Identity conflict: two receipt copies of g1 disagree on tt and on the
  # provider response id.
  def fixture_conflict(dir)
    write_chat(dir, 'conflict.chat',
               receipt_chat_text({'c1' => [meta_receipt('pt=5 tt=6 inference_id=g1 provider_response_id=rA'),
                                           meta_receipt('pt=5 tt=9 inference_id=g1 provider_response_id=rB'),
                                           meta_receipt('pt=3 tt=4 inference_id=h1')]}))
  end

  # 5) Incomplete evidence: the two copies of h1 differ only in that one
  # carries a provider_response_id and the other does not.  The job must be
  # linked from the parent through a job= meta so both copies are discovered.
  def fixture_incomplete_evidence(dir)
    saved_log = "user: w\nmeta: pt=3 tt=4 inference_id=h1 provider_response_id=rq\nassistant: done\n"
    job = make_job(dir, 'W4/ask/Default_4', logs: {'agent.chat' => saved_log})
    write_chat(dir, 'parent.chat',
               receipt_chat_text({'a1' => [meta_receipt('pt=3 tt=4 inference_id=h1')]},
                                 extra: ["meta: job=#{job}"]))
  end

  # D) Nested receipt chain: the Manager asks Worker through a receipt whose
  # job= reference is followed (agent_job edge), and the Worker log itself
  # carries a second socialized receipt for Critic (receipt-only, no Critic
  # job anywhere).
  def fixture_nested_chain(dir)
    worker_log = "user: work\n" +
                 'function_call: ' + %({"name":"ask","arguments":{"agent":"Critic"},"id":"k1"}) + "\n" +
                 'function_call_output: ' + receipt_output('k1', [meta_receipt('pt=3 ct=2 tt=5 inference_id=c1')], content: 'critic done') + "\n" +
                 "meta: pt=100 ct=50 tt=150 inference_id=w1\n" +
                 "assistant: done\n"
    worker = make_job(dir, 'Worker/ask/Default_w', logs: {'agent.chat' => worker_log})
    parent = write_chat(dir, 'manager.chat',
                        receipt_chat_text({'m1' => [meta_receipt("job=#{worker}")]},
                                          extra: ['meta: pt=1 ct=1 tt=2 inference_id=p1']))
    [parent, worker]
  end

  # 6) Two receipts pointing at the same Worker job: both call ids and both
  # receipt addresses must stay visible as separate agent_job edges.
  def fixture_two_receipts_one_job(dir)
    worker_log = "user: work\nmeta: pt=100 ct=50 tt=150 inference_id=w1\nassistant: done\n"
    worker = make_job(dir, 'Worker/ask/Default_w', logs: {'agent.chat' => worker_log})
    parent = write_chat(dir, 'parent.chat',
                        receipt_chat_text({'a1' => [meta_receipt("job=#{worker}")],
                                           'a2' => [meta_receipt("job=#{worker}")]},
                                          extra: ['meta: pt=1 ct=1 tt=2 inference_id=p1']))
    [parent, worker]
  end
end
