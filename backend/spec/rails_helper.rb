require "simplecov"
SimpleCov.start "rails" do
  enable_coverage :branch
  skip "/spec/"
end
ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
abort("Rails is running in production mode!") if Rails.env.production?
require "rspec/rails"
require "webmock/rspec"
require "committee/rails/test/methods"
WebMock.disable_net_connect!

Dir[Rails.root.join("spec/support/**/*.rb")].sort.each { |f| require f }
ActiveRecord::Migration.maintain_test_schema!

RSpec.configure do |config|
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_run_when_matching :focus
  config.include FactoryBot::Syntax::Methods
  config.include ActiveSupport::Testing::TimeHelpers
  config.before { Clock.reset!; Rails.cache.clear; ApplicationController.cache_store.clear }
end
