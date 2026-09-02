# frozen_string_literal: true

require_relative "../lib/uc_character"
require_relative "../lib/uc_zone_table"
require_relative "../lib/uc_zone_picker"
require_relative "../lib/uc_leg_tracker"
require_relative "support/fake_skills"
require_relative "support/fake_zone_table"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
end
