# Reconstructed hermetic fixture (rev3 defect N2). The original was lost with
# the rev3 evidence tree; this rebuilds fixture_job_root_with_delegation from
# the accounting documented in test_job_root_own_chats.rb (root agent chat 60
# tt + result chat 30 tt = root 90; linked child log 150 tt = delegated),
# using the CURRENT scout-ai layout conventions: job chats live directly
# under <job>.files/ (no log/ segment), persisted jobs carry an .info
# sidecar, and a result chat is exposed through the :result relation when the
# job type is 'chat'.
module ChatAnalystFixtures
  def fixture_job_root_with_delegation(dir)
    # Root job: own agent chat (60 tt) + chat-type result (30 tt) => root 90.
    root = File.join(dir, 'Root/ask/Default_r.chat')
    agent_chat = "user: root work\n" +
      'function_call: ' + %({"name":"cortex_continue","arguments":{"agent":"Worker","conversation":"k"},"id":"r1"}) + "\n" +
      'function_call_output: ' + %({"name":"cortex_continue","content":"ok","id":"r1","agent_meta":[{"role":"meta","content":"job=#{File.join(dir, 'Worker/ask/Default_w')}"}]}) + "\n" +
      "meta: pt=40 ct=20 tt=60 inference_id=r1\n" +
      "assistant: root done\n"
    FileUtils.mkdir_p(root + '.files')
    File.write(root + '.files/agent.chat', agent_chat)
    File.write(root, "user: root work\nmeta: pt=20 ct=10 tt=30 inference_id=rr1\nassistant: root done\n")
    File.write(root + '.info', {status: 'done', type: 'chat', dependencies: []}.to_json)

    # Linked child job whose own log chat carries the delegated event (150 tt).
    child = File.join(dir, 'Worker/ask/Default_w')
    child_chat = "user: child work\n" +
                 "meta: pt=100 ct=50 tt=150 inference_id=k1\n" +
                 "assistant: child done\n"
    FileUtils.mkdir_p(child + '.files')
    File.write(child + '.files/agent.chat', child_chat)
    File.write(child, 'ok')
    File.write(child + '.info', {status: 'done', type: 'string', dependencies: []}.to_json)

    [root, child]
  end
end
