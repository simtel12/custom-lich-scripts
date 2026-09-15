# frozen_string_literal: true

# Normalises the Lich-settings inputs uc-leg.lic hands to
# UberCombat::LegOverlay: the uc_settings catalogue block read off
# get_settings, and the canonical spell-name list read off get_data('spells').
#
# Every uber-combat setting lives under ONE top-level uc_settings: key, so that
# each new setting does not claim a top-level name of its own. That is also the
# home for settings this project has already identified but not yet built --
# uc_gain_check (LegTracker::DEFAULT_GAIN_CHECK today) and the wrapper's own
# hunting-mode preference (the Q26 residual).
#
# ONE place, per the same rule uc_zone_table.rb#initialize follows for its own
# top-level keys. That precedent is not hypothetical: get_data returns an
# OpenStruct whose #to_h symbolises the TOP LEVEL only (setup_files.rb:295-298
# via safe_load_yaml, setup_files.rb:63-65), and that exact mismatch silently
# emptied the zone table in production -- 363 zones became 0 -- while every
# test passed, because from_game_data was the one method with no coverage.
#
# get_settings goes through a MATERIALLY DIFFERENT pipeline than get_data, so
# this class exists to pin its shape down empirically rather than assume it
# is the same hazard:
#   1. Each profile file is parsed with SetupFiles#safe_load_yaml
#      (setup_files.rb:63-65): OpenStruct.new(YAML.unsafe_load_file(fp)).to_h
#      -- symbolises that ONE file's top-level keys.
#   2. SetupFiles#get_settings merges every file's Hash with a plain
#      Hash#merge (setup_files.rb:96-104) -- this does not touch value shapes,
#      it only decides which file's top-level value wins per key.
#   3. SettingsTransformer.transform wraps the merged Hash in ANOTHER
#      OpenStruct (settings_transformer.rb:29) and runs it through seven
#      enrichment phases keyed off settings_config.rb's TRANSFORM_CONFIG.
#      uc_weapons and uc_spells appear in NONE of that config's key lists
#      (spell_map_enrich_data_keys, spell_list_keys, waggle_set_keys, ...),
#      so no phase touches them -- they pass through Hop 3 as plain values.
#
# Verified in spec/uc_leg_settings_spec.rb, which builds the exact shape that
# pipeline produces (not YAML.load_file's shape): a profile's uc_weapons: and
# uc_spells: values keep String keys straight through OpenStruct#uc_weapons /
# #uc_spells method access. OpenStruct never touches a value that is itself a
# Hash or Array -- only the attribute NAME at the level it wraps -- so nested
# content is untouched by every hop above. The "normalisation" below is
# therefore a nil guard, not a key-shape fix. If a future
# settings_config.rb change ever routes uc_weapons or uc_spells through an
# enrichment phase, THIS is the one place that needs to change, and the spec
# is the one place that will fail first.
module UberCombat
  module LegSettings
    # The pre-consolidation top-level keys. Every uber-combat setting now
    # lives under the single uc_settings: key instead, so that new ones never
    # each claim a top-level name. See .legacy_keys for why these are still
    # named here.
    LEGACY_KEYS = [:uc_weapons, :uc_spells].freeze

    # settings: an OpenStruct, exactly get_settings's return value.
    #
    # THE NESTED VALUE KEEPS STRING KEYS. Verified against the real
    # pipeline: OpenStruct#to_h symbolises the key it wraps and NOTHING
    # below it, so settings.uc_settings is a Hash whose own keys are
    # "weapons" and "spells" as Strings. Indexing it with :weapons reads nil
    # -- silently, and every skill then reports as a gap, which reads exactly
    # like a character with no catalogue. This is the same failure that
    # emptied the zone table in game while every test passed
    # (uc_zone_table.rb:100-101).
    def self.uc_settings(settings)
      settings.uc_settings || {}
    end

    # nil means the character's -setup.yaml carries no weapons catalogue at
    # all. LegOverlay#build_weapon_training calls @uc_weapons.key?(skill)
    # unconditionally (uc_leg_overlay.rb:190), which raises NoMethodError on
    # nil -- {} is the correct "no catalogue" value instead: every leg skill
    # then reports :no_weapon_entry, which is exactly the "report, never
    # silently skip" behaviour this diagnostic exists to surface.
    def self.weapons(settings)
      uc_settings(settings)["weapons"] || {}
    end

    # nil is a legitimate, DIFFERENT-meaning value to LegOverlay itself
    # (uc_leg_overlay.rb:51-53 and :161-165, spell_candidates: "return []
    # unless @uc_spells"): nil means no catalogue was supplied at all, so
    # offensive_spells is omitted entirely and the character's own setup
    # value stands. An empty Array would reach that same guard the same way
    # today, but it is not the same claim, and manufacturing one out of nil
    # here would erase the distinction the moment that guard's condition
    # ever changes. Pass nil through as nil.
    def self.spells(settings)
      uc_settings(settings)["spells"]
    end

    # Whether this character's account can reach premium-only hunting zones.
    #
    # DEFAULTS TO FALSE, in three separate absences: no uc_settings: block at
    # all, no premium: key inside it, and premium: null. A character is
    # non-premium unless the profile says otherwise.
    #
    # False is the safe default because its failure mode is the cheap one. A
    # non-premium character defaulted to false loses at most the premium zones
    # from an otherwise full table -- it UNDER-selects. Defaulting to true
    # would route a non-premium character to a zone they cannot travel to, and
    # that hunt fails silently, which is the exact failure this gate was added
    # to stop. Under-selection costs a zone; over-selection costs the hunt.
    #
    # == true rather than truthiness, so a hand-edited "premium: yes" (a
    # String, not the YAML boolean) reads as non-premium instead of unlocking
    # the premium table off a typo. Same direction as the default.
    #
    # Same String-key contract as .weapons above: the value under uc_settings
    # is a plain Hash whose own keys OpenStruct never symbolised, so
    # ["premium"] is the only spelling that reads it (uc_zone_table.rb:100-101
    # for the production incident that pins this down).
    def self.premium(settings)
      uc_settings(settings)["premium"] == true
    end

    # The province the character wants to stay inside, or nil for no limit.
    # Keeps a hunt near its home town instead of sending it somewhere wildly
    # distant that happens to fit the rank band.
    #
    # Unlike `premium`, this is NOT coerced to a boolean, because the value
    # IS the answer: any non-empty string names a province and nil means no
    # restriction. An empty or blank string is treated as nil rather than as
    # a province no zone can match, which would silently admit nothing at
    # all -- the same fail-loud-or-fail-open choice the premium gate makes.
    def self.in_province_only(settings)
      value = uc_settings(settings)["in_province_only"]
      return nil unless value.is_a?(String)

      trimmed = value.strip
      trimmed.empty? ? nil : trimmed
    end

    # How many killing skills one leg may carry, or nil to take the picker's
    # own default. Optional, and most profiles will not set it.
    #
    # There is no single right value, because it depends on what the character
    # trains. A character training two or three skills wants a cap that never
    # bites; a character training every allowed weapon and magic wants its
    # legs divided somewhere sensible. So the default is a middle value and
    # this key is how a person moves it.
    #
    # A non-integer, zero or negative value reads as nil -- the default --
    # rather than as a cap of zero, which would build a leg for every skill
    # and turn one cycle into a dozen stints. Same fail-open-and-report
    # direction as .in_province_only above: the caller prints what it saw, so
    # a typo shows up as a warning instead of as a very strange itinerary.
    def self.max_skills_per_leg(settings)
      value = uc_settings(settings)["max_skills_per_leg"]
      return nil unless value.is_a?(Integer)
      return nil unless value.positive?

      value
    end

    # True when the key is present but unusable, so a caller can say so. A
    # missing key is not a mistake and must never warn.
    def self.bad_max_skills_per_leg?(settings)
      raw = uc_settings(settings)["max_skills_per_leg"]
      !raw.nil? && max_skills_per_leg(settings).nil?
    end

    # Minutes to hunt in one stint, or nil to take the director's default.
    #
    # Mainly here to make a cycle testable in minutes instead of hours: at the
    # default of 30 a three-leg pass is about two hours, which is a long wait
    # to find out whether rotation works. Set it low, watch a whole pass, set
    # it back.
    #
    # The stint TIMEOUT does not shrink with it, and must not. The timeout
    # bounds the untimed parts -- tannery trip, blocking restock, travel, walk
    # home -- and those cost the same whether the hunt is five minutes or
    # fifty. A five-minute stint still takes about thirteen minutes of wall
    # clock, and nearly all of the saving is in the hunting.
    #
    # Same fail-open-and-report shape as .max_skills_per_leg: anything that is
    # not a positive whole number reads as nil, and the caller says so. Zero
    # would be the worst reading to take literally, since hunting-buddy's check
    # is `(counter / 60) >= duration` (hunting-buddy.lic:622) and that is true
    # on its first pass -- every stint would end instantly having taught
    # nothing, and every leg would be skipped for two failures.
    def self.hunt_duration_minutes(settings)
      value = uc_settings(settings)["hunt_duration_minutes"]
      return nil unless value.is_a?(Integer)
      return nil unless value.positive?

      value
    end

    # Present but unusable, so a caller can warn. A missing key is not a
    # mistake and must never warn.
    def self.bad_hunt_duration_minutes?(settings)
      raw = uc_settings(settings)["hunt_duration_minutes"]
      !raw.nil? && hunt_duration_minutes(settings).nil?
    end

    # The creature gates this character requires of every zone, as a list of
    # names from CritterFlags::ZONE_GATES. Empty means no restriction.
    #
    # This is how a guild opts in (user, 2026-09-15). An empath lists
    # construct_or_undead, because it may attack nothing else. A necromancer
    # lists living, because Thanatology is not learned from an undead or a
    # construct. Any non-cleric lists corporeal as well, because an ordinary
    # weapon cannot touch an incorporeal creature.
    #
    # Only well-formed names come back. The caller must check
    # .creature_flag_errors first and refuse to run on any, the same as a
    # misspelled skill: dropping a mistyped `livng` quietly would send a
    # necromancer at undead with nothing to say why.
    def self.require_creature_flags(settings)
      raw = uc_settings(settings)["require_creature_flags"]
      return [] unless raw.is_a?(Array)

      raw.map(&:to_s).select { |name| CritterFlags::ZONE_GATES.key?(name) }.uniq
    end

    # Every way the setting can be wrong, as printable lines. Empty when it is
    # absent or clean.
    #
    # All of these are fatal, not warnings. Each one either drops a gate the
    # person meant to apply, which routes a character at creatures its guild
    # forbids or cannot learn from, or combines gates that admit no zone at
    # all, which reads exactly like a character with nowhere to hunt.
    def self.creature_flag_errors(settings)
      raw = uc_settings(settings)["require_creature_flags"]
      return [] if raw.nil?
      return ["require_creature_flags must be a list, for example [living, corporeal]"] unless raw.is_a?(Array)

      errors = raw.map(&:to_s).reject { |name| CritterFlags::ZONE_GATES.key?(name) }.map do |name|
        "require_creature_flags: #{name} is not one of #{CritterFlags::ZONE_GATES.keys.join(', ')}"
      end
      flags = require_creature_flags(settings)
      if flags.include?("construct_or_undead") && flags.include?("living")
        errors << "require_creature_flags: construct_or_undead and living together admit no zone"
      end
      errors
    end

    # The skills this character actually wants to train: every skill named in
    # the weapons catalogue, plus every skill named in the spells catalogue.
    #
    # THE CATALOGUE IS THE DECLARATION (user, 2026-09-05). Omitting Small Edged
    # from `weapons` means "I do not train Small Edged", not "I forgot". It
    # used to mean the second: the picker built a leg for every trained skill,
    # the overlay reported :no_weapon_entry for the ones with no catalogue
    # entry, and LegWriter refused the leg -- so a character training three of
    # twelve weapons could not run at all.
    #
    # Spells count because a skill can be trained by casting rather than by
    # swinging. Targeted Magic and Debilitation are the standing cases.
    def self.trainable_skills(settings)
      weapon_skills = weapons(settings).keys.map(&:to_s)
      spell_skills = (spells(settings) || []).filter_map { |entry| entry["skill"] }
      (weapon_skills + spell_skills).uniq
    end

    # An EMPTY weapons catalogue is an error, and the one case that must stay
    # loud (user, 2026-09-05). Omitting a weapon is a choice; omitting all of
    # them leaves nothing to hunt with, and combat-trainer keys its stances on
    # an equipped weapon. Silence here would look exactly like a character with
    # nowhere to hunt, which is the failure mode this project keeps meeting.
    def self.no_weapons?(settings)
      weapons(settings).empty?
    end

    # Catalogue entries whose skill name is not a real skill.
    #
    # The valid names are a CLOSED SET, so a typo is detectable rather than
    # merely suspicious, and detectable means it should be an error rather
    # than a report (user, 2026-09-05). Without this check `Small Edge` reads
    # as a deliberate decision not to train Small Edged, which is exactly what
    # a person who typed it did not mean.
    #
    # weapons keys are checked against KILLING_SET rather than TRAINING_SET:
    # Debilitation cannot be trained by swinging anything, so a weapon entry
    # for it is a mistake too. spells entries are checked against
    # TRAINING_SET, where Debilitation belongs.
    #
    # Returns [{name:, source:, suggestion:}], empty when the catalogues are
    # clean.
    def self.unknown_skill_names(settings)
      bad = weapons(settings).keys.map(&:to_s)
                             .reject { |name| Character::KILLING_SET.include?(name) }
                             .map { |name| { name: name, source: "weapons" } }

      bad + (spells(settings) || []).map { |entry| entry["skill"].to_s }
                                    .reject { |name| Character::TRAINING_SET.include?(name) }
                                    .map { |name| { name: name, source: "spells" } }
    end

    # The closest real skill name, or nil when nothing is close enough to be
    # worth guessing at. Cheap on purpose: a shared case-insensitive prefix
    # catches the typos people actually make -- a dropped letter, a missing
    # plural, a wrong ending -- and does not invent a suggestion for a name
    # that is simply not a skill.
    MIN_SUGGESTION_PREFIX = 4

    def self.closest_skill_name(name)
      target = name.to_s.downcase
      best = Character::TRAINING_SET.max_by { |known| shared_prefix(target, known.downcase) }
      return nil if best.nil?

      shared_prefix(target, best.downcase) >= MIN_SUGGESTION_PREFIX ? best : nil
    end

    def self.shared_prefix(one, two)
      limit = [one.length, two.length].min
      (0...limit).find { |i| one[i] != two[i] } || limit
    end
    private_class_method :shared_prefix

    # Names of the OLD top-level keys a profile still carries. The caller
    # prints these as a warning.
    #
    # This exists because a half-migrated profile fails SILENTLY and its
    # symptom is indistinguishable from a real answer: with uc_settings
    # absent, .weapons returns {} and every single leg skill reports
    # :no_weapon_entry -- which reads exactly like "this character has no
    # catalogue yet" rather than "you moved the keys and missed one". The
    # legacy names are cheap to look for and they turn a confusing gap report
    # into one line naming the actual cause.
    def self.legacy_keys(settings)
      LEGACY_KEYS.select { |key| !settings[key].nil? }
    end

    # data: an OpenStruct, exactly get_data('spells')'s return value.
    # Canonical spell names live under base-spells.yaml's top-level
    # spell_data: key (contract Q6 correction #5,
    # notes/uber-combat/35-overlay-contract.md), not at the file's own top
    # level -- there is no top-level "name" list to read instead.
    def self.known_spell_names(data)
      (data.spell_data || {}).keys
    end
  end
end
