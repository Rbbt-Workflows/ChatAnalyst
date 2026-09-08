# Reconstructed hermetic fixture (rev3 defect N1, missing child). The original
# was lost with the rev3 evidence tree; this rebuilds the two fixtures the
# blocked tests expect (fixture_cortex_continue_missing and
# fixture_cortex_continue) from the conventions documented in
# test_unresolved_jobs_nil.rb, test_job_root_own_chats.rb and
# tmp/rev3/step3/repro_nil_fixture.rb, using the CURRENT scout-ai layout
# (job chats under <job>.files/, no log/ segment, .info sidecar).
module ChatAnalystFixtures
  # Parent chat whose cortex_continue receipt job= reference points at a job
  # that does NOT exist (the AGS situation that produced the nil leak).
  def fixture_cortex_continue_missing(dir)
    ghost = File.join(dir, 'Cortex/continue/Default_ghost')
    parent = File.join(dir, 'parent_missing.chat')
    File.write(parent, "user: go\n" +
      'function_call: ' + %({"name":"cortex_continue","arguments":{"agent":"Worker","conversation":"c1"},"id":"x1"}) + "\n" +
      'function_call_output: ' + %({"name":"cortex_continue","content":"child answer","id":"x1","agent_meta":[{"role":"meta","content":"job=#{ghost}"}]}) + "\n" +
      "meta: pt=4 ct=2 tt=6 inference_id=p1\n" +
      "assistant: done\n")
    [parent, ghost]
  end

end
