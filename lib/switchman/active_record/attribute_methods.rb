# frozen_string_literal: true

module Switchman
  module ActiveRecord
    module AttributeMethods
      module ClassMethods

        def sharded_primary_key?
          self != Shard && shard_category != :unsharded && integral_id?
        end

        def sharded_foreign_key?(column_name)
          reflection = reflection_for_integer_attribute(column_name.to_s)
          return false unless reflection
          reflection.options[:polymorphic] || reflection.klass.sharded_primary_key?
        end

        def sharded_column?(column_name)
          column_name = column_name.to_s
          @sharded_column_values ||= {}
          unless @sharded_column_values.has_key?(column_name)
            @sharded_column_values[column_name] = (column_name == primary_key && sharded_primary_key?) || sharded_foreign_key?(column_name)
          end
          @sharded_column_values[column_name]
        end

        protected

        def reflection_for_integer_attribute(attr_name)
          attr_name = attr_name.to_s
          columns_hash[attr_name] && columns_hash[attr_name].type == :integer &&
              reflections.find { |_, r| r.belongs_to? && r.foreign_key.to_s == attr_name }&.last
        rescue ::ActiveRecord::StatementInvalid
          # this is for when models are referenced in initializers before migrations have been run
          raise if connection.open_transactions > 0
        end

        def define_method_global_attribute(attr_name)
          if sharded_column?(attr_name)
            generated_attribute_methods.module_eval <<-RUBY, __FILE__, __LINE__ + 1
              def __temp_global_attribute__
                raw_value = original_#{attr_name}
                return nil if raw_value.nil?
                return raw_value if raw_value > Shard::IDS_PER_SHARD

                Shard.global_id_for(original_#{attr_name}, shard)
              end
              alias_method 'global_#{attr_name}', :__temp_global_attribute__
              undef_method :__temp_global_attribute__
            RUBY
          else
            define_method_unsharded_column(attr_name, 'global')
          end
        end

        def define_method_local_attribute(attr_name)
          if sharded_column?(attr_name)
            generated_attribute_methods.module_eval <<-RUBY, __FILE__, __LINE__ + 1
              def __temp_local_attribute__
                raw_value = original_#{attr_name}
                return nil if raw_value.nil?
                return raw_value % Shard::IDS_PER_SHARD
              end
              alias_method 'local_#{attr_name}', :__temp_local_attribute__
              undef_method :__temp_local_attribute__
            RUBY
          else
            define_method_unsharded_column(attr_name, 'local')
          end
        end

        # see also Base#shard_category_for_reflection
        # the difference being this will output static strings for the common cases, making them
        # more performant
        def shard_category_code_for_reflection(reflection)
          if reflection
            if reflection.options[:polymorphic]
              # a polymorphic association has to be discovered at runtime. This code ends up being something like
              # context_type.&.constantize&.shard_category || :primary
              "read_attribute(:#{reflection.foreign_type})&.constantize&.shard_category || :primary"
            else
              # otherwise we can just return a symbol for the statically known type of the association
              reflection.klass.shard_category.inspect
            end
          else
            shard_category.inspect
          end
        end

        def define_method_original_attribute(attr_name)
          if sharded_column?(attr_name)
            reflection = reflection_for_integer_attribute(attr_name)
            if attr_name == "id" && ::Rails.version >= '5.1.2'
              return if self.method_defined?(:original_id)
              owner = self
            else
              owner = generated_attribute_methods
            end
            owner.module_eval <<-RUBY, __FILE__, __LINE__ + 1
              # rename the original method to original_
              alias_method 'original_#{attr_name}', '#{attr_name}'
              # and replace with one that transposes the id
              def __temp_relative_attribute__
                raw_value = original_#{attr_name}
                return nil if raw_value.nil?

                abs_raw_value = raw_value.abs
                current_shard = Shard.current(#{shard_category_code_for_reflection(reflection)})
                same_shard = shard == current_shard
                return raw_value if same_shard && abs_raw_value < Shard::IDS_PER_SHARD

                value_shard_id = abs_raw_value / Shard::IDS_PER_SHARD
                # this is a stupid case when someone stuffed a global id for the current shard in instead
                # of a local id
                return raw_value % Shard::IDS_PER_SHARD if value_shard_id == current_shard.id
                return raw_value if !same_shard && abs_raw_value > Shard::IDS_PER_SHARD
                return shard.global_id_for(raw_value) if !same_shard && abs_raw_value < Shard::IDS_PER_SHARD

                Shard.relative_id_for(raw_value, shard, current_shard)
              end
              alias_method '#{attr_name}', :__temp_relative_attribute__
              undef_method :__temp_relative_attribute__

              alias_method 'original_#{attr_name}=', '#{attr_name}='
              def __temp_relative_attribute_assignment__(new_value)
                self.original_#{attr_name} = Shard.relative_id_for(new_value, Shard.current(#{shard_category_code_for_reflection(reflection)}), shard)
              end
              alias_method '#{attr_name}=', :__temp_relative_attribute_assignment__
              undef_method :__temp_relative_attribute_assignment__
            RUBY
          else
            define_method_unsharded_column(attr_name, 'global')
          end
        end

        def define_method_unsharded_column(attr_name, prefix)
          return if columns_hash["#{prefix}_#{attr_name}"]
          generated_attribute_methods.module_eval <<-RUBY, __FILE__, __LINE__ + 1
              def __temp_unsharded_attribute__
                raise NoMethodError, "undefined method `#{prefix}_#{attr_name}'; are you missing an association?"
              end
              alias_method '#{prefix}_#{attr_name}', :__temp_unsharded_attribute__
              undef_method :__temp_unsharded_attribute__
          RUBY
        end
      end

      def self.included(klass)
        klass.extend(ClassMethods)
        klass.attribute_method_prefix "global_", "local_", "original_"
      end

      # ensure that we're using the sharded attribute method
      # and not the silly one in AR::AttributeMethods::PrimaryKey
      def id
        self.class.define_attribute_methods
        super
      end
    end
  end
end
