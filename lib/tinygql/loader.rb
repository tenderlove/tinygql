# frozen_string_literal: true

module TinyGQL
  # Batches loads.  Subclass this and implement `perform`, which gets every
  # key loaded since the last batch and calls `fulfill` for each one:
  #
  #   class AuthorLoader < TinyGQL::Loader
  #     def initialize db
  #       super()
  #       @db = db
  #     end
  #
  #     def perform keys
  #       authors = @db.authors_by_id(keys)
  #       i = 0
  #       while i < keys.length
  #         fulfill keys[i], authors[keys[i]]
  #         i += 1
  #       end
  #     end
  #   end
  #
  # Resolvers return `loader.load(key)`, a Lazy, instead of a value.  The
  # executor finishes the rest of the response before it asks a Lazy for its
  # value, so every key loaded at the same depth is in one batch.
  #
  # Loaders cache what they load, so use one instance per request.  Keep
  # them on the `context` passed to `execute`.
  class Loader
    # Raised when `perform` doesn't fulfill a key it was given
    class BrokenError < StandardError; end

    # @rbs @queue: Hash[untyped, true]
    # @rbs @results: Hash[untyped, untyped]
    # @rbs @errors: Hash[untyped, ExecutionError]

    #: () -> void
    def initialize
      @queue = {}
      @results = {}
      @errors = {}
    end

    # A Lazy for the value of `key`
    #: (untyped) -> Lazy
    def load key
      @queue[key] = true unless @results.key?(key) || @errors.key?(key)
      Lazy.new(self, key)
    end

    # Lazies for the values of `keys`.  A list field can return these
    #: (Array[untyped]) -> Array[Lazy]
    def load_many keys
      lazies = Array.new(keys.length)
      i = 0
      while i < keys.length
        lazies[i] = load(keys[i])
        i += 1
      end
      lazies
    end

    # The value of `key`, performing the batch it's in if it hasn't been.
    # Lazy#sync calls this
    #: (untyped) -> untyped
    def value_for key
      perform_queue unless @results.key?(key) || @errors.key?(key)
      return @results[key] if @results.key?(key)

      error = @errors[key]
      raise BrokenError, "#{self.class} didn't fulfill key #{key.inspect}" unless error
      # Each field gets its own copy, as fields add their paths to errors
      raise error.dup
    end

    private

    # Loads `keys` and calls `fulfill` for each of them.  Raise
    # ExecutionError to make every field waiting on this batch null
    #: (Array[untyped]) -> void
    def perform keys
      raise NotImplementedError, "#{self.class}#perform is not implemented"
    end

    # Sets the value of `key`, for `perform`
    #: (untyped, untyped) -> void
    def fulfill key, value
      @results[key] = value
    end

    #: () -> void
    def perform_queue
      keys = @queue.keys
      @queue = {}
      perform keys
    rescue ExecutionError => e
      i = 0
      while i < keys.length
        @errors[keys[i]] = e unless @results.key?(keys[i])
        i += 1
      end
    end
  end

  # A value a Loader hasn't loaded yet.  Resolvers can return one anywhere
  # they'd return a value, including as items of a list
  class Lazy
    # @rbs @loader: Loader
    # @rbs @key: untyped

    #: (Loader, untyped) -> void
    def initialize loader, key
      @loader = loader
      @key = key
    end

    # The value, which may be another Lazy
    #: () -> untyped
    def sync
      @loader.value_for @key
    end
  end
end
