# frozen_string_literal: true

require_relative "../lib/charbus_protocol"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
end
