require 'switchman/schema_cache'

module Switchman
  module ConnectionError
    def self.===(other)
      return true if defined?(PG::Error) && PG::Error === other
      return true if defined?(Mysql2::Error) && Mysql2::Error === other
      false
    end
  end

  class ConnectionPoolProxy
    delegate :spec, :connected?, :default_schema, :with_connection, :query_cache_enabled, :active_connection?,
             :to => :current_pool

    attr_reader :category, :schema_cache

    def default_pool
      @default_pool
    end

    def initialize(category, default_pool, shard_connection_pools)
      @category = category
      @default_pool = default_pool
      @connection_pools = shard_connection_pools
      @schema_cache = default_pool.get_schema_cache(nil) if ::Rails.version >= '6'
      @schema_cache = SchemaCache.new(self) unless @schema_cache.is_a?(SchemaCache)
      if ::Rails.version >= '6'
        @default_pool.set_schema_cache(@schema_cache)
        @connection_pools.each_value do |pool|
          pool.set_schema_cache(@schema_cache)
        end
      end
    end

    def active_shard
      Shard.current(@category)
    end

    def active_guard_rail_environment
      ::Rails.env.test? ? :primary : active_shard.database_server.guard_rail_environment
    end

    def current_pool
      current_active_shard = active_shard
      pool = self.default_pool if current_active_shard.database_server == Shard.default.database_server && active_guard_rail_environment == :primary && (current_active_shard.default? || current_active_shard.database_server.shareable?)
      pool = @connection_pools[pool_key] ||= create_pool unless pool
      pool.shard = current_active_shard
      pool
    end

    def connections
      connection_pools.map(&:connections).inject([], &:+)
    end

    def connection(switch_shard: true)
      pool = current_pool
      begin
        connection = pool.connection(switch_shard: switch_shard)
        connection.instance_variable_set(:@schema_cache, @schema_cache) unless ::Rails.version >= '6'
        connection
      rescue ConnectionError
        raise if active_shard.database_server == Shard.default.database_server && active_guard_rail_environment == :primary
        configs = active_shard.database_server.config(active_guard_rail_environment)
        raise unless configs.is_a?(Array)
        configs.each_with_index do |config, idx|
          pool = create_pool(config.dup)
          begin
            connection = pool.connection
            connection.instance_variable_set(:@schema_cache, @schema_cache) unless ::Rails.version >= '6'
          rescue ConnectionError
            raise if idx == configs.length - 1
            next
          end
          @connection_pools[pool_key] = pool
          break connection
        end
      end
    end

    def get_schema_cache(_connection)
      @schema_cache
    end

    %w{release_connection
       disconnect!
       flush!
       clear_reloadable_connections!
       verify_active_connections!
       clear_stale_cached_connections!
       enable_query_cache!
       disable_query_cache! }.each do |method|
      class_eval(<<-RUBY, __FILE__, __LINE__ + 1)
          def #{method}
            connection_pools.each(&:#{method})
          end
      RUBY
    end

    def discard!
      # this breaks everything if i try to pass it onto the pools and i'm not sure why
    end

    def automatic_reconnect=(value)
      connection_pools.each { |pool| pool.automatic_reconnect = value }
    end

    def clear_idle_connections!(since_when)
      connection_pools.each { |pool| pool.clear_idle_connections!(since_when) }
    end

    def remove_shard!(shard)
      connection_pools.each { |pool| pool.remove_shard!(shard) }
    end

    protected

    def connection_pools
      (@connection_pools.values + [default_pool]).uniq
    end

    def pool_key
      [active_guard_rail_environment,
        active_shard.database_server.shareable? ? active_shard.database_server.pool_key : active_shard]
    end

    def create_pool(config = nil)
      shard = active_shard
      unless config
        if shard != Shard.default
          config = shard.database_server.config(active_guard_rail_environment)
          config = config.first if config.is_a?(Array)
          config = config.dup
        else
          # we read @config instead of calling config so that we get the config
          # *before* %{shard_name} is applied
          # also, we can't just read the database server's config, because
          # different models could be using different configs on the default
          # shard, and database server wouldn't know about that
          config = default_pool.spec.instance_variable_get(:@config)
          if config[active_guard_rail_environment].is_a?(Hash)
            config = config.merge(config[active_guard_rail_environment])
          elsif config[active_guard_rail_environment].is_a?(Array)
            config = config.merge(config[active_guard_rail_environment].first)
          else
            config = config.dup
          end
        end
      end
      spec = ::ActiveRecord::ConnectionAdapters::ConnectionSpecification.new(
        category,
        config,
        "#{config[:adapter]}_connection"
      )
      # unfortunately the AR code that does this require logic can't really be
      # called in isolation
      require "active_record/connection_adapters/#{config[:adapter]}_adapter"

      ::ActiveRecord::ConnectionAdapters::ConnectionPool.new(spec).tap do |pool|
        pool.shard = shard
        pool.set_schema_cache(@schema_cache) if ::Rails.version >= '6'
        pool.enable_query_cache! if !@connection_pools.empty? && @connection_pools.first.last.query_cache_enabled
      end
    end
  end
end

