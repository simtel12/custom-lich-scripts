# frozen_string_literal: true

require "yaml"

# Loader for base-uc-zones.yaml.
#
# Spec: notes/uber-combat/33-zone-picker-spec.md section 1.5 and 1.6.
#
# The file name keeps its "base-" prefix because Lich's loader globs base*.yaml
# and builds the name with to_base_filename (setup_files.rb:201-203). The prefix
# is required, not decorative. Do not tidy it away.
module UberCombat
  # One annotated hunting zone. A thin reader over the parsed YAML hash, so the
  # picker never indexes raw strings and never sees a missing key as a nil band.
  class Zone
    attr_reader :key, :data

    def initialize(key, data)
      @key = key
      @data = data
    end

    def rank_min
      band["min"]
    end

    def rank_max
      band["max"]
    end

    def closed_band?
      !rank_min.nil? && !rank_max.nil?
    end

    def low_confidence?
      data["rank_confidence"] == "low"
    end

    # A3: low rank confidence is a hard exclusion from auto-selection. A zone
    # opts back in per zone, and no zone currently does.
    def allow_low_confidence_auto_select?
      data["allow_low_confidence_auto_select"] == true
    end

    def critter_refs
      data["critter_refs"] || {}
    end

    def critters
      data["critters"] || []
    end

    def access
      data["access"]
    end

    def province
      data["province"]
    end

    private

    def band
      data["rank"] || {}
    end
  end

  class ZoneTable
    DEFAULT_PATH = File.expand_path("../data/base-uc-zones.yaml", __dir__)

    attr_reader :zones, :critters

    def self.load(path = DEFAULT_PATH)
      parsed = YAML.load_file(path, aliases: true)
      new(parsed)
    end

    # Production entry point. Lich resolves get_data('uc-zones') to the runtime
    # mirror at lich-5/scripts/data/custom/base-uc-zones.yaml.
    def self.from_game_data
      new(get_data("uc-zones").to_h)
    end

    def initialize(parsed)
      @critters = parsed["critters"] || {}
      @zones = (parsed["zones"] || {}).map { |key, data| Zone.new(key, data) }
      @by_key = @zones.each_with_object({}) { |zone, index| index[zone.key] = zone }
    end

    def zone(key)
      @by_key[key]
    end

    # Always resolve a noun through the zone's own critter_refs. 13 in-game
    # nouns map to 2 or 3 records with different bands, so critters[noun] is
    # ambiguous and wrong. A nil result means an unrostered wanderer, not an
    # error.
    def critter_for(zone, noun)
      key = zone.critter_refs[noun]
      key && critters[key]
    end
  end
end
