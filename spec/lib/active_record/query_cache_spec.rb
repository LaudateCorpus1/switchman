# frozen_string_literal: true

require "spec_helper"

module Switchman
  module ActiveRecord
    describe QueryCache do
      include RSpecHelper

      after do
        ::ActiveRecord::Base.connection_pool.disable_query_cache!
      end

      it "Works when doing updates with a shard activated" do
        ::ActiveRecord::Base.connection_pool.enable_query_cache!
        @shard1.activate do
          @user1 = User.create!
        end
        @shard2.activate do
          @user2 = User.create!
        end

        root = Root.create!(user: @user1)
        users = @shard1.activate do
          root.update(user: @user2)
          User.all.includes(:roots).to_a
        end
        expect(users[0].roots).to match_array([])
      end

      it "should isolate queries to multiple shards on the same server" do
        expect(::ActiveRecord::Base.connection_pool.query_cache_enabled).to eq false
        ::ActiveRecord::Base.connection_pool.enable_query_cache!

        @shard1.activate do
          expect(User.connection.query_cache_enabled).to eq true
          User.create!
          User.create!
        end
        @shard3.activate do
          expect(User.connection.query_cache_enabled).to eq true
          User.create!
        end
        expect(@shard1.activate { User.all.to_a }).not_to eq @shard3.activate { User.all.to_a }
        @shard1.activate { User.connection.expects(:select).never }
        expect(@shard1.activate { User.all.to_a }).not_to eq @shard3.activate { User.all.to_a }
      end

      it "doesn't break logging with binds" do
        ::Rails.logger.expects(:error).never
        User.connection.cache do
          User.where(id: 1).take
          User.where(id: 1).take
        end
      end
    end
  end
end
