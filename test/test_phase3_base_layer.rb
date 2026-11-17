$LOAD_PATH.unshift '.'
require 'test/test_helper'
require 'ChatAnalyst/ids'
require 'ChatAnalyst/tsv_base'
require 'tmpdir'
require 'fileutils'
require 'stringio'
require 'json'

# Phase 3 base layer (plan step 2, research/phase3-contract.md): the
# entity-ID grammar and the TSV serializer conventions.
#
# Three verification surfaces, mirroring the stage-0 probes:
#   1. grammar round-trips and malformed-id errors (pure functions);
#   2. encoder pins + TSV dump/open round-trip with annotation survival;
#   3. a disposable scratch task persistence round-trip (task => :tsv
#      through a REAL Scout job, the stage-0 probe-G pattern) proving the
#      annotations and casts survive Step#load.
class TestPhase3BaseLayer < Test::Unit::TestCase
  include ChatAnalystFixtures

  # --- 1. ID grammar ------------------------------------------------------

  def test_escape_table_is_exact_and_closed
    assert_equal '%25', ChatAnalyst::Ids.escape_path('%')
    assert_equal '%23', ChatAnalyst::Ids.escape_path('#')
    assert_equal '%09', ChatAnalyst::Ids.escape_path("\t")
    assert_equal '%0A', ChatAnalyst::Ids.escape_path("\n")
    assert_equal '%0D', ChatAnalyst::Ids.escape_path("\r")
    # everything else is left verbatim, including '|' and '~'
    assert_equal '|~, a b', ChatAnalyst::Ids.escape_path('|~, a b')
    # the table escapes '%' itself, so an embedded escape-looking sequence
    # doubles its '%' (closed-table consequence, not URL encoding)
    assert_equal '%2522', ChatAnalyst::Ids.escape_path('%22')
  end

  def test_escape_unescape_round_trip_hostile_paths
    hostile = [
      '/home/u/a b/c#3',
      '/home/u/a%25b#12',
      "/home/u/t\ta\nb\rc#7",
      '/home/u/100%#tab\there',
      '~/.scout/x#0',
      '/home/u/#'
    ]
    hostile.each do |raw|
      escaped = ChatAnalyst::Ids.escape_path(raw)
      refute_match(/[\t\n\r]/, escaped)
      refute_match(/[^%0-9A-Za-z]#/, escaped)
      assert_equal raw, ChatAnalyst::Ids.unescape_path(escaped), raw.inspect
    end
  end

  def test_message_id_grammar_and_parse
    Dir.mktmpdir do |dir|
      chat = write_chat(dir, 'plain.chat', "user: a\nassistant: b\n")
      id = ChatAnalyst::Ids.message_id(chat, 3)
      path, index = ChatAnalyst::Ids.parse_message_id(id)
      assert_equal ChatAnalyst.canonical_chat_path(chat), path
      assert_equal 3, index
      assert id.end_with?('#3')

      hostile = File.join(dir, 'we ird#ta%b.chat')
      File.write(hostile, "user: x\nassistant: y\n")
      id = ChatAnalyst::Ids.message_id(hostile, 0)
      assert_equal 1, id.count('#')
      path, index = ChatAnalyst::Ids.parse_message_id(id)
      assert_equal ChatAnalyst.canonical_chat_path(hostile), path
      assert_equal 0, index
    end
  end

  def test_parse_message_id_errors
    [
      nil, '', 'no-separator', 'a#b#c', 'path#-1', 'path#x', 'path#',
      'path#1#2', "path\t#1", "pa\nth#1", "pa\rth#1"
    ].each do |bad|
      error = assert_raise(ArgumentError, bad.inspect) do
        ChatAnalyst::Ids.parse_message_id(bad)
      end
      assert_match(/message id/i, error.message, bad.inspect)
    end
  end

  def test_message_id_rejects_bad_index
    assert_raise(ArgumentError) { ChatAnalyst::Ids.message_id('/tmp/a.chat', -1) }
    assert_raise(ArgumentError) { ChatAnalyst::Ids.message_id('/tmp/a.chat', '1') }
    assert_raise(ArgumentError) { ChatAnalyst::Ids.message_id('/tmp/a.chat', nil) }
  end

  def test_composite_keys_round_trip
    key = ChatAnalyst::Ids.composite_key('/escaped/a%23b', 'job_reference', 2)
    assert_equal ['/escaped/a%23b', 'job_reference', '2'],
                 ChatAnalyst::Ids.parse_composite(key, 3)
    assert_raise(ArgumentError) { ChatAnalyst::Ids.composite_key('a#b', 'c') }
    assert_raise(ArgumentError) { ChatAnalyst::Ids.parse_composite('a#b#1', 2) }
  end

  def test_token_event_id_from_core_identity
    event = {identity: [:inference_id, 'w1'], tokens: {pt: 1, ct: 1, tt: 2}}
    assert_equal 'inference_id#w1', ChatAnalyst::Ids.token_event_id(event)
    # path-valued identity elements are escape_path'd (NOT URL-encoded):
    # only the closed five-character table applies
    event = {identity: [:receipt, '/path/to/e#vi dence']}
    assert_equal 'receipt#/path/to/e%23vi%20dence'.gsub('%20', ' '),
                 ChatAnalyst::Ids.token_event_id(event)
    # TAB and NEWLINE inside an identity value survive the join
    event = {identity: [:receipt, "a\tb\nc"]}
    assert_equal "receipt#a%09b%0Ac", ChatAnalyst::Ids.token_event_id(event)
    assert_raise(ArgumentError) { ChatAnalyst::Ids.token_event_id({}) }
    assert_raise(ArgumentError) { ChatAnalyst::Ids.token_event_id(identity: []) }
  end

  # --- 2. encoders + TSV round-trip ----------------------------------------

  def test_text_encoder_distinguishes_null_and_empty_string
    assert_equal '\N', ChatAnalyst::TSVBase.text(nil)
    assert_equal '', ChatAnalyst::TSVBase.text('')
    assert_equal 'x', ChatAnalyst::TSVBase.text('x')
    # a literal sentinel in DATA is escaped away, never confused with null
    assert_equal '\\\N', ChatAnalyst::TSVBase.text('\N')
    assert_nil ChatAnalyst::TSVBase.untext('\N')
    assert_equal '', ChatAnalyst::TSVBase.untext('')
    assert_equal '\N', ChatAnalyst::TSVBase.untext('\\\N')
  end

  def test_integer_float_boolean_encoders
    assert_equal '42', ChatAnalyst::TSVBase.integer(42)
    assert_equal '-7', ChatAnalyst::TSVBase.integer(-7)
    assert_equal '\N', ChatAnalyst::TSVBase.integer(nil)
    assert_equal 42, ChatAnalyst::TSVBase.uninteger('42')
    assert_nil ChatAnalyst::TSVBase.uninteger('\N')

    assert_equal '3.5', ChatAnalyst::TSVBase.float(3.5)
    assert_equal '\N', ChatAnalyst::TSVBase.float(nil)
    assert_equal 3.5, ChatAnalyst::TSVBase.unfloat('3.5')

    assert_equal 'true', ChatAnalyst::TSVBase.boolean(true)
    assert_equal 'false', ChatAnalyst::TSVBase.boolean(false)
    assert_equal '\N', ChatAnalyst::TSVBase.boolean(nil)
    assert_equal true, ChatAnalyst::TSVBase.unboolean('true')
    assert_equal false, ChatAnalyst::TSVBase.unboolean('false')
    assert_nil ChatAnalyst::TSVBase.unboolean('\N')
    assert_raise(ArgumentError) { ChatAnalyst::TSVBase.boolean('yes') }
    assert_raise(ArgumentError) { ChatAnalyst::TSVBase.integer('42') }
    assert_raise(ArgumentError) { ChatAnalyst::TSVBase.float('3.5') }
  end

  def test_timestamp_encoder_normalizes_or_nulls
    assert_equal '2026-02-03T11:00:00.123Z',
                 ChatAnalyst::TSVBase.timestamp(Time.parse('2026-02-03T11:00:00.123Z'))
    # offset input normalizes to Z with milliseconds intact
    assert_equal '2026-02-03T11:00:00.500Z',
                 ChatAnalyst::TSVBase.timestamp(Time.iso8601('2026-02-03T12:00:00.500+01:00'))
    assert_equal '2026-02-03T11:00:00.500Z',
                 ChatAnalyst::TSVBase.timestamp('2026-02-03T12:00:00.500+01:00')
    assert_equal '2026-02-03T11:00:00.000Z',
                 ChatAnalyst::TSVBase.timestamp('2026-02-03T12:00:00+01:00')
    assert_equal '\N', ChatAnalyst::TSVBase.timestamp('not a time')
    assert_equal '\N', ChatAnalyst::TSVBase.timestamp(nil)
    assert_equal '2026-02-03T11:00:00.123Z',
                 ChatAnalyst::TSVBase.timestamp('2026-02-03T11:00:00.123Z')
  end

  def test_multi_value_pipe_invariant
    assert_equal 'a|b', ChatAnalyst::TSVBase.multi(%w[a b])
    assert_equal '\N', ChatAnalyst::TSVBase.multi(nil)
    assert_equal '\N', ChatAnalyst::TSVBase.multi([])
    assert_equal '/a%23b|x', ChatAnalyst::TSVBase.multi(['/a#b', 'x'], encoder: :path)
    assert_raise(ArgumentError) { ChatAnalyst::TSVBase.multi(['a|b'], encoder: :text) }
    # '| survives the path encoder verbatim (the escape table does not
    # touch it) — multi() still refuses it, pinning the invariant at the
    # only layer that owns it
    assert_equal '/a|b', ChatAnalyst::TSVBase.path('/a|b')
    assert_raise(ArgumentError) { ChatAnalyst::TSVBase.multi(['/a|b'], encoder: :path) }
    assert_equal ['a', 'b'], ChatAnalyst::TSVBase.unmulti('a|b')
    assert_nil ChatAnalyst::TSVBase.unmulti('\N')
    assert_equal [], ChatAnalyst::TSVBase.unmulti('')
  end

  def test_build_table_duplicate_keys_raise
    rows = [['k', ['1']]]
    table = ChatAnalyst::TSVBase.build_table(
      key_field: 'K', fields: ['V'], rows: rows
    )
    assert_equal({'k' => ['1']}, table.to_h)
    assert_raise(ArgumentError) do
      ChatAnalyst::TSVBase.build_table(
        key_field: 'K', fields: ['V'], rows: [rows.first, rows.first]
      )
    end
  end

  def test_tsv_dump_open_round_trip_with_annotations_and_nulls
    rows = [
      ['/chat%23one#3', ['user', '42', '\N', '', 'true', '2026-02-03T11:00:00.123Z']],
      ['/chat%23two#4', ['assistant', '0', 'text', 'x', 'false', '\N']]
    ]
    table = ChatAnalyst::TSVBase.build_table(
      key_field: 'Message', fields: %w[Role Characters Timestamp Note Large When],
      rows: rows,
      # root_path carries the ESCAPED canonical path: the '#:' line grammar
      # cannot carry a raw '#' inside an annotation value (freeze-probe
      # evidence: unescaped '#1.chat' corrupts directive parsing), and the
      # escape table removes '#' anyway
      annotations: {page: 1, per_page: 50, total: 2,
                    root_path: ChatAnalyst::Ids.escape_path('/root chat#1.chat')}
    )
    dump = table.to_s
    refute_includes dump, "\t\t\n"
    back = TSV.open(StringIO.new(dump))

    assert_equal 2, back.length
    assert_equal ['user', '42', '\N', '', 'true', '2026-02-03T11:00:00.123Z'], back[rows[0][0]]
    assert_equal ['assistant', '0', 'text', 'x', 'false', '\N'], back[rows[1][0]]

    # null-vs-empty distinction survives dump/reopen
    assert_nil ChatAnalyst::TSVBase.untext(back[rows[0][0]][2])
    assert_equal '', ChatAnalyst::TSVBase.untext(back[rows[0][0]][3])

    # annotations survive (registered names -> typed accessors)
    assert_equal 1, back.options[:page]
    assert_equal 50, back.options[:per_page]
    assert_equal 2, back.options[:total]
    assert_equal ChatAnalyst::Ids.escape_path('/root chat#1.chat'),
                 back.options[:root_path]
    assert_equal '/root chat#1.chat',
                 ChatAnalyst::Ids.unescape_path(back.options[:root_path])
  end

  def test_tsv_cast_round_trip_numeric_table
    rows = [['root', [10, 20, 30]], ['delegated', [1, 2, 3]]]
    table = ChatAnalyst::TSVBase.build_table(
      key_field: 'Bucket', fields: %w[Pt Ct Tt], rows: rows, cast: :to_i
    )
    back = TSV.open(StringIO.new(table.to_s))
    assert_equal [10, 20, 30], back['root']
    assert_equal :to_i, back.options[:cast]
    # empty cell under cast reads nil (native numeric null)
    table2 = ChatAnalyst::TSVBase.build_table(
      key_field: 'Bucket', fields: %w[Pt Ct Tt],
      rows: [['x', ['', '5', '']]], cast: :to_i
    )
    back2 = TSV.open(StringIO.new(table2.to_s))
    assert_nil back2['x'][0]
    assert_nil back2['x'][2]
    assert_equal 5, back2['x'][1]
  end

  def test_paginate_rows_matches_envelope_semantics
    rows = (1..7).collect { |i| ["k#{i}", [i.to_s]] }
    page_rows, annotations = ChatAnalyst::TSVBase.paginate_rows(rows, 2, 3)
    assert_equal %w[k4 k5 k6], page_rows.collect(&:first)
    assert_equal({page: 2, per_page: 3, total: 7, total_pages: 3,
                  next_page: 3, prev_page: 1}, annotations)

    last_rows, last_annotations = ChatAnalyst::TSVBase.paginate_rows(rows, 3, 3)
    assert_equal %w[k7], last_rows.collect(&:first)
    assert_nil last_annotations[:next_page]

    past_rows, past_annotations = ChatAnalyst::TSVBase.paginate_rows(rows, 9, 3)
    assert_equal [], past_rows
    assert_equal 3, past_annotations[:total_pages]

    assert_nil ChatAnalyst::TSVBase.paginate_rows(rows, nil, 3)
  end

  def test_annotation_registration_seen_without_explicit_require
    # test_helper loads workflow.rb, which requires tsv_base: the accessors
    # must already exist on a fresh TSV instance.
    tsv = TSV.setup({}, type: :list, key_field: 'K', fields: ['V'])
    %w[page per_page total total_pages next_page prev_page root_path
       max_gap_seconds first last scope filters chats jobs delegations
       clusters inferences unclustered conflicts incomplete_evidence].each do |name|
      assert_respond_to tsv, "#{name}=", name
    end
    tsv.max_gap_seconds = 120
    tsv.unclustered = 0
    assert_equal 120, TSV.open(StringIO.new(tsv.to_s)).options[:max_gap_seconds]
    assert_equal 0, TSV.open(StringIO.new(tsv.to_s)).options[:unclustered]
  end

  # --- 3. scratch task persistence round-trip ------------------------------

  # A disposable scratch workflow in the test tmpdir (the stage-0 probe-G
  # pattern): one task returning a contract-built table, run through a REAL
  # Scout job so the result is persisted as a task would persist it.
  SCRATCH_SOURCE = <<~RUBY
    require 'scout'
    module Phase3BaseLayerProbe
      extend Workflow
      self.name = 'Phase3BaseLayerProbe'

      input :unused, :string, 'unused', nil, nofile: true
      task :table => :tsv do |unused|
        ChatAnalyst::TSVBase.build_table(
          key_field: 'Message', fields: %w[Role Characters Null Empty Large],
          rows: [
            ['/a%23b#0', ['user', '42', '\\\\N', '', 'true']],
            ['/a%23b#1', ['assistant', '0', 'x', '\\\\N', 'false']]
          ],
          annotations: {page: 1, per_page: 50, total: 2,
                        root_path: '/a%23b.chat', max_gap_seconds: 120}
        )
      end
    end
  RUBY

  def test_scratch_task_persists_annotations_through_step_load
    scratch_dir = File.join(@__test_dir, 'scratch-workflow')
    FileUtils.mkdir_p(scratch_dir)
    File.write(File.join(scratch_dir, 'workflow.rb'), SCRATCH_SOURCE)

    # fresh child per run: a reused load would re-require the same
    # workflow.rb path and re-declare its tasks (Stage-0 scratch pattern)
    loaded_before = $LOADED_FEATURES.length
    require File.join(scratch_dir, 'workflow')
    assert_operator $LOADED_FEATURES.length, :>=, loaded_before

    job = Phase3BaseLayerProbe.job(:table, {unused: 'x'}, workflow: 'Phase3BaseLayerProbe')
    job.run
    loaded = Step.load(job.path).load
    assert_equal 2, loaded.length
    assert_equal ['user', '42', '\N', '', 'true'], loaded['/a%23b#0']
    assert_equal 1, loaded.options[:page]
    assert_equal 50, loaded.options[:per_page]
    assert_equal 2, loaded.options[:total]
    assert_equal '/a%23b.chat', loaded.options[:root_path]
    assert_equal 120, loaded.options[:max_gap_seconds]
    assert_nil ChatAnalyst::TSVBase.untext(loaded['/a%23b#0'][2])
    assert_equal '', ChatAnalyst::TSVBase.untext(loaded['/a%23b#0'][3])
    assert_equal 'x', ChatAnalyst::TSVBase.untext(loaded['/a%23b#1'][2])
    assert_nil ChatAnalyst::TSVBase.untext(loaded['/a%23b#1'][3])
  end
end
