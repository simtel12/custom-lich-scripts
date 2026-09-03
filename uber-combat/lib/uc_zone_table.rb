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

    # THREE-STATE, and it must stay that way. true is "known premium-only",
    # false is "known open to every account", nil is "nobody has checked yet"
    # -- either premium: null or no premium: key at all. nil is NOT false: the
    # picker admits an unknown zone and reports it (ZonePicker#premium_locked?
    # and #unresolved_premium_records), so collapsing nil to false here would
    # silently retire the report that is the only thing shrinking the unknown
    # list. Same missing-key-versus-false distinction low_confidence? and
    # allow_low_confidence_auto_select? already draw above, for the same
    # reason.
    #
    # Indexed with a String because this key is NESTED. get_data's OpenStruct
    # symbolises the TOP LEVEL only (see ZoneTable#initialize), so in
    # production every key at this depth is still a String. data[:premium]
    # would read nil for all 363 zones -- the fail-open direction, which means
    # it would never raise and never be noticed.
    def premium
      data["premium"]
    end

    # Unknown premium status, the state most of the table is in until the
    # harvest passes fill it in. Kept as its own predicate so callers ask the
    # question instead of re-deriving it from premium.nil?.
    def premium_unknown?
      premium.nil?
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

    # Is this zone inside the named province? A nil or blank name means "no
    # restriction", so everything matches -- the setting is opt-in and its
    # absence must never narrow anything.
    #
    # Comparison is on letters and digits only, folded to lower case, so a
    # person can write Qi'Reshalia, qi reshalia or QiReshalia and get the
    # same answer. The apostrophe is the reason: it is the one province name
    # nobody types the same way twice, and a strict compare would silently
    # admit no zones at all rather than complain.
    #
    # A zone with no province recorded matches NOTHING once a restriction is
    # set. All 363 rows carry one today, so this is a guard rather than a
    # live case, and excluding is the safe direction: the whole point of the
    # setting is to stay near home, and an unlabelled zone cannot promise
    # that.
    def in_province?(name)
      return true if name.nil? || Zone.fold_province(name).empty?
      return false if province.nil?

      Zone.fold_province(province) == Zone.fold_province(name)
    end

    def self.fold_province(value)
      value.to_s.downcase.gsub(/[^a-z0-9]/, "")
    end

    private

    def band
      data["rank"] || {}
    end
  end

  class ZoneTable
    DEFAULT_PATH = File.expand_path("../data/base-uc-zones.yaml", __dir__)

    # An empty table is never legitimate. It reports every skill as having no
    # admissible zone, which reads exactly like a character with nothing to
    # hunt, so it must be loud.
    class EmptyTable < StandardError; end

    attr_reader :zones, :critters

    def self.load(path = DEFAULT_PATH)
      parsed = YAML.load_file(path, aliases: true)
      new(parsed)
    end

    # Production entry point. Lich resolves get_data('uc-zones') to the runtime
    # mirror at lich-5/scripts/data/custom/base-uc-zones.yaml.
    def self.from_game_data
      table = new(fetch_game_data)
      return table unless table.zones.empty?

      raise EmptyTable, "get_data('uc-zones') returned no zones. Check that " \
                        "scripts/data/custom/base-uc-zones.yaml exists and parses."
    end

    # The one call that needs the Lich runtime, kept alone so the parsing above
    # it can be tested without a game session.
    def self.fetch_game_data
      get_data("uc-zones").to_h
    end

    def initialize(parsed)
      # get_data returns an OpenStruct (setup_files.rb:295-298), and
      # OpenStruct#to_h symbolises the TOP LEVEL only: "zones" arrives as
      # :zones while every nested key is still a String. YAML.load_file gives
      # strings throughout. Normalise the one level that differs.
      parsed = parsed.to_h.transform_keys(&:to_s)
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
