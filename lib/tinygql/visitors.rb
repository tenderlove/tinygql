module TinyGQL
  module Visitors
    module Visitor
      def handle_document obj
            obj.definitions.each { _1.accept self }
      end
      def handle_operation_definition obj
        if obj.variable_definitions
            obj.variable_definitions.each { _1.accept self }
        end
        if obj.directives
            obj.directives.each { _1.accept self }
        end
            obj.selection_set.each { _1.accept self }
      end
      def handle_variable obj
      end
      def handle_named_type obj
      end
      def handle_not_null_type obj
            obj.type.accept self
      end
      def handle_list_type obj
            obj.type.accept self
      end
      def handle_variable_definition obj
            obj.variable.accept self
            obj.type.accept self
        if obj.default_value
            obj.default_value.accept self
        end
      end
      def handle_value obj
      end
      def handle_argument obj
            obj.value.accept self
      end
      def handle_field obj
        if obj.arguments
            obj.arguments.each { _1.accept self }
        end
        if obj.directives
            obj.directives.each { _1.accept self }
        end
        if obj.selection_set
            obj.selection_set.each { _1.accept self }
        end
      end
      def handle_object_field obj
            obj.value.accept self
      end
      def handle_int_value obj
      end
      def handle_float_value obj
      end
      def handle_string_value obj
      end
      def handle_boolean_value obj
      end
      def handle_null_value obj
      end
      def handle_enum_value obj
      end
      def handle_list_value obj
      end
      def handle_object_value obj
            obj.values.each { _1.accept self }
      end
      def handle_directive obj
            obj.arguments.each { _1.accept self }
      end
      def handle_type_condition obj
            obj.named_type.accept self
      end
      def handle_inline_fragment obj
        if obj.type_condition
            obj.type_condition.accept self
        end
        if obj.directives
            obj.directives.each { _1.accept self }
        end
            obj.selection_set.each { _1.accept self }
      end
      def handle_fragment_spread obj
            obj.fragment_name.accept self
        if obj.directives
            obj.directives.each { _1.accept self }
        end
      end
      def handle_fragment_definition obj
            obj.fragment_name.accept self
            obj.type_condition.accept self
        if obj.directives
            obj.directives.each { _1.accept self }
        end
            obj.selection_set.each { _1.accept self }
      end
    end

    module Fold
      def handle_document obj, seed
            obj.definitions.each { seed = _1.fold(self, seed) }
        seed
      end
      def handle_operation_definition obj, seed
        if obj.variable_definitions
            obj.variable_definitions.each { seed = _1.fold(self, seed) }
        end
        seed
        if obj.directives
            obj.directives.each { seed = _1.fold(self, seed) }
        end
        seed
            obj.selection_set.each { seed = _1.fold(self, seed) }
        seed
      end
      def handle_variable obj, seed
      end
      def handle_named_type obj, seed
      end
      def handle_not_null_type obj, seed
            seed = obj.type.fold self, seed
        seed
      end
      def handle_list_type obj, seed
            seed = obj.type.fold self, seed
        seed
      end
      def handle_variable_definition obj, seed
            seed = obj.variable.fold self, seed
        seed
            seed = obj.type.fold self, seed
        seed
        if obj.default_value
            seed = obj.default_value.fold self, seed
        end
        seed
      end
      def handle_value obj, seed
      end
      def handle_argument obj, seed
            seed = obj.value.fold self, seed
        seed
      end
      def handle_field obj, seed
        if obj.arguments
            obj.arguments.each { seed = _1.fold(self, seed) }
        end
        seed
        if obj.directives
            obj.directives.each { seed = _1.fold(self, seed) }
        end
        seed
        if obj.selection_set
            obj.selection_set.each { seed = _1.fold(self, seed) }
        end
        seed
      end
      def handle_object_field obj, seed
            seed = obj.value.fold self, seed
        seed
      end
      def handle_int_value obj, seed
      end
      def handle_float_value obj, seed
      end
      def handle_string_value obj, seed
      end
      def handle_boolean_value obj, seed
      end
      def handle_null_value obj, seed
      end
      def handle_enum_value obj, seed
      end
      def handle_list_value obj, seed
      end
      def handle_object_value obj, seed
            obj.values.each { seed = _1.fold(self, seed) }
        seed
      end
      def handle_directive obj, seed
            obj.arguments.each { seed = _1.fold(self, seed) }
        seed
      end
      def handle_type_condition obj, seed
            seed = obj.named_type.fold self, seed
        seed
      end
      def handle_inline_fragment obj, seed
        if obj.type_condition
            seed = obj.type_condition.fold self, seed
        end
        seed
        if obj.directives
            obj.directives.each { seed = _1.fold(self, seed) }
        end
        seed
            obj.selection_set.each { seed = _1.fold(self, seed) }
        seed
      end
      def handle_fragment_spread obj, seed
            seed = obj.fragment_name.fold self, seed
        seed
        if obj.directives
            obj.directives.each { seed = _1.fold(self, seed) }
        end
        seed
      end
      def handle_fragment_definition obj, seed
            seed = obj.fragment_name.fold self, seed
        seed
            seed = obj.type_condition.fold self, seed
        seed
        if obj.directives
            obj.directives.each { seed = _1.fold(self, seed) }
        end
        seed
            obj.selection_set.each { seed = _1.fold(self, seed) }
        seed
      end
    end
  end
end
