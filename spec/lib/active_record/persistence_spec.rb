# frozen_string_literal: true

require "spec_helper"

module Switchman
  module ActiveRecord
    describe FinderMethods do
      include RSpecHelper

      describe "#touch" do
        it "should touch on the correct shard" do
          user = @shard1.activate { User.create! }

          old_time = 1.day.ago
          @shard1.activate do
            User.where(:id => user).update_all(:updated_at => old_time)
          end

          expect(user.reload.updated_at.to_i).to eq old_time.to_i
          user.touch
          expect(user.reload.updated_at.to_i).to_not eq old_time.to_i
        end
      end

      describe "#update_columns" do
        it "should update on the correct shard" do
          user = @shard1.activate { User.create! }

          new_time = 1.day.from_now
          expect(user.update_columns(:updated_at => new_time)).to eq true
          expect(user.reload.updated_at.to_i).to eq new_time.to_i
        end
      end
    end
  end
end
