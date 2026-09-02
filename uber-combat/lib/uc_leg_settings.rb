# frozen_string_literal: true

# Normalises the two Lich-settings inputs uc-leg.lic hands to
# UberCombat::LegOverlay: the uc_weapons / uc_spells catalogue read off
# get_settings, and the canonical spell-name list read off get_data('spells').
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
    # settings: an OpenStruct, exactly get_settings's return value.
    #
    # nil means the character's -setup.yaml carries no uc_weapons: key at
    # all. LegOverlay#build_weapon_training calls @uc_weapons.key?(skill)
    # unconditionally (uc_leg_overlay.rb:190), which raises NoMethodError on
    # nil -- {} is the correct "no catalogue" value instead: every leg skill
    # then reports :no_weapon_entry, which is exactly the "report, never
    # silently skip" behaviour this diagnostic exists to surface.
    def self.uc_weapons(settings)
      settings.uc_weapons || {}
    end

    # nil is a legitimate, DIFFERENT-meaning value to LegOverlay itself
    # (uc_leg_overlay.rb:51-53 and :161-165, spell_candidates: "return []
    # unless @uc_spells"): nil means no catalogue was supplied at all, so
    # offensive_spells is omitted entirely and the character's own setup
    # value stands. An empty Array would reach that same guard the same way
    # today, but it is not the same claim, and manufacturing one out of nil
    # here would erase the distinction the moment that guard's condition
    # ever changes. Pass nil through as nil.
    def self.uc_spells(settings)
      settings.uc_spells
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
