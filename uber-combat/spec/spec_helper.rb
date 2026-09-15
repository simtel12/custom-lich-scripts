# frozen_string_literal: true

require_relative "../lib/uc_character"
require_relative "../lib/uc_zone_table"
require_relative "../lib/uc_zone_picker"
require_relative "../lib/uc_zone_distance"
require_relative "../lib/uc_leg_tracker"
require_relative "../lib/uc_leg_overlay"
require_relative "../lib/uc_leg_settings"
require_relative "../lib/uc_leg_writer"
require_relative "../lib/uc_director"
require_relative "../lib/uc_probe"
require_relative "../lib/uc_town"
require_relative "support/fake_skills"
require_relative "support/fake_zone_table"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
end
