# frozen_string_literal: true

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
  # When a field raises ExecutionError, or its value doesn't fit its type,
  # the field is null and the error is added to the response's "errors".
  # Nulls in non-null fields make their parent null instead, up to the
  # nearest field that can be null.
  #
  # Resolvers can return a Lazy from a Loader instead of a value.  Lazies
  # are queued, and once the rest of the response is done the queue is
  # drained: each Lazy's value is completed where the Lazy was, which can
  # queue more Lazies.  Each depth of the response loads in one batch.  The
  # fields of a mutation drain the queue one at a time, so they run in order.
  class Executor
    # The position of an object or list in the response, as a linked list.
    # Each node has the parent's position, the key the value is at, the
    # Hash or Array it's in, and whether it can be null.  Lazies completed
    # after the rest of the response use it to make the nearest nullable
    # position null
    # @rbs!
    #   type path = [path?, String | Integer, Hash[String, untyped] | Array[untyped], bool]

    # @rbs @resolvers: untyped
    # @rbs @scalars: Scalars
    # @rbs @inputs: Inputs
    # @rbs @variables: Array[untyped]
    # @rbs @context: untyped
    # @rbs @errors: Array[ExecutionError]
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
      # nodes, Lazy, path, key, and the Hash or Array the value goes in
      @lazies = []
    end

    # Executes operation `op` in `doc` and returns the response, a Hash
    # with "data" and, if there were errors, "errors"
    #: (Nodes::Document, String?, untyped) -> Hash[String, untyped]
    def execute doc, op, root
      operation = @inputs.operation(doc, op)

      definitions = doc.definitions
      i = 0
      while i < definitions.length
        definition = definitions[i]
        @fragments[definition.fragment_name] = definition if definition.fragment_definition?
        i += 1
      end

      data = begin
        data = execute_operation(operation.type, root, [operation].freeze)
        drain
        data
      rescue ExecutionError => e
        # A non-null root field was null
        @errors << e
        nil
      end

      response = { "data" => data }
      unless @errors.empty?
        errors = Array.new(@errors.length)
        i = 0
        while i < errors.length
          errors[i] = @errors[i].to_h
          i += 1
        end
        response["errors"] = errors
      end
      response
    end

    private

    # The fields to execute on an object of `type` for `nodes`, the field
    # nodes that share a response key, or the operation.  Returns a flat
    # Array of response keys and the field nodes for each key
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
      collected = Array.new(keys.length * 2)
      i = 0
      while i < keys.length
        collected[i * 2] = keys[i]
        collected[i * 2 + 1] = fields[keys[i]].freeze
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

    # Completes the value a resolver returned for a field of `type`.  The
    # value goes at `key` in `container`, the Hash or Array at `path`.
    # Lazies are queued, and nil holds their place
    #: (Nodes::NamedType | Nodes::ListType | Nodes::NotNullType, Array[Nodes::Field], untyped, path?, String | Integer, Hash[String, untyped] | Array[untyped]) -> untyped
    def complete_value type, nodes, value, path, key, container
      if value.is_a?(Lazy)
        @lazies << type << nodes << value << path << key << container
        nil
      elsif type.not_null_type?
        value = complete_present(type.type, nodes, value, path, key, container, false) unless value.nil?
        if value.nil?
          raise ExecutionError, "Cannot return null for non-nullable field #{nodes[0].parent_type}.#{nodes[0].name}"
        end
        value
      elsif value.nil?
        nil
      else
        complete_present type, nodes, value, path, key, container, true
      end
    end

    # Completes a value that isn't nil, of a named or list type
    #: (Nodes::NamedType | Nodes::ListType | Nodes::NotNullType, Array[Nodes::Field], untyped, path?, String | Integer, Hash[String, untyped] | Array[untyped], bool) -> untyped
    def complete_present type, nodes, value, path, key, container, nullable
      if type.list_type?
        unless value.is_a?(Array)
          raise ExecutionError, "Expected a list for field #{nodes[0].parent_type}.#{nodes[0].name}, got #{value.class}"
        end
        complete_list type.type, nodes, value, [path, key, container, nullable]
      else
        complete_named type.name, nodes, value, path, key, container, nullable
      end
    end

    #: (Nodes::NamedType | Nodes::ListType | Nodes::NotNullType, Array[Nodes::Field], Array[untyped], path) -> Array[untyped]
    def complete_list type, nodes, values, path
      list = Array.new(values.length)
      i = 0
      while i < values.length
        begin
          list[i] = complete_value(type, nodes, values[i], path, i, list)
        rescue ExecutionError, Scalars::InvalidValue => e
          list[i] = field_error(e, type, path, i)
        end
        i += 1
      end
      list
    end

    # Completes queued Lazies until there are none.  Completing a Lazy's
    # value can queue more, which wait for the next round, so each round
    # loads one batch per Loader
    #: () -> void
    def drain
      until @lazies.empty?
        lazies = @lazies
        @lazies = []
        i = 0
        while i < lazies.length
          type = lazies[i]
          nodes = lazies[i + 1]
          path = lazies[i + 3]
          key = lazies[i + 4]
          container = lazies[i + 5]
          begin
            container[key] = complete_value(type, nodes, lazies[i + 2].sync, path, key, container)
          rescue ExecutionError, Scalars::InvalidValue => e
            lazy_error e, type, path, key, container
          end
          i += 6
        end
      end
    end

    # Handles an error for a Lazy's value, like field_error.  The positions
    # above it are already in the response, so a null in a non-null
    # position replaces the nearest nullable one.  If there isn't one, the
    # error goes to `execute` and "data" is null
    #: (StandardError, Nodes::NamedType | Nodes::ListType | Nodes::NotNullType, path?, String | Integer, Hash[String, untyped] | Array[untyped]) -> void
    def lazy_error error, type, path, key, container
      error = execution_error(error, path, key)
      if type.not_null_type?
        while path
          if path[3]
            path[2][path[1]] = nil
            @errors << error
            return
          end
          path = path[0]
        end
        raise error
      end
      container[key] = nil
      @errors << error
    end

    #: (Hash[String, true], String, untyped) -> String
    def complete_enum values, type, value
      value = value.name if value.is_a?(Symbol)
      unless value.is_a?(String) && values.key?(value)
        raise ExecutionError, "Enum #{type} cannot represent value: #{value.inspect}"
      end
      value
    end

    # Handles an error for the value of `type` at `key` under `path`.  The
    # value becomes null, unless its type is non-null, then the error goes
    # to the parent
    #: (StandardError, Nodes::NamedType | Nodes::ListType | Nodes::NotNullType, path?, String | Integer) -> nil
    def field_error error, type, path, key
      error = execution_error(error, path, key)
      raise error if type.not_null_type?
      @errors << error
      nil
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
