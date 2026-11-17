# lib/ChatAnalyst/ids.rb
#
# Phase 3 base layer: the frozen entity-ID grammar
# (research/phase3-contract.md section 1a).
#
# Escaping table (applied to path components of every identifier and to
# every path-valued key or cell):
#
#   %  -> %25    #  -> %23    TAB -> %09    NEWLINE -> %0A    CR -> %0D
#
# The table is CLOSED: exactly these five escapes are produced and exactly
# these five are recognized on unescape.  A message id is the escaped
# canonical chat path, then '#', then the zero-based decimal index; because
# a raw '#' cannot survive in the escaped path, splitting a message id on
# '#' yields exactly two parts.  Composite row keys join escaped parts with
# '#' the same way, so splitting on '#' recovers the parts unambiguously.
#
# These helpers are pure string functions: no filesystem access, no Scout
# loading.  Malformed ids raise ArgumentError, never return a best guess.

module ChatAnalyst
  module Ids
    ESCAPES = {
      '%' => '%25',
      '#' => '%23',
      "\t" => '%09',
      "\n" => '%0A',
      "\r" => '%0D'
    }.freeze
    UNESCAPES = ESCAPES.invert.freeze

    module_function

    # Escape one path (or path-like component) per the frozen table.
    # Returns a plain String even for Path-extended inputs.
    def escape_path(path)
      String.new(path.to_s).gsub(/[%#\t\n\r]/) { |char| ESCAPES[char] }
    end

    # Inverse of escape_path: exactly the five table escapes are
    # recognized; every other '%' sequence is left verbatim.
    def unescape_path(text)
      String.new(text.to_s).gsub(/%25|%23|%09|%0A|%0D/) { |token| UNESCAPES[token] }
    end

    # Canonical chat id: the EXISTING canonical spelling
    # (ChatAnalyst.canonical_chat_path -> Chat.provenance_path(:chat, ...)),
    # escaped per the table.  No new canonical form is invented here.
    def chat_id(chat_path)
      escape_path(ChatAnalyst.canonical_chat_path(chat_path))
    end

    # Canonical job id: the canonical job-path spelling
    # (Chat.provenance_path(:job, step)); accepts a Step or a job path.
    # Chat.provenance_path(:job, object) reads object.path, which only a
    # Step (or a Path SET UP AS a step-like path) carries correctly - a
    # Path.setup'd ordinary string appends 'path' - so a plain String is
    # canonicalized directly (expand_path + realpath, the same spelling the
    # core helper produces for a Step).
    def job_id(job)
      if job.is_a?(String)
        expanded = File.expand_path(job.to_s)
        return escape_path(File.file?(expanded) ? File.realpath(expanded) : expanded)
      end
      escape_path(Chat.provenance_path(:job, job).to_s)
    end

    # Message id: escaped canonical chat path + '#' + zero-based decimal
    # index.  The index is validated as a non-negative Integer.
    def message_id(chat_path, index)
      unless Integer === index && index >= 0
        raise ArgumentError, "Invalid message index #{index.inspect}: indices are zero-based and must be non-negative integers"
      end
      "#{chat_id(chat_path)}##{index}"
    end

    # Parse a message id back into [canonical_chat_path, index].  Raises
    # ArgumentError for ids that are not exactly path#index with a
    # non-negative decimal index.
    def parse_message_id(id)
      text = id.to_s
      unless String === id && !text.empty?
        raise ArgumentError, "Invalid message id #{id.inspect}: expected the escaped chat path, then '#', then the zero-based index"
      end
      parts = text.split('#', -1)
      unless parts.length == 2
        raise ArgumentError, "Invalid message id #{id.inspect}: expected exactly one '#' separating the escaped chat path from the index (got #{parts.length - 1})"
      end
      path, index = parts
      # The path part of a valid id is an ESCAPED path: raw TAB/NEWLINE/CR
      # can never occur there (the escape table removes them), so their
      # presence proves a malformed/unescaped id.
      if path.match?(/[\t\n\r]/)
        raise ArgumentError, "Invalid message id #{id.inspect}: the path part carries a raw control character (TAB/NEWLINE/CR) an escaped path cannot contain"
      end
      unless index.match?(/\A\d+\z/)
        raise ArgumentError, "Invalid message id #{id.inspect}: the part after the final '#' must be a non-negative decimal index"
      end
      [unescape_path(path), index.to_i]
    end

    # Composite row key: escaped parts joined with '#'.  Each part is
    # escaped with the SAME table when it looks like a path (callers pass
    # already-escaped path parts and raw controlled values); this method
    # only joins, so callers keep control of which parts were paths.
    def composite_key(*parts)
      parts = parts.collect { |part| part.nil? ? '' : String.new(part.to_s) }
      parts.each_with_index do |part, position|
        raise ArgumentError, "Composite key parts must not contain '#': part #{position} is #{part.inspect}" if part.include?('#')
      end
      parts * '#'
    end

    # Split a composite key back into its parts.  Raises ArgumentError
    # when the key does not carry exactly +count+ segments.
    def parse_composite(key, count)
      parts = String.new(key.to_s).split('#', -1)
      unless parts.length == count
        raise ArgumentError, "Invalid composite key #{key.inspect}: expected #{count} '#'-joined segments (got #{parts.length})"
      end
      parts
    end

    # Token-event id: the core grouping identity (an Array whose first
    # element names the identity kind) rendered as
    # identity-kind + '#' + escaped identity value.  The identity Array is
    # unique per deduplicated event, so the rendered id is too.
    def token_event_id(event)
      identity = event[:identity] || event['identity']
      raise ArgumentError, "Token event carries no identity: #{event.inspect}" unless Array === identity && !identity.empty?
      kind = identity.first.to_s
      value = identity.length == 2 ? identity.last.to_s : JSON.generate(identity.drop(1))
      composite_key(kind, escape_path(value))
    end
  end
end
