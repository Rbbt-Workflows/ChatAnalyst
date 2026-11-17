# lib/ChatAnalyst/tsv_base.rb
#
# Phase 3 base layer: TSV serialization conventions frozen in
# research/phase3-contract.md section 1.
#
# Explicit helpers only — NO metaprogrammed serializer framework.  Every
# production TSV task is built from:  the encoders below (one per cell
# kind), build_table (type/key_field/fields/cast/annotations/rows) and
# the read-side decoders.
#
# Encodings (contract 1b-1d):
#   null in String columns  -> the two-character sentinel \N
#   empty string            -> '' (ALWAYS empty string, never null)
#   booleans                -> 'true' / 'false', null -> \N (no :to_b cast
#                              exists in the loaded stack)
#   timestamps              -> UTC iso8601(3), normalized when parseable,
#                              null when missing or unparseable
#   multi-value cells       -> '|'-joined; values must not contain '|'
#   numeric columns in mixed tables -> decimal strings (int/float encoders);
#                              only all-numeric tables cast natively
#
# Annotation registration (contract 1f/1g): ONE TSV.annotation call with
# every name the task surface uses, executed at library load.  workflow.rb
# requires this file after ChatAnalyst/api and before any task file, so
# every task run and every test sees the accessors.  Registering the same
# name twice is harmless (idempotent in effect).

require 'ChatAnalyst/ids'
require 'time'

TSV.annotation :page, :per_page, :total, :total_pages, :next_page,
               :prev_page, :root_path, :max_gap_seconds,
               :first, :last, :scope, :filters,
               :chats, :jobs, :delegations,
               :clusters, :inferences, :unclustered,
               :conflicts, :incomplete_evidence

