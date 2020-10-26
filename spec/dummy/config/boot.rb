# frozen_string_literal: true

require 'rubygems'
gemfile = File.expand_path('../../../../Gemfile', __FILE__)

if File.exist?(ENV['BUNDLE_GEMFILE'] || gemfile)
  ENV['BUNDLE_GEMFILE'] ||= gemfile
  require 'bundler'
  Bundler.setup
end

$:.unshift File.expand_path('../../../../lib', __FILE__)