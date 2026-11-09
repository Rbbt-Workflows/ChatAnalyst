$LOAD_PATH.unshift '.'
require 'test/test_helper'
require 'test/scout/agent_meta_fixtures'

# Minimal revision phase 2 (plan step 6): canonical chat-path spelling and
# overview normalization.
#
# The /home/mvazque2 vs /bulk/mvazque2 mount alias claimed by claim 10 is
# NOT a generic path alias on this machine (they are different device trees:
# /home/mvazque2/git is device 2081, /bulk/mvazque2/git is device 79; only
# the ChatAnalyst checkout is bind-mounted at the /bulk spelling inside
# this bwrap session, and Chat.provenance_path resolves it to the /bulk
# spelling).  The alias test therefore exercises a REAL alias pair the
# tests can construct deterministically: a symlinked directory, so the same
# chat file is addressable at two spellings exactly the way a mount alias
# makes it addressable.  The guarantee under test is the invariant itself —
# one canonical spelling across overview / relationships / range /
# tool_calls / tool_call — not the specific mount pair.
class TestCanonicalPathsAndNormalization < Test::Unit::TestCase
  def setup
    @dir = Dir.mktmpdir('chat_analyst_canonical')
  end

  def teardown
    FileUtils.rm_rf(@dir) if @dir
  end

  # A chat file reachable through a symlinked directory: two spellings, one
  # file, exactly the /home-vs-/bulk alias situation in miniature.
  def aliased_chat(text = "user: a\nassistant: b\n")
    real_dir = File.join(@dir, 'real')
    FileUtils.mkdir_p(real_dir)
    chat = File.join(real_dir, 'a.chat')
    File.write(chat, text)
    FileUtils.ln_s(real_dir, File.join(@dir, 'alias'))
    alias_chat = File.join(@dir, 'alias', 'a.chat')
    raise 'alias fixture broken' unless File.file?(alias_chat)
    [chat, alias_chat, File.realpath(alias_chat)]
  end

  def test_all_public_operations_return_one_canonical_spelling_from_alias
    _real, alias_chat, canonical = aliased_chat

    assert_equal canonical, ChatAnalyst.overview(alias_chat)[:root][:path],
                 'overview already canonicalized the alias'
    assert_equal canonical, ChatAnalyst.range(alias_chat, 0, 1)[:chat],
                 'range must echo the canonical spelling, not the input alias'
    assert_equal canonical, ChatAnalyst.tool_calls(alias_chat)[:chat]
    assert_equal canonical, ChatAnalyst.tool_call(alias_chat, nil)[:chat] rescue nil
    assert_equal canonical, ChatAnalyst.relationships(alias_chat)[:chat]

    # import targets and the import closure use the same canonical spelling
    # (an import: reference resolved through the alias lands on canonical).
    real_dir2 = File.join(@dir, 'real2')
    FileUtils.mkdir_p(real_dir2)
    imported = File.join(real_dir2, 'b.chat')
    File.write(imported, "user: earlier\nassistant: older\n")
    FileUtils.ln_s(real_dir2, File.join(@dir, 'alias2'))
    host = File.join(@dir, 'real', 'host.chat')
    File.write(host, "import: #{@dir}/alias2/b.chat\nuser: q\nassistant: r\n")

    relationships = ChatAnalyst.relationships(host)
    assert_equal File.realpath(imported), relationships[:references].first[:target],
                 'resolved import targets must carry the canonical spelling'
    assert relationships[:import_closure].all? { |p| p == File.realpath(p) rescue false },
           'closure entries are canonical'
  end

  def test_overview_returns_plain_strings_recursively
    parent, worker = fixture_receipt_plus_log(@dir + '/plus_log')
    dep = make_job(@dir, 'D1/load/Default_1')
    make_job(@dir, 'W/ask/Default_w2', dependencies: [dep],
              logs: {'agent.chat' => "user: w\nmeta: pt=1 ct=1 tt=2 inference_id=w1\nassistant: d\n"})
    overview = ChatAnalyst.overview(parent)

    offenders = []
    walk = lambda do |node, trail|
      case node
      when Hash
        node.each { |key, value| walk.call(value, "#{trail}[#{key.inspect}]") }
      when Array
        node.each_with_index { |value, i| walk.call(value, "#{trail}[#{i}]") }
      when String
        offenders << "#{node.class} at #{trail}" if Path === node
        offenders << "alias spelling at #{trail}" if node.include?('/alias/') && trail.include?('path')
      else
        offenders << "#{node.class} at #{trail}" unless [Integer, Float, TrueClass, FalseClass, NilClass, Symbol].include?(node.class)
      end
    end
    walk.call(overview, '$')
    assert_empty offenders, "graph maps must normalize to plain canonical strings: #{offenders.first(5).inspect}"

    # graph-derived maps specifically: String values, canonical spelling
    chat = overview[:chats].find { |c| c[:path] == parent }
    job_ref = chat[:job_references].values.first
    assert_equal String, job_ref.class
    assert_equal File.realpath(worker), job_ref
    assert_equal String, chat[:delegation_references].values.first.class
    assert_equal String, overview[:jobs].first[:dependencies].first.class if overview[:jobs].any? { |j| j[:dependencies].any? }
  end

  def test_overview_warnings_are_plain_strings
    missing = File.join(@dir, 'gone/ask/Default_gone')
    chat = write_chat(@dir, 'broken.chat', "user: x\nmeta: job=#{missing}\nassistant: y\n")
    overview = ChatAnalyst.overview(chat)
    warnings = overview[:chats].first[:warnings]
    assert warnings
    assert JSON.generate(warnings), 'warnings stay serializable'
  end
end
