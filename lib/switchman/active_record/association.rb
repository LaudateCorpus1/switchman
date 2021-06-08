# frozen_string_literal: true

module Switchman
  module ActiveRecord
    module Association
      def shard
        reflection.shard(owner)
      end

      def build_record(*args)
        self.shard.activate { super }
      end

      def load_target
        self.shard.activate { super }
      end

      def scope
        shard_value = @reflection.options[:multishard] ? @owner : self.shard
        @owner.shard.activate { super.shard(shard_value, :association) }
      end

      def creation_attributes
        attributes = super

        # translate keys
        if reflection.macro.in?([:has_one, :has_many]) && !options[:through]
          attributes[reflection.foreign_key] = Shard.relative_id_for(owner[reflection.active_record_primary_key], owner.shard, self.shard)
        end
        attributes
      end
    end

    module CollectionAssociation
      def find_target
        shards = reflection.options[:multishard] && owner.respond_to?(:associated_shards) ? owner.associated_shards : [shard]
        # activate both the owner and the target's shard category, so that Reflection#join_id_for,
        # when called for the owner, will be returned relative to shard the query will execute on
        Shard.with_each_shard(shards, [klass.shard_category, owner.class.shard_category].uniq) do
          super
        end
      end
    end

    module BelongsToAssociation
      def replace_keys(record)
        if record && record.class.sharded_column?(reflection.association_primary_key(record.class))
          foreign_id = record[reflection.association_primary_key(record.class)]
          owner[reflection.foreign_key] = Shard.relative_id_for(foreign_id, record.shard, owner.shard)
        else
          super
        end
      end

      def shard
        if @owner.class.sharded_column?(@reflection.foreign_key) &&
            foreign_id = @owner[@reflection.foreign_key]
          Shard.shard_for(foreign_id, @owner.shard)
        else
          super
        end
      end
    end

    module Extension
      def self.build(_model, _reflection)
      end

      def self.valid_options
        [:multishard]
      end
    end

    ::ActiveRecord::Associations::Builder::Association.extensions << Extension

    module Preloader
      module Association
        if ::Rails.version >= "5.2" and ::Rails.version < "6.0"
          def run(preloader)
            associated_records_by_owner.each do |owner, records|
              associate_records_to_owner(owner, records)
            end
          end
        end

        if ::Rails.version >= "6.0"
          # Copypasta from Activerecord but with added global_id_for goodness.
          def records_for(ids)
            scope.where(association_key_name => ids).load do |record|
              global_key = if model.shard_category == :unsharded
                             convert_key(record[association_key_name])
                           else
                             Shard.global_id_for(record[association_key_name], record.shard)
                           end
              owner = owners_by_key[global_key.to_s].first
              association = owner.association(reflection.name)
              association.set_inverse_instance(record)
            end
          end

          def records_by_owner
            associated_records_by_owner
          end
        end

        def associated_records_by_owner(preloader = nil)
          return @associated_records_by_owner if defined?(@associated_records_by_owner)
          owners_map = owners_by_key

          if klass.nil? || owners_map.empty?
            records = []
          else
            # determine the shard to search for each owner
            if reflection.macro == :belongs_to
              # for belongs_to, it's the shard of the foreign_key
              partition_proc = ->(owner) do
                if owner.class.sharded_column?(owner_key_name)
                  Shard.shard_for(owner[owner_key_name], owner.shard)
                else
                  Shard.current
                end
              end
            elsif !reflection.options[:multishard]
              # for non-multishard associations, it's *just* the owner's shard
              partition_proc = ->(owner) { owner.shard }
            else
              # for multishard associations, it's the owner object itself
              # (all associated shards)

              # this is the default behavior of partition_by_shard, so just let it be nil
              # to avoid the proc call
              # partition_proc = ->(owner) { owner }
            end

            records = Shard.partition_by_shard(owners, partition_proc) do |partitioned_owners|
              # Some databases impose a limit on the number of ids in a list (in Oracle it's 1000)
              # Make several smaller queries if necessary or make one query if the adapter supports it
              sliced_owners = partitioned_owners.each_slice(model.connection.in_clause_length || partitioned_owners.size)
              sliced_owners.map do |slice|
                relative_owner_keys = slice.map do |owner|
                  key = owner[owner_key_name]
                  if key && owner.class.sharded_column?(owner_key_name)
                    key = Shard.relative_id_for(key, owner.shard, Shard.current(owner.class.shard_category))
                  end
                  key && key.to_s
                end
                relative_owner_keys.compact!
                relative_owner_keys.uniq!
                records_for(relative_owner_keys)
              end
            end
            records.flatten!
          end

          # This ivar may look unused, but remember this is an extension of
          # rails' AR::Associations::Preloader::Association class. It gets used
          # by that class (and its subclasses).
          @preloaded_records = records

          # Each record may have multiple owners, and vice-versa
          @associated_records_by_owner = owners.each_with_object({}) do |owner,h|
            h[owner] = []
          end
          records.each do |record|
            owner_key = record[association_key_name]
            owner_key = Shard.global_id_for(owner_key, record.shard) if owner_key && record.class.sharded_column?(association_key_name)

            owners_map[owner_key.to_s].each do |owner|
              owner.association(reflection.name).set_inverse_instance(record)
              @associated_records_by_owner[owner] << record
            end
          end
          @associated_records_by_owner
        end

        def owners_by_key
          @owners_by_key ||= owners.group_by do |owner|
            key = owner[owner_key_name]
            key = Shard.global_id_for(key, owner.shard) if key && owner.class.sharded_column?(owner_key_name)
            key && key.to_s
          end
        end

        def scope
          build_scope
        end
      end
    end

    module CollectionProxy
      def initialize(*args)
        super
        self.shard_value = scope.shard_value
        self.shard_source_value = :association
      end

      def shard(*args)
        scope.shard(*args)
      end
    end

    module AutosaveAssociation
      def record_changed?(reflection, record, key)
        record.new_record? ||
          (record.has_attribute?(reflection.foreign_key) && record.send(reflection.foreign_key) != key) || # have to use send instead of [] because sharding
          record.attribute_changed?(reflection.foreign_key)
      end

      def save_belongs_to_association(reflection)
        # this seems counter-intuitive, but the autosave code will assign to attribute bypassing switchman,
        # after reading the id attribute _without_ bypassing switchman. So we need Shard.current for the
        # category of the associated record to match Shard.current for the category of self
        shard.activate(shard_category_for_reflection(reflection)) { super }
      end
    end
  end
end