module ChatAnalyst
  module TSVBase
    NULL = '\\N'
    MULTI_VALUE_SEPARATOR = '|'

    module_function

    # -- cell encoders -------------------------------------------------------

    # Text cell: nil -> sentinel, every other value -> its plain String
    # form.  The sentinel itself is escaped away so a literal '\N' in data
    # can never be confused with null.
    def text(value)
      return NULL if value.nil?
      string = String.new(value.to_s)
      string == NULL ? '\\' + NULL : string
    end

    # Read side: sentinel -> nil, anything else -> the String as stored.
    def untext(cell)
      return nil if cell.nil? || cell == NULL
      cell == '\\' + NULL ? NULL : cell
    end

    # Integer cell in a mixed (all-String) table: decimal string, nil ->
    # sentinel.  Non-integer inputs raise (writers must pass Integers).
    def integer(value)
      return NULL if value.nil?
      raise ArgumentError, "Expected an Integer, got #{value.inspect}" unless Integer === value
      value.to_s
    end

    def uninteger(cell)
      return nil if cell.nil? || cell == NULL
      Integer(cell)
    end

    # Float cell in a mixed table: decimal string, nil -> sentinel.
    def float(value)
      return NULL if value.nil?
      raise ArgumentError, "Expected a Numeric, got #{value.inspect}" unless Numeric === value
      value.to_f.to_s
    end

    def unfloat(cell)
      return nil if cell.nil? || cell == NULL
      Float(cell)
    end

    # Boolean cell: 'true'/'false', nil -> sentinel.  Anything other than
    # true/false raises (no implicit truthiness).
    def boolean(value)
      return NULL if value.nil?
      return 'true' if value == true
      return 'false' if value == false
      raise ArgumentError, "Expected true or false, got #{value.inspect}"
    end

    def unboolean(cell)
      return nil if cell.nil? || cell == NULL
      case cell
      when 'true' then true
      when 'false' then false
      else raise ArgumentError, "Invalid boolean cell #{cell.inspect}: expected 'true', 'false' or the null sentinel"
      end
    end

    # Timestamp cell: parseable time -> UTC iso8601(3); missing or
    # unparseable -> sentinel.  Never invents a value.  Time objects are
    # used directly (a to_s round-trip loses sub-second precision);
    # strings go strict-iso8601 first, then lenient Time.parse.
    def timestamp(value)
      return NULL if value.nil?
      return value if value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/)
      parsed = case value
               when Time then value
               else
                 begin
                   Time.iso8601(value.to_s)
                 rescue ArgumentError
                   begin
                     Time.parse(value.to_s)
                   rescue ArgumentError, TypeError
                     nil
                   end
                 end
               end
      return NULL unless parsed
      parsed.utc.iso8601(3)
    end

    def untimestamp(cell)
      return nil if cell.nil? || cell == NULL
      Time.parse(cell)
    end

    # Path cell: nil -> sentinel, otherwise the escaped canonical string.
    def path(value)
      return NULL if value.nil?
      ChatAnalyst::Ids.escape_path(value)
    end

    def unpath(cell)
      return nil if cell.nil? || cell == NULL
      ChatAnalyst::Ids.unescape_path(cell)
    end

    # Multi-value cell: nil and [] -> sentinel; otherwise '|'-joined with
    # every member validated '|' -free (contract 1b invariant).  Members
    # are encoded by the given encoder (:text by default).
    def multi(values, encoder: :text)
      return NULL if values.nil?
      values = values.to_a
      return NULL if values.empty?
      encoder_method = method(encoder)
      values.collect do |value|
        encoded = encoder_method.call(value)
        if encoded.include?(MULTI_VALUE_SEPARATOR)
          raise ArgumentError, "Multi-value member must not contain '|': #{value.inspect}"
        end
        encoded
      end * MULTI_VALUE_SEPARATOR
    end

    def unmulti(cell, decoder: :untext)
      return nil if cell.nil? || cell == NULL
      return [] if cell.empty?
      decoder_method = method(decoder)
      cell.split(MULTI_VALUE_SEPARATOR, -1).collect { |part| decoder_method.call(part) }
    end

    # -- table construction --------------------------------------------------

    # Build one TSV from explicit, complete inputs:
    #   type:      :list (every contract table) — the alignment contract
    #              for aligned-by-construction relations rides :list too
    #   key_field: field name String
    #   fields:    Array of field-name Strings
    #   cast:      nil (mixed/String table) or :to_i / :to_f when EVERY
    #              field is numeric (contract 1c)
    #   annotations: Hash of registered annotation name => Scalar value;
    #              nil values are skipped (absent directive == nil on read)
    #   rows:      Array of [key, [value, ...]] pairs, values ALREADY
    #              encoded as Strings (the encoders above produced them)
    #   serializer_options: extra TSV.setup options passed through
    #
    # Duplicate keys raise (key uniqueness is a contract guarantee).
    def build_table(key_field:, fields:, rows:, type: :list, cast: nil,
                    annotations: {}, serializer_options: {})
      tsv = TSV.setup({}, serializer_options.merge(
        type: type, key_field: key_field, fields: fields.dup, cast: cast
      ).compact)
      seen = {}
      rows.each do |key, values|
        key_string = String.new(key.to_s)
        raise ArgumentError, "Duplicate row key #{key_string.inspect}" if seen[key_string]
        seen[key_string] = true
        case type
        when :single then tsv[key_string] = values.first
        else tsv[key_string] = values.collect { |value| value.nil? ? '' : String.new(value.to_s) }
        end
      end
      annotations.each do |name, value|
        next if value.nil?
        raise ArgumentError, "Unknown annotation #{name.inspect}" unless tsv.respond_to?("#{name}=")
        tsv.send("#{name}=", value)
      end
      tsv
    end

    # Apply the contract pagination to a full row list.  Returns the page
    # rows and the pagination annotation values (page, per_page, total,
    # total_pages, next_page, prev_page) ready for build_table; nil when
    # +page+ is nil (pagination not requested — the table is unpaginated).
    def paginate_rows(rows, page, per_page)
      return nil unless page
      per_page = (per_page || 50).to_i
      per_page = 1 if per_page < 1
      page = page.to_i
      page = 1 if page < 1
      total = rows.length
      total_pages = [(total.to_f / per_page).ceil, 1].max
      offset = (page - 1) * per_page
      page_rows = rows[offset, per_page] || []
      annotations = {
        page: page, per_page: per_page, total: total, total_pages: total_pages,
        next_page: page < total_pages ? page + 1 : nil,
        prev_page: page > 1 ? page - 1 : nil
      }
      [page_rows, annotations]
    end
  end
end
