# frozen_string_literal: true

require "tinygql/parser"

module TinyGQL
  # An index of the types in a schema document, with extensions merged and
  # type references resolved.
  class Schema
    class Error < StandardError; end

    # `kind` is one of :object, :interface, :union, :scalar, :enum, or :input
    Type = Struct.new(:kind, :name, :fields, :interfaces, :members) do
      def composite?; kind == :object || kind == :interface || kind == :union; end
    end

    # `type_name` is the named type with list and non-null wrappers removed
    Field = Struct.new(:name, :arguments, :type_name)

    Argument = Struct.new(:name, :required)

    BUILTIN_SCALARS = %w{ Int Float String Boolean ID }.freeze

    def self.parse sdl
      new Parser.parse(sdl)
    end

    # Map of type name to Type, in definition order
    attr_reader :types

    # Map of operation type ("query", "mutation", "subscription") to type name
    attr_reader :roots

    def initialize document
      @types = {}
      BUILTIN_SCALARS.each { |name| @types[name] = Type.new(:scalar, name, {}, [], []) }

      roots = nil
      extensions = []

      document.definitions.each do |defn|
        case defn
        when Nodes::SchemaDefinition
          raise Error, "Multiple schema definitions" if roots
          roots = root_operations(defn.root_operation_definitions)
        when Nodes::ObjectTypeDefinition
          add_type :object, defn.name, fields(defn.fields_definition), names(defn.implements_interfaces)
        when Nodes::InterfaceTypeDefinition
          add_type :interface, defn.name, fields(defn.fields_definition), names(defn.implements_interfaces)
        when Nodes::UnionTypeDefinition
          add_type :union, defn.name, {}, [], names(defn.union_member_types)
        when Nodes::ScalarTypeDefinition
          add_type :scalar, defn.name
        when Nodes::EnumTypeDefinition
          add_type :enum, defn.name
        when Nodes::InputObjectTypeDefinition
          add_type :input, defn.name
        when Nodes::SchemaExtension,
             Nodes::ObjectTypeExtension,
             Nodes::InterfaceTypeExtension,
             Nodes::UnionTypeExtension
          extensions << defn
        when Nodes::DirectiveDefinition,
             Nodes::ScalarTypeExtension,
             Nodes::EnumTypeExtension,
             Nodes::InputObjectTypeExtension
          # These don't affect which queries can be parsed
        else
          raise Error, "Unexpected #{defn.class.name.split("::").last} in schema"
        end
      end

      roots ||= %w{ query mutation subscription }.each_with_object({}) { |op, h|
        name = op.capitalize
        h[op] = name if @types.key?(name)
      }

      extensions.each do |ext|
        if ext.schema_extension?
          root_operations(ext.root_operation_definitions || []).each do |op, name|
            raise Error, "Schema already has a #{op} type" if roots.key?(op)
            roots[op] = name
          end
        else
          extend_type ext
        end
      end

      @roots = roots
      check_references
    end

    def [] name
      @types[name]
    end

    # Object types that a value of type `name` could be
    def possible_types name
      type = @types.fetch(name)
      case type.kind
      when :object then [name]
      when :interface
        @types.each_value.select { |t| t.kind == :object && t.interfaces.include?(name) }.map(&:name)
      when :union then type.members
      else []
      end
    end

    private

    def add_type kind, name, fields = {}, interfaces = [], members = []
      # Schema dumps often declare the built in scalars too
      return if kind == :scalar && BUILTIN_SCALARS.include?(name)
      raise Error, "Duplicate type #{name}" if @types.key?(name)
      @types[name] = Type.new(kind, name, fields, interfaces, members)
    end

    def extend_type ext
      type = @types[ext.name]
      raise Error, "Cannot extend unknown type #{ext.name}" unless type

      expected = case ext
                 when Nodes::ObjectTypeExtension then :object
                 when Nodes::InterfaceTypeExtension then :interface
                 when Nodes::UnionTypeExtension then :union
                 end
      raise Error, "Cannot extend #{type.kind} #{type.name} as #{expected}" unless type.kind == expected

      if expected == :union
        type.members.concat names(ext.union_member_types)
      else
        fields(ext.fields_definition).each do |name, field|
          raise Error, "Duplicate field #{type.name}.#{name}" if type.fields.key?(name)
          type.fields[name] = field
        end
        type.interfaces.concat names(ext.implements_interfaces)
      end
    end

    def root_operations defs
      defs.each_with_object({}) { |d, h|
        raise Error, "Duplicate #{d.operation_type} type" if h.key?(d.operation_type)
        h[d.operation_type] = d.named_type.name
      }
    end

    def fields defs
      (defs || []).each_with_object({}) { |d, h|
        raise Error, "Duplicate field #{d.name}" if h.key?(d.name)
        args = (d.arguments_definition || []).map { |a|
          Argument.new(a.name, a.type.not_null_type? && a.default_value.nil?)
        }
        h[d.name] = Field.new(d.name, args, named_type(d.type))
      }
    end

    def named_type type
      type = type.type until type.named_type?
      type.name
    end

    def names list
      (list || []).map(&:name)
    end

    def check_references
      raise Error, "Schema has no query type" unless @roots["query"]

      @roots.each do |op, name|
        type = @types[name]
        raise Error, "Unknown #{op} type #{name}" unless type
        raise Error, "#{op} type #{name} must be an object type" unless type.kind == :object
      end

      @types.each_value do |type|
        type.fields.each_value do |field|
          unless @types.key?(field.type_name)
            raise Error, "Unknown type #{field.type_name} for #{type.name}.#{field.name}"
          end
        end

        type.interfaces.each do |name|
          unless @types[name]&.kind == :interface
            raise Error, "#{type.name} implements #{name}, which is not an interface"
          end
        end

        type.members.each do |name|
          unless @types[name]&.kind == :object
            raise Error, "Union #{type.name} includes #{name}, which is not an object type"
          end
        end
      end
    end
  end
end
