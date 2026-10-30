# frozen_string_literal: true

module TinyGQL
  # Measures how large a document would be with its fragment spreads
  # expanded, without expanding it.  Fragments can spread other fragments
  # more than once, so a small document can expand exponentially:
  #
  #   score = TinyGQL::Expansion.check(TinyGQL.parse(query), 100_000)
  #
  # Scores match Bluejay's `max_expansion` check:
  #
  # * Each selection set and each selection adds 1
  # * Each fragment spread also adds the selection sets of every fragment
  #   definition with that name, every time it's spread
  # * Every operation and fragment definition counts, even unused ones
  #
  # The schema isn't used, and directives like @skip don't reduce the score.
  #
  # A spread that closes a fragment cycle adds 1 but isn't expanded again on
  # that path, so cyclic documents get a finite score.  Cyclic documents are
  # still invalid and validation should reject them.
  module Expansion
    class LimitExceeded < StandardError; end

    # `cyclic` is true when the document has a fragment cycle, so `value` is
    # the score with cycles cut rather than an exact score
    Score = Struct.new(:value, :cyclic) do
      alias_method :cyclic?, :cyclic
    end

    # Returns the Score for `document`, or raises LimitExceeded if it's
    # larger than `limit`
    def self.check document, limit
      raise ArgumentError, "limit must be a non-negative Integer" unless Integer === limit && limit >= 0
      Scorer.new(document, limit).score
    end

    class Scorer # :nodoc:
      def initialize document, limit
        @limit = limit
        @operations = []
        @fragments = []
        @bodies = {}
        document.definitions.each do |defn|
          if defn.operation_definition?
            @operations << defn.selection_set
          elsif defn.fragment_definition?
            @fragments << defn
            (@bodies[defn.fragment_name] ||= []) << defn.selection_set
          end
        end
        # Fragment name to :visiting while it's being expanded, or to its
        # score once that's known
        @states = {}
        @stack = []
        @score = 0
        @cycles = 0
      end

      def score
        @operations.each { |body| run body }
        @fragments.each do |fragment|
          name = fragment.fragment_name
          # Keep the cached score, this body may be one of several with the
          # same name
          state = @states[name]
          @states[name] = :visiting
          run fragment.selection_set
          @states[name] = state
        end
        Score.new(@score, @cycles > 0)
      end

      private

      # Uses an explicit stack because fragment chains can be very long.
      # Selection sets are Arrays and fragment spreads are Strings.  :finish
      # is pushed on top of the fragment name and the counters from when its
      # expansion started.
      def run task
        stack = @stack
        stack.push task
        while (task = stack.pop)
          case task
          when Array
            add 1
            task.each do |selection|
              add 1
              if selection.fragment_spread?
                stack.push selection.fragment_name
              elsif (child = selection.selection_set)
                stack.push child
              end
            end
          when String
            # Spreads of missing fragments only count themselves
            next unless (bodies = @bodies[task])

            case state = @states[task]
            when Integer
              add state
            when :visiting
              @cycles += 1
              limit_exceeded! if @cycles > @limit
            else
              @states[task] = :visiting
              stack.push @cycles, @score, task, :finish
              # Expand the first definition first, like Bluejay
              (1...bodies.length).each { |i| stack.push bodies[i] }
              stack.push bodies[0]
            end
          when :finish
            name = stack.pop
            start_score = stack.pop
            start_cycles = stack.pop
            # Scores that hit a cycle depend on the path taken, so only cache
            # the others
            @states[name] = @cycles == start_cycles ? @score - start_score : nil
          end
        end
      end

      def add n
        @score += n
        limit_exceeded! if @score > @limit
      end

      def limit_exceeded!
        raise LimitExceeded, "Maximum expansion limit of #{@limit} exceeded"
      end
    end
  end
end
