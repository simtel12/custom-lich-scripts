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

    # Reachable only by an escort, so the zone key is not a room tag and no
    # amount of travel finds a hunting room in it. hunting-buddy resolves its
    # rooms from the key and exits when the list comes back empty
    # (hunting-buddy.lic:383-386), which a caller sees as a stint that
    # returned in seconds having taught nothing.
    #
    # 18 zones carry this. They are excluded from auto-selection rather than
    # deleted, because the escort route is real and a later wave can use it.
    # What is untrue is that a hunt can be SENT here unaided.
    def escort_access?
      access == "escort"
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

  # Extracted into a module for one reason: spec/support/fake_zone_table.rb
  # includes it too, so the double in the tests runs THIS code rather than a
  # copy of it or a stub that always answers yes. A double that answers a
  # production predicate more generously than production does is how a rule
  # passes every test and then fails in game, and this project has shipped
  # that shape of bug twice already.
  #
  # It needs only #critters and a Zone, which the real table and the fake one
  # expose identically.
  module CritterBands
    # Can this zone's band be trusted to mean "every creature here still
    # teaches"?
    #
    # WHY THE BAND ALREADY MEANS THAT. For all 30 multi-critter zones whose
    # critters carry a band, the zone band is exactly the INTERSECTION of
    # those bands: max(mins) to min(maxes). The band is therefore already the
    # window in which no creature has dropped out, and the ordinary rank test
    # in ZonePicker#admissible? enforces the rule with no help.
    # boar_boobrie_riverhaven reads 50-42 because the boar stops teaching at
    # 42 and the boobrie does not start until 50 -- an empty window. An
    # inverted band can never satisfy rank_min <= rank <= rank_max, so such a
    # zone excludes itself with no code at all.
    #
    # THE HOLE THIS CLOSES. An intersection cannot account for a critter whose
    # own band is unknown. golden_atiket's 120-170 came from the atik'et
    # alone, because the westanuryn's band is nil/nil with rank_confidence
    # "low" and the note "no band text on this row". The zone LOOKS uniform
    # and is not, so a character sent there fights something that teaches it
    # nothing.
    #
    # golden_atiket is the case that DEMONSTRATES the hazard, not a zone this
    # rule still has to catch: it is also access "escort", so Zone#escort_access?
    # -- added in the same change -- already refuses it, and that test runs
    # first. Of the 6 zones failing this predicate, 3 are refused by something
    # else as well (2 escort, 1 low confidence). This rule is the SOLE reason
    # for exactly three: money_grubbers, shifty_eyed_skinflints and orc_scouts,
    # all in Therengia, all with bands a mid-level character would fit.
    # spec/uc_zone_data_integrity_spec.rb pins the counts.
    #
    # That is not cosmetic. combat-trainer DELETES a weapon from
    # weapons_to_train once it stops gaining mindstate (CT:5821-5833). The
    # weak creature disarms the character, and the creature the zone was
    # chosen for then arrives to find nothing willing to attack it.
    #
    # ONLY multi-critter zones are judged. One creature cannot diverge from
    # itself, so a lone unknown band leaves the zone band exactly as
    # trustworthy as the comment it came from. 5 zones are in that state and
    # none of them is at risk.
    def critter_bands_known?(zone)
      refs = zone.critter_refs
      return true if refs.size < 2

      refs.each_value.all? { |key| closed_critter_band?(critters[key]) }
    end

    private

    # Indexed with Strings for the same reason Zone#premium is: these keys are
    # nested, and get_data's OpenStruct symbolises the top level only, so a
    # Symbol here would read nil for every record in production and fail open.
    def closed_critter_band?(record)
      band = record && record["rank"]
      !band.nil? && !band["min"].nil? && !band["max"].nil?
    end
  end

  class ZoneTable
    include CritterBands

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
