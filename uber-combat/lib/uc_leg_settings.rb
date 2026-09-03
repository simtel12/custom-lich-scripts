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
