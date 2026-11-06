# frozen_string_literal: true

require "json"
require "tinygql/inputs"
require "tinygql/loader"

module TinyGQL
  # A field error.  Resolvers raise this to make a field null and report an
  # error in the response.  Other exceptions aren't caught
  class ExecutionError < StandardError
    # Response keys and list indexes from the root to the field
    attr_accessor :path #: Array[String | Integer]?

    #: () -> Hash[String, untyped]
    def to_h
      { "message" => message, "path" => path }
    end
  end

  # Executes operations in documents parsed by a generated parser.
  # Generated parsers define a subclass, `MyParser::Executor`, with methods
  # for each of the schema's output types.  Use it through `MyParser.execute`.
  #
  # Fields are resolved by calling a method on the resolvers object named
  # after the object type and field, like `Post_title(obj, args, context)`.
  # `args` is an instance of the field's generated class in
  # `MyParser::Arguments`, like `Arguments::Post_comments`, with a reader
  # for each argument, or nil for fields without arguments.  Arguments are
  # coerced like variables, and missing arguments get their default, or nil
  # when they don't have one.  Generated parsers define a Resolvers class
  # whose methods call the field's name on `obj`, like `obj.title`, and whose
  # methods for interfaces and unions, like `resolve_type_Node(obj,
  # context)`, raise NotImplementedError.  Subclass it to resolve fields.
  #
  # The response is written as JSON, straight into one String, in the
  # order the fields are executed.  No Hash of the result is built.
  #
  # When a field raises ExecutionError, or its value doesn't fit its type,
  # the field is null and the error is added to the response's "errors".
  # Nulls in non-null fields make their parent null instead, up to the
  # nearest field that can be null.  That position's JSON is cut back to
  # where it started and replaced with `null`.
  #
  # Resolvers can return a Lazy from a Loader instead of a value.  Lazies
  # are queued, leaving a hole in the JSON, and once the rest of the
  # response is done the queue is drained: each Lazy's value is written to
  # its own Segment, which can queue more Lazies.  Each depth of the
  # response loads in one batch.  The fields of a mutation drain the queue
  # one at a time, so they run in order.  When everything is done, the
  # segments are spliced into their holes.  Responses without Lazies are
  # never copied.
  class Executor
    # JSON written while completing Lazies, and where it goes.  `buf` is the
    # JSON.  `holes` are the Lazies waiting inside it, in the order they're
    # in `buf`.  `nulls` are positions in `buf` that a Lazy's error made
    # null after they were written.  `hole` is where the segment goes, nil
    # for the response
    class Segment
      attr_reader :buf #: String
      attr_reader :holes #: Array[Hole]
      attr_reader :hole #: Hole?
      attr_accessor :nulls #: Array[path]?

      #: (String, Hole?) -> void
      def initialize buf, hole
        @buf = buf
        @holes = []
        @hole = hole
        @nulls = nil
      end
    end

    # Where a Lazy's JSON goes: `offset` bytes into `segment`'s JSON.
    # `fill` is the Segment the Lazy's value was written to, or nil for
    # null.  `dead` holes were inside JSON that was cut back, so their
    # Lazies still run but their JSON isn't used
    class Hole
      attr_reader :segment #: Segment
      attr_reader :offset #: Integer
      attr_accessor :fill #: Segment?
      attr_accessor :dead #: bool

      #: (Segment, Integer) -> void
      def initialize segment, offset
        @segment = segment
        @offset = offset
        @fill = nil
        @dead = false
      end

      # Whether this hole's JSON is used: it isn't dead, and neither is any
      # hole it's inside
      #: () -> bool
      def live?
        hole = self
        while hole
          return false if hole.dead
          hole = hole.segment.hole
        end
        true
      end
    end

    # The position of an object or list in the response, as a linked list.
    # Each node has the parent's position, the key the value is at, whether
    # it can be null, and the Segment and byte range its JSON is in.  The
    # range ends at nil until the value is written.  Lazies completed after
    # the rest of the response use it to make the nearest nullable position
    # null
    # @rbs!
    #   type path = [path?, String | Integer, bool, Segment, Integer, Integer?]

    # Characters JSON escapes in strings
    JSON_ESCAPE = /["\\\x00-\x1f]/ #: Regexp

    # The JSON that starts every response
    DATA = '{"data":' #: String

    # @rbs @resolvers: untyped
    # @rbs @scalars: Scalars
    # @rbs @inputs: Inputs
    # @rbs @variables: Array[untyped]
    # @rbs @context: untyped
    # @rbs @errors: Array[ExecutionError]
    # @rbs @segment: Segment
    # @rbs @buf: String
    # @rbs @fragments: Hash[String, Nodes::FragmentDefinition]
    # @rbs @collected: Hash[Array[Nodes::Field | Nodes::OperationDefinition], Hash[String, Array[untyped]]]
    # @rbs @lazies: Array[untyped]

    #: (untyped, Scalars, Inputs, Array[untyped], untyped) -> void
    def initialize resolvers, scalars, inputs, variables, context
      @resolvers = resolvers
      @scalars = scalars
      @inputs = inputs
      @variables = variables
      @context = context
      @errors = []
      @fragments = {}
      # Fields collected for each list of field nodes and object type.
      # Lists of field nodes come from earlier collections, so the fields of
      # a list of objects are only collected once
      @collected = {}.compare_by_identity
      # Lazies waiting to be completed, six entries each: the type, field
      # nodes, Lazy, path, key, and the Hole the value goes in
      @lazies = []
      @buf = +DATA
      @segment = Segment.new(@buf, nil)
    end

    # Executes operation `op` in `doc` and writes the response, a JSON
    # object with "data" and, if there were errors, "errors", to `out`:
    # anything with `<<`, like a String, a StringIO or an IO.  Returns `out`.
    # Without `out`, returns the response as a new String.
    #
    # The response can't be written to `out` until it's done, because a
    # null in a non-null field can still replace JSON that's already
    # written.  It's built in a String, then written to `out` once.  When
    # Lazies left holes in it, the pieces are written to `out` in order
    # instead of being joined first
    #: (Nodes::Document, String?, untyped, ?untyped) -> untyped
    def execute doc, op, root, out = nil
      operation = @inputs.operation(doc, op)

      definitions = doc.definitions
      i = 0
      while i < definitions.length
        definition = definitions[i]
        @fragments[definition.fragment_name] = definition if definition.fragment_definition?
        i += 1
      end

      segment = begin
        execute_operation(operation.type, root, [operation].freeze)
        drain
        @segment
      rescue ExecutionError => e
        # A non-null root field was null
        @errors << e
        Segment.new(+'{"data":null', nil)
      end

      buf = segment.buf
      unless @errors.empty?
        errors = Array.new(@errors.length)
        i = 0
        while i < errors.length
          errors[i] = @errors[i].to_h
          i += 1
        end
        buf << ',"errors":' << JSON.generate(errors)
      end
      buf << "}"

      if segment.holes.empty? && segment.nulls.nil?
        return buf unless out
        out << buf
      else
        out ||= +""
        splice segment, out
      end
      out
    end

    private

    # The fields to execute on an object of `type` for `nodes`, the field
    # nodes that share a response key, or the operation.  Returns a flat
    # Array of response keys, the field nodes for each key, and the JSON
    # that goes before the key's value: the key, its colon, and the opening
    # brace or a comma
    #: (String, Array[Nodes::Field | Nodes::OperationDefinition]) -> Array[untyped]
    def collect_fields type, nodes
      by_type = @collected[nodes] ||= {}
      collected = by_type[type]
      return collected if collected

      fields = {}
      visited = {}
      i = 0
      while i < nodes.length
        collect_selections type, nodes[i].selection_set, fields, visited
        i += 1
      end

      keys = fields.keys
      collected = Array.new(keys.length * 3)
      i = 0
      while i < keys.length
        key = keys[i]
        collected[i * 3] = key
        collected[i * 3 + 1] = fields[key].freeze
        # The JSON before the key's value.  Response keys are names, so they
        # never need escaping
        collected[i * 3 + 2] = (i == 0 ? "{\"#{key}\":" : ",\"#{key}\":").freeze
        i += 1
      end
      by_type[type] = collected.freeze
    end

    #: (String, Array[Nodes::Field | Nodes::InlineFragment | Nodes::FragmentSpread], Hash[String, Array[Nodes::Field]], Hash[String, true]) -> void
    def collect_selections type, selections, fields, visited
      i = 0
      while i < selections.length
        selection = selections[i]
        if included?(selection.directives)
          if selection.field?
            key = selection.aliaz || selection.name
            (fields[key] ||= []) << selection
          elsif selection.inline_fragment?
            condition = selection.type_condition
            if condition.nil? || fragment_applies?(condition.named_type.name, type)
              collect_selections type, selection.selection_set, fields, visited
            end
          else
            name = selection.fragment_name
            unless visited.key?(name)
              visited[name] = true
              fragment = @fragments[name]
              if fragment_applies?(fragment.type_condition.named_type.name, type)
                collect_selections type, fragment.selection_set, fields, visited
              end
            end
          end
        end
        i += 1
      end
    end

    # Whether @skip and @include let a selection be executed
    #: (Array[Nodes::Directive]?) -> bool
    def included? directives
      return true unless directives
      i = 0
      while i < directives.length
        directive = directives[i]
        case directive.name
        when "skip" then return false if directive_condition(directive)
        when "include" then return false unless directive_condition(directive)
        end
        i += 1
      end
      true
    end

    # The value of the `if` argument of @skip or @include
    #: (Nodes::Directive) -> bool
    def directive_condition directive
      arguments = directive.arguments
      i = 0
      while i < arguments.length
        argument = arguments[i]
        if argument.name == "if"
          value = argument.value
          condition = if value.variable?
            @variables[value.index]
          elsif value.boolean_value?
            value.value == "true"
          end
          return condition if true == condition || false == condition
        end
        i += 1
      end
      raise ExecutionError, "@#{directive.name} needs a Boolean if argument"
    end

    # Writes the value a resolver returned for a field of `type`, at `key`
    # in the object or list at `path`.  A Lazy leaves a hole, which `drain`
    # fills
    #: (Nodes::NamedType | Nodes::ListType | Nodes::NotNullType, Array[Nodes::Field], untyped, path?, String | Integer) -> void
    def complete_value type, nodes, value, path, key
      if value.is_a?(Lazy)
        segment = @segment
        hole = Hole.new(segment, @buf.bytesize)
        segment.holes << hole
        @lazies << type << nodes << value << path << key << hole
      elsif type.not_null_type?
        raise null_error(nodes) if value.nil?
        complete_present type.type, nodes, value, path, key, false
      elsif value.nil?
        @buf << "null"
      else
        complete_present type, nodes, value, path, key, true
      end
    end

    #: (Array[Nodes::Field]) -> ExecutionError
    def null_error nodes
      ExecutionError.new("Cannot return null for non-nullable field #{nodes[0].parent_type}.#{nodes[0].name}")
    end

    # Writes a value that isn't nil, of a named or list type
    #: (Nodes::NamedType | Nodes::ListType | Nodes::NotNullType, Array[Nodes::Field], untyped, path?, String | Integer, bool) -> void
    def complete_present type, nodes, value, path, key, nullable
      if type.list_type?
        node = [path, key, nullable, @segment, @buf.bytesize, nil]
        complete_list type.type, nodes, value, node
        node[5] = @buf.bytesize
      else
        complete_named type.name, nodes, value, path, key, nullable
      end
    end

    # Writes the items of `values`, anything with `each`, like an Array or
    # an ActiveRecord relation
    #: (Nodes::NamedType | Nodes::ListType | Nodes::NotNullType, Array[Nodes::Field], untyped, path) -> void
    def complete_list type, nodes, values, path
      buf = @buf
      buf << "["
      i = 0
      values.each do |value|
        buf << "," if i > 0
        complete_item type, nodes, value, path, i
        i += 1
      end
      buf << "]"
    rescue NoMethodError => e
      # Only when `values` has no `each`, not when something completing the
      # items does
      raise unless e.name == :each && e.receiver.equal?(values)
      raise ExecutionError, "Expected a list for field #{nodes[0].parent_type}.#{nodes[0].name}, got #{values.class}"
    end

    # Writes the list item at `i`
    #: (Nodes::NamedType | Nodes::ListType | Nodes::NotNullType, Array[Nodes::Field], untyped, path, Integer) -> void
    def complete_item type, nodes, value, path, i
      start = @buf.bytesize
      complete_value(type, nodes, value, path, i)
    rescue ExecutionError, Scalars::InvalidValue => e
      field_error(e, type, path, i, start)
    end

    # Writes the value of a scalar, as coerce_result_X returned it.
    # `nullable` is whether the position can be null
    #: (untyped, Array[Nodes::Field], bool) -> void
    def complete_scalar value, nodes, nullable
      buf = @buf
      case value
      when String
        # Generated parsers write Strings that need no escaping themselves
        buf << JSON.generate(value)
      when Integer then buf << value.to_s
      when true then buf << "true"
      when false then buf << "false"
      when nil
        raise null_error(nodes) unless nullable
        buf << "null"
      else
        buf << JSON.generate(value)
      end
    end

    # Writes the JSON each queued Lazy's value to its hole's Segment, until
    # there are none.  Completing a Lazy's value can queue more, which wait
    # for the next round, so each round loads one batch per Loader
    #: () -> void
    def drain
      return if @lazies.empty?
      segment = @segment
      buf = @buf
      begin
        until @lazies.empty?
          lazies = @lazies
          @lazies = []
          i = 0
          while i < lazies.length
            type = lazies[i]
            nodes = lazies[i + 1]
            path = lazies[i + 3]
            key = lazies[i + 4]
            hole = lazies[i + 5]
            fill = @segment = Segment.new(@buf = +"", hole)
            begin
              complete_value(type, nodes, lazies[i + 2].sync, path, key)
              hole.fill = fill
            rescue ExecutionError, Scalars::InvalidValue => e
              lazy_error e, type, path, key, hole
            end
            i += 6
          end
        end
      ensure
        @segment = segment
        @buf = buf
      end
    end

    # Handles an error for a Lazy's value, like field_error.  The positions
    # above it are already written, so a null in a non-null position makes
    # the nearest nullable one null.  If there isn't one, the error goes to
    # `execute` and "data" is null.  Lazies inside JSON that was already cut
    # back to null only add their error
    #: (StandardError, Nodes::NamedType | Nodes::ListType | Nodes::NotNullType, path?, String | Integer, Hole) -> void
    def lazy_error error, type, path, key, hole
      error = execution_error(error, path, key)
      if type.not_null_type? && hole.live?
        while path
          if path[2]
            (path[3].nulls ||= []) << path
            @errors << error
            return
          end
          path = path[0]
        end
        raise error
      end
      @errors << error
    end

    # Writes `segment`'s JSON to `out`, with its holes filled and the
    # positions Lazies made null replaced with null
    #: (Segment, String) -> String
    def splice segment, out
      buf = segment.buf
      holes = segment.holes
      nulls = segment.nulls
      nulls = nulls.sort_by { _1[4] } if nulls && nulls.length > 1
      at = 0
      h = 0
      n = 0
      while true
        hole = holes[h]
        null = nulls && nulls[n]
        if null && (hole.nil? || null[4] <= hole.offset)
          if null[4] >= at
            out << buf.byteslice(at, null[4] - at) << "null"
            at = null[5]
          end
          n += 1
        elsif hole
          if hole.offset >= at
            out << buf.byteslice(at, hole.offset - at)
            fill = hole.fill
            fill ? splice(fill, out) : out << "null"
            at = hole.offset
          end
          h += 1
        else
          break
        end
      end
      out << buf.byteslice(at, buf.bytesize - at)
    end

    #: (Hash[String, true], String, untyped) -> String
    def complete_enum values, type, value
      value = value.name if value.is_a?(Symbol)
      unless value.is_a?(String) && values.key?(value)
        raise ExecutionError, "Enum #{type} cannot represent value: #{value.inspect}"
      end
      value
    end

    # Handles an error for the value of `type` at `key` under `path`, which
    # started `start` bytes into the JSON.  The value becomes null, unless
    # its type is non-null, then the error goes to the parent
    #: (StandardError, Nodes::NamedType | Nodes::ListType | Nodes::NotNullType, path?, String | Integer, Integer) -> void
    def field_error error, type, path, key, start
      error = execution_error(error, path, key)
      raise error if type.not_null_type?
      cut start
      @buf << "null"
      @errors << error
    end

    # Cuts the JSON back to `start` bytes.  Lazies whose holes were in the
    # removed JSON still run, but their JSON isn't used
    #: (Integer) -> void
    def cut start
      buf = @buf
      return if buf.bytesize == start
      holes = @segment.holes
      while (hole = holes.last) && hole.offset >= start
        hole.dead = true
        holes.pop
      end
      if buf.respond_to?(:bytesplice)
        buf.bytesplice(start, buf.bytesize - start, "")
      else
        buf.replace(buf.byteslice(0, start))
      end
    end

    # `error` as an ExecutionError with a path, unless it already has one
    #: (StandardError, path?, String | Integer) -> ExecutionError
    def execution_error error, path, key
      error = ExecutionError.new(error.message) unless error.is_a?(ExecutionError)
      error.path ||= path_array(path, key)
      error
    end

    #: (path?, String | Integer) -> Array[String | Integer]
    def path_array path, key
      list = [key]
      while path
        list.unshift path[1]
        path = path[0]
      end
      list
    end

    # The value of an argument of `type`, for a field's argument Hash.
    # Returns UNDEFINED for missing variables, so the argument's default is
    # used
    #: (String, Nodes::NamedType | Nodes::ListType | Nodes::NotNullType, Nodes::Value | Nodes::ObjectValue | Nodes::Variable) -> untyped
    def argument_value name, type, node
      value = @inputs.literal_value(type, node, @variables)
      if value.nil? && type.not_null_type?
        raise ExecutionError, "Argument #{name} of non-null type must not be null"
      end
      value
    rescue Scalars::InvalidValue => e
      raise ExecutionError, "Invalid value for argument #{name}: #{e.message}"
    end
  end
end
