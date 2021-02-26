module Switchman
  module Rake
    def self.filter_database_servers(&block)
      chain = filter_database_servers_chain # use a local variable so that the current chain is closed over in the following lambda
      @filter_database_servers_chain = lambda { |servers| block.call(servers, chain) }
    end

    def self.scope(base_scope = Shard,
      database_server: ENV['DATABASE_SERVER'],
      shard: ENV['SHARD'])
      servers = DatabaseServer.all

      if database_server
        servers = database_server
        if servers.first == '-'
          negative = true
          servers = servers[1..-1]
        end
        servers = servers.split(',')
        open = servers.delete('open')

        servers = servers.map { |server| DatabaseServer.find(server) }.compact
        if open
          open_servers = DatabaseServer.all.select { |server| server.config[:open] }
          servers.concat(open_servers)
          servers << DatabaseServer.find(nil) if open_servers.empty?
          servers.uniq!
        end
        servers = DatabaseServer.all - servers if negative
      end

      servers = filter_database_servers_chain.call(servers)

      scope = base_scope.order(::Arel.sql("database_server_id IS NOT NULL, database_server_id, id"))
      if servers != DatabaseServer.all
        conditions = ["database_server_id IN (?)", servers.map(&:id)]
        conditions.first << " OR database_server_id IS NULL" if servers.include?(Shard.default.database_server)
        scope = scope.where(conditions)
      end

      if shard
        scope = shard_scope(scope, shard)
      end

      scope
    end

    def self.options
      { parallel: ENV['PARALLEL'].to_i, max_procs: ENV['MAX_PARALLEL_PROCS'] }
    end

    # categories - an array or proc, to activate as the current shard during the
    # task. tasks which modify the schema may want to pass all categories in
    # so that schema updates for non-default tables happen against all shards.
    # this is handled automatically for the default migration tasks, below.
    def self.shardify_task(task_name, categories: [:primary])
      old_task = ::Rake::Task[task_name]
      old_actions = old_task.actions.dup
      old_task.actions.clear

      old_task.enhance do |*task_args|
        if ::Rails.env.test?
          require 'switchman/test_helper'
          TestHelper.recreate_persistent_test_shards(dont_create: true)
        end

        ::GuardRail.activate(:deploy) do
          Shard.default.database_server.unguard do
            begin
              categories = categories.call if categories.respond_to?(:call)
              Shard.with_each_shard(scope, categories, options) do
                shard = Shard.current
                puts "#{shard.id}: #{shard.description}"
                ::ActiveRecord::Base.connection_pool.spec.config[:shard_name] = Shard.current.name
                # Adopted from the deprecated code that currently lives in rails proper
                remaining_configs = ::ActiveRecord::Base.configurations.configurations.reject { |db_config| db_config.env_name == ::Rails.env }
                new_config = ::ActiveRecord::DatabaseConfigurations.new(::Rails.env =>
                  ::ActiveRecord::Base.connection_pool.spec.config.stringify_keys).configurations
                new_configs = remaining_configs + new_config
    
                ::ActiveRecord::Base.configurations = new_configs
                shard.database_server.unguard do
                  old_actions.each { |action| action.call(*task_args) }
                end
                nil
              end
            rescue => e
              puts "Exception from #{e.current_shard.id}: #{e.current_shard.description}" if options[:parallel] != 0
              raise
            end
          end
        end
      end
    end

    %w{db:migrate db:migrate:up db:migrate:down db:rollback}.each do |task_name|
      shardify_task(task_name, categories: ->{ Shard.categories })
    end

    private

    def self.shard_scope(scope, raw_shard_ids)
      raw_shard_ids = raw_shard_ids.split(',')

      shard_ids = []
      negative_shard_ids = []
      ranges = []
      negative_ranges = []
      total_shard_count = nil

      raw_shard_ids.each do |id|
        case id
        when 'default'
          shard_ids << Shard.default.id
        when '-default'
          negative_shard_ids << Shard.default.id
        when 'primary'
          shard_ids.concat(Shard.primary.pluck(:id))
        when '-primary'
          negative_shard_ids.concat(Shard.primary.pluck(:id))
        when /^(-?)(\d+)?\.\.(\.)?(\d+)?$/
          negative, start, open, finish = $1.present?, $2, $3.present?, $4
          raise "Invalid shard id or range: #{id}" unless start || finish
          range = []
          range << "id>=#{start}" if start
          range << "id<#{'=' unless open}#{finish}" if finish
          (negative ? negative_ranges : ranges) << "(#{range.join(' AND ')})"
        when /^-(\d+)$/
          negative_shard_ids << $1.to_i
        when /^\d+$/
          shard_ids << id.to_i
        when %r{^(-?\d+)/(\d+)$}
          numerator = $1.to_i
          denominator = $2.to_i
          if numerator == 0 || numerator.abs > denominator
            raise "Invalid fractional chunk: #{id}"
          end
          # one chunk means everything
          if denominator == 1
            next if numerator == 1
            return scope.none
          end

          total_shard_count ||= scope.count
          per_chunk = (total_shard_count / denominator.to_f).ceil
          index = numerator.abs

          # more chunks than shards; the trailing chunks are all empty
          return scope.none if index > total_shard_count

          subscope = Shard.select(:id).order(:id)
          select = []
          if index != 1
            subscope = subscope.offset(per_chunk * (index - 1))
            select << "MIN(id) AS min_id"
          end
          if index != denominator
            subscope = subscope.limit(per_chunk)
            select << "MAX(id) AS max_id"
          end

          result = Shard.from(subscope).select(select.join(", ")).to_a.first
          if index == 1
            range = "id<=#{result['max_id']}"
          elsif index == denominator
            range = "id>=#{result['min_id']}"
          else
            range = "(id>=#{result['min_id']} AND id<=#{result['max_id']})"
          end

          (numerator < 0 ? negative_ranges : ranges) <<  range
          else
          raise "Invalid shard id or range: #{id}"
        end
      end

      shard_ids.uniq!
      negative_shard_ids.uniq!
      unless shard_ids.empty?
        shard_ids -= negative_shard_ids
        if shard_ids.empty? && ranges.empty?
          return scope.none
        end
        # we already trimmed them all out; no need to make the server do it as well
        negative_shard_ids = [] if ranges.empty?
      end

      conditions = []
      positive_queries = []
      unless ranges.empty?
        positive_queries << ranges.join(" OR ")
      end
      unless shard_ids.empty?
        positive_queries << "id IN (?)"
        conditions << shard_ids
      end
      positive_query = positive_queries.join(" OR ")
      scope = scope.where(positive_query, *conditions) unless positive_queries.empty?

      scope = scope.where("NOT (#{negative_ranges.join(" OR")})") unless negative_ranges.empty?
      scope = scope.where("id NOT IN (?)", negative_shard_ids) unless negative_shard_ids.empty?
      scope
    end

    def self.filter_database_servers_chain
      @filter_database_servers_chain ||= ->(servers) { servers }
    end
  end

  module ActiveRecord
    module PostgreSQLDatabaseTasks
      def structure_dump(filename, extra_flags=nil)
        set_psql_env
        args = ['-s', '-x', '-O', '-f', filename]
        args.concat(Array(extra_flags)) if extra_flags
        search_path = configuration['schema_search_path']
        shard = Shard.current.name
        serialized_search_path = shard
        args << "--schema=#{Shellwords.escape(shard)}"

        args << configuration['database']
        run_cmd('pg_dump', args, 'dumping')
        File.open(filename, "a") { |f| f << "SET search_path TO #{serialized_search_path};\n\n" }
      end
    end
  end
end

ActiveRecord::Tasks::PostgreSQLDatabaseTasks.prepend(Switchman::ActiveRecord::PostgreSQLDatabaseTasks)
