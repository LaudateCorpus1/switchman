# frozen_string_literal: true

require "spec_helper"

module Switchman
  module ActiveRecord
    describe Batches do
      include RSpecHelper

      describe "#find_in_batches" do
        it "doesn't form invalid queries with qualified_names" do
          User.shard(@shard1).find_in_batches {}
        end
      end
    end
  end
end
