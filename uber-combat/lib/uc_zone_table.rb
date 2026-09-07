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

  # One creature record from the `critters:` dictionary. A thin reader, for the
  # same reason Zone is one: the enrichment flags are THREE-STATE and a caller
  # that indexes the raw hash reads a missing key as nil without ever deciding
  # what nil means.
  #
  # Every predicate below therefore answers true / false / nil, and none of them
  # collapses nil to false. nil is "elanthipedia does not say", which
  # Template:Critter renders as "Unknown" on the page itself. 20 of the 306
  # records have all seven flags nil, because their page is missing or carries
  # no {{Critter}} infobox at all.
  #
  # Indexed with Strings throughout, for the reason Zone#premium documents:
  # these keys are NESTED, get_data's OpenStruct symbolises the top level only,
  # so a Symbol here reads nil for all 306 records in production -- the
  # fail-open direction, which raises nothing and is never noticed.
  class Critter
    attr_reader :key, :data

    def initialize(key, data)
      @key = key
      @data = data || {}
    end

    def noun
      data["noun"]
    end

    def skinnable
      data["skinnable"]
    end

    def drops_boxes
      data["drops_boxes"]
    end

    def construct
      data["construct"]
    end

    def undead
      data["undead"]
    end

    def cursed
      data["cursed"]
    end

    def corporeal
      data["corporeal"]
    end

    # Which of a skin, a part and a bone this creature actually drops. An empty
    # list is a real answer ("the page names all three as No"); nil is "the page
    # names none of the three at all", and 48 records are in that state.
    #
    # NOT the same question as #skinnable. |Skinnable= only says the SKIN verb
    # does something here. An adult desert armadillo is skinnable and yields no
    # hide, only a plated claw. A leg that exists to gather skins wants this;
    # a leg that merely must not waste time skinning wants #skinnable.
    def skin_yields
      data["skin_yields"]
    end

    def yields?(kind)
      y = skin_yields
      y.nil? ? nil : y.include?(kind.to_s)
    end

    # Dissecting is the same permission as skinning: if the SKIN verb works on
    # a creature then DISSECT does too (user, 2026-09-07). Elanthipedia carries
    # no separate field and needs none.
    #
    # An alias rather than a second harvested flag, because the two can never
    # disagree and storing them apart would invite a data pass to make them.
    # It exists as its own name because the leg that reads it is a different
    # leg: a First Aid leg dissects, a skinning leg skins, and both want this
    # question rather than skin_yields.
    def dissectable
      skinnable
    end

    # Incorporeal creatures resist ordinary weapons, so a zone holding one is a
    # bad posting for a character with no way to touch it. Three-state, and the
    # nil is the point: 24 records do not say, and an avoidance filter is
    # exactly where an unknown must not read as "safe".
    def incorporeal
      c = corporeal
      c.nil? ? nil : !c
    end

    # The empath predicate, per the data file's own mode-derivation rules:
    # an empath may attack a construct or an undead and nothing else.
    #
    # Three-state on purpose, and the nil must NOT be read as false by a
    # caller that is about to admit a zone. undead and cursed come from one
    # four-way |Evil= field, so an absent field leaves undead nil rather than
    # false, and "construct: false, undead: nil" is genuinely unknown. Guessing
    # false there is a guild-law violation, not lost yield.
    def construct_or_undead
      return true if construct == true || undead == true
      return false if construct == false && undead == false

      nil
    end

    # Did anyone read a {{Critter}} infobox for this creature at all? False for
    # the 20 records whose page is missing or carries no infobox.
    def flags_known?
      data.dig("provenance", "flags") == "elanthipedia_critter_infobox"
    end

    # The page contradicts ITSELF: |Skinnable= disagrees with the three yield
    # fields. 8 records carry it. Neither half is resolved in the data, so a
    # caller that cares must decide, and most callers should simply exclude.
    def flags_review?
      data["flags_review"] == true
    end

    def flags_review_reason
      data["flags_review_reason"]
    end
  end

  # Zone-level rollups over the enrichment flags, for the mode derivation the
  # data file's header specifies and deliberately does not store: modes are
  # derived at load time, never written down.
  #
  # Extracted into a module for the same reason CritterBands is: the test
  # double includes it, so the rules under test are these rules.
  #
  # HOW A nil COUNTS. Every ratio below divides by the WHOLE roster, so an
  # unknown creature drags the ratio down exactly as a false does. That is the
  # conservative direction for a threshold rule -- a zone is not promoted to a
  # skinning zone on the strength of creatures nobody has checked. It also
  # makes the ratio alone ambiguous, so #flag_census reports the three counts
  # separately and a caller that wants to say WHY a zone missed can.
  #
  # AN EMPTY ROSTER IS nil, NOT ZERO. 32 zones carry no critter_refs at all.
  # A ratio over nothing is undefined, and answering 0.0 would read as "checked,
  # and none of them qualify".
  module CritterFlags
    QUALIFYING = { "skinnable" => :skinnable, "drops_boxes" => :drops_boxes,
                   "cursed" => :cursed, "construct" => :construct,
                   "undead" => :undead, "corporeal" => :corporeal }.freeze

    # Every creature on this zone's roster, as Critter readers. Resolved through
    # critter_refs, never by bare noun: 13 nouns map to 2 or 3 records.
    #
    # A ref pointing at a record the dictionary does not hold yields a Critter
    # over an empty hash rather than a nil, so a caller counting a roster gets
    # the roster's real size and the record reads as all-unknown. Dropping it
    # instead would shrink the denominator and quietly raise every ratio.
    def critters_in(zone)
      zone.critter_refs.map { |_noun, key| Critter.new(key, critters[key]) }
    end

    # Fraction of the roster for which `flag` is true, or nil when the zone has
    # no roster. See the module comment for why nil counts against.
    def qualifying_ratio(zone, flag)
      roster = critters_in(zone)
      return nil if roster.empty?

      reader = QUALIFYING.fetch(flag.to_s)
      roster.count { |critter| critter.public_send(reader) == true }.to_f / roster.size
    end

    # true / false / unknown counts for one flag, so a report can say whether a
    # zone missed a threshold on evidence or on ignorance.
    def flag_census(zone, flag)
      reader = QUALIFYING.fetch(flag.to_s)
      values = critters_in(zone).map { |critter| critter.public_send(reader) }
      { yes: values.count(true), no: values.count(false), unknown: values.count(nil) }
    end

    # The empath mode gate. EVERY creature in the zone must be a construct or an
    # undead, and an unknown creature fails it.
    #
    # This one stays a hard all_of with no threshold, per the data file's own
    # rule: a non-qualifying creature here is an empath attacking a living
    # thing, which is a guild-law violation rather than lost yield, so there is
    # no ratio at which it becomes acceptable. An empty roster fails too -- a
    # zone with nothing recorded cannot promise what lives in it.
    def all_construct_or_undead?(zone)
      roster = critters_in(zone)
      return false if roster.empty?

      roster.all? { |critter| critter.construct_or_undead == true }
    end

    # Is every creature here one an ordinary weapon can touch?
    #
    # The gate for a character with no answer to an incorporeal creature, which
    # is everyone but a cleric: 12 records are incorporeal, spread over 16
    # zones.
    #
    # THIS IS A DIFFERENT AXIS FROM all_construct_or_undead?, AND A CHARACTER
    # CAN NEED BOTH (user, 2026-09-07). That predicate is GUILD LAW -- what an
    # empath MAY attack. This one is CAPABILITY -- what a non-cleric CAN hurt.
    # They are independent: 35 of the 44 undead are corporeal, and an empath
    # may and should fight those; what it cannot do, being no cleric, is touch
    # the other 9. So an empath is admitted by the INTERSECTION of the two,
    # which is 59 zones rather than the 75 the guild rule alone allows.
    #
    # Neither flag substitutes for the other in either direction. Undeath does
    # not imply incorporeality, and incorporeality does not imply undeath: an
    # emaciated umbramagus is incorporeal, not undead, and untouchable all the
    # same.
    #
    # Fails an unknown and fails an empty roster, for the reason
    # all_construct_or_undead? does. This is an avoidance filter, and the
    # direction of a wrong answer here is a character swinging all stint at
    # something it cannot hit.
    def all_corporeal?(zone)
      roster = critters_in(zone)
      return false if roster.empty?

      roster.all? { |critter| critter.corporeal == true }
    end

    # The `normal` mode gate: is there anything here worth stopping for? True
    # when ANY creature on the roster is skinnable or drops boxes. Unknown
    # creatures neither help nor block, so a zone whose roster is entirely
    # unknown answers false.
    def any_loot?(zone)
      critters_in(zone).any? { |critter| critter.skinnable == true || critter.drops_boxes == true }
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
    include CritterFlags

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

    # The same lookup as #critter_for, wrapped in a Critter reader. Kept
    # separate rather than changing what #critter_for returns, because the
    # picker and the data-integrity specs read that raw hash directly.
    #
    # Returns nil for an unrostered noun, exactly as #critter_for does. That is
    # a wanderer, not an error.
    def critter_record_for(zone, noun)
      key = zone.critter_refs[noun]
      key && Critter.new(key, critters[key])
    end
  end
end
