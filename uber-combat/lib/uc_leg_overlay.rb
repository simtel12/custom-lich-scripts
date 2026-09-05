# frozen_string_literal: true

# Maps one hunting leg (ZonePicker#present output) plus live character state
# to a complete profile-overlay settings hash, ready to be handed to a
# separate YAML-emitting component.
#
# Contract: notes/uber-combat/35-overlay-contract.md. Every key name, key
# type and shape below cites that document by its Q-number.
#
# PURE. No Lich, no game runtime, no network, no file reads at call time.
# The caller supplies every external input this needs: the uc_weapons
# catalogue (skill -> weapon string, Zurvan-setup.yaml:74-85), the optional
# uc_spells catalogue, and the set of canonical spell names to validate
# offensive_spells against. Nothing here reads a YAML or data file.
module UberCombat
  class LegOverlay
    # The three strings combat-trainer subtracts against
    # (combat-trainer.lic:340, "['Evasion', 'Parry Ability', 'Shield Usage']
    # - [@priority_defense]"). combat-trainer does NOT validate this itself
    # -- any other string fails to subtract, leaving a 4-entry priority list
    # that silently produces "stance set 0 0 0", i.e. no defence at all
    # (contract Q8). This class raises rather than ever emit a value outside
    # this set.
    VALID_PRIORITY_DEFENSES = ["Evasion", "Parry Ability", "Shield Usage"].freeze

    # The reasons a gap record can carry. Kept a fixed set for the same
    # reason ZonePicker#exclusion_record's is (uc_zone_picker.rb:129-131): a
    # free-text reason invites a silent typo that reads as "no gap".
    GAP_REASONS = [:no_weapon_entry, :unknown_spell_name, :survivability_blacklisted].freeze

    # A Struct, not a bare Hash, so the gap report cannot be dropped by a
    # caller who destructures only what they expect (the Itinerary
    # precedent, uc_zone_picker.rb:48).
    Overlay = Struct.new(:settings, :gaps, keyword_init: true)

    # character: for Character#stance_order (uc_character.rb:129-136). Live,
    #   never a snapshot -- the same rule uc_character.rb:6-8 states for
    #   every character-derived value in this codebase.
    # uc_weapons: Hash[String skill => String weapon]. An empty-string value
    #   is a real bare-hands entry (contract Q5, Zurvan-setup.yaml:68/78)
    #   and must never be treated as "no entry" -- membership is checked
    #   with #key?, never with truthiness.
    # uc_spells: optional Array[Hash] catalogue (Zurvan-setup.yaml:93-102).
    #   Each entry is a normal offensive_spells entry (String keys "name",
    #   "mana", "cast_only_to_train", ...) PLUS a "skill" key naming the
    #   magic skill it trains -- that "skill" key is OUR selector (see
    #   build_offensive_spells below) but it is also a real key
    #   combat-trainer reads on every offensive_spells entry (verified:
    #   combat-trainer.lic:1631, :2538-2548, :2572, :2589-2591, :2616,
    #   :2763 all key off spell['skill']), so it is kept on the emitted
    #   entry, never stripped. nil (the default) means "no catalogue
    #   given": offensive_spells and prioritize_offensive_spells are both
    #   omitted so the character's own setup values stand (contract Q6).
    #   This is also how combat_spell_training's ban is enforced -- there
    #   is no parameter for it anywhere in this class, so there is no code
    #   path that can write it (the user's direct ruling in the brief: it
    #   must always be inherited from setup).
    # known_spell_names: injectable Array/Set of canonical spell names, so
    #   this class never has to load dr-scripts/data/base-spells.yaml
    #   itself to validate offensive_spells entries (contract Q6
    #   correction #5: an unmatched name never gets an abbrev filled in by
    #   the enrichment pass, and combat-trainer.lic:2644 dereferences that
    #   nil with no guard the first time it casts). Canonical names live
    #   under that file's top-level "spell_data" key (base-spells.yaml:565),
    #   not at the file's top level -- irrelevant to this class, since it
    #   never reads the file, but the caller that builds this list needs
    #   to know it. Leaving this at its default empty list is the
    #   fail-safe direction: with nothing known, every candidate is
    #   reported and none is emitted.
    def initialize(character, uc_weapons, uc_spells: nil, known_spell_names: [])
      @character = character
      @uc_weapons = uc_weapons
      @uc_spells = uc_spells
      @known_spell_names = known_spell_names
    end

    # leg: exactly ZonePicker#present's output shape --
    #   { skills:, zone_key:, stance: { policy:, key: }, min_mana: }.
    # duration: optional caller-supplied minutes. nil (the default) omits
    #   the :duration: key entirely, which contract Q2 confirms means
    #   "never stop on time" -- there is no numeric sentinel for that, and
    #   0 stops almost immediately, so nil must never round-trip to a
    #   written 0.
    #
    # Returns an Overlay(settings:, gaps:). settings is ready to hand to the
    # (separate) YAML-emitting component. gaps never drops a record: a leg
    # skill missing from uc_weapons, or an offensive_spells entry whose name
    # is not canonical, is reported and excluded from settings -- never
    # silently written as-is, since that failure mode is not a warning, it
    # is a NoMethodError the first time combat-trainer tries to use it.
    def build(leg, duration: nil)
      settings = {}

      # Selected first, because which skills the spell catalogue covers
      # decides which skills can legitimately have no weapon (see
      # build_weapon_training).
      candidates = spell_candidates(leg)
      valid_spells, spell_gaps = validate_offensive_spells(candidates)

      settings["hunting_info"] = [hunting_info_entry(leg, duration)]

      weapon_training, weapon_gaps = build_weapon_training(leg, candidates.map { |entry| entry["skill"] })
      settings["weapon_training"] = weapon_training

      settings["hunting_room_min_mana"] = leg[:min_mana] unless leg[:min_mana].nil?

      apply_stances(leg, settings)

      # Emit only when at least one catalogue entry SURVIVED validation.
      #
      # Writing an empty list here would be the silent blanking this class
      # exists to avoid: "offensive_spells" REPLACES the character's own
      # value rather than merging with it (contract Q6, setup_files.rb:76-111),
      # so [] leaves a magic leg casting nothing at all. Omitting the key
      # leaves the character's own setup spells standing, which is strictly
      # better than nothing, and the gap record says why we fell back.
      # prioritize_offensive_spells is TRUE whenever offensive_spells is
      # written, and it is not a caller's choice (user, Wave 8). A leg only
      # emits spells because one of its own skills trains by casting, so the
      # spells are the point of the leg rather than a garnish on it. The live
      # Zurvan-tm.yaml sets the pair exactly this way. The two keys are written
      # together, so neither can be left behind by a later edit.
      unless valid_spells.empty?
        settings["offensive_spells"] = valid_spells
        settings["prioritize_offensive_spells"] = true
      end

      Overlay.new(settings: settings, gaps: weapon_gaps + spell_gaps)
    end

    private

    # Symbol :zone and Symbol :duration, String "stop_on" -- contract Q1's
    # mixed key style is not cosmetic. hunting-buddy.lic reads info[:zone]
    # and info['stop_on'] (hunting-buddy.lic:145, :138); the wrong key class
    # makes the value invisible to that reader, not merely mis-typed.
    #
    # stop_on carries the leg's own skill list verbatim, Debilitation
    # included when the leg carries it. should_stop_for_high_skills? uses
    # .all? (hunting-buddy.lic:456-460, contract Q3): every listed skill
    # must lock before the leg's own stop fires. That is the same rule
    # LegTracker's own mindlock backstop already uses (skills.all? { ...
    # mindlocked? }, uc_leg_tracker.rb:93) -- both treat "one skill still
    # learning" as reason enough to keep going, so this is consistent with
    # a leg design already in this codebase, not a new judgement call. It
    # is also redundant with LegTracker by design: LegTracker is the
    # component that actually owns leg advancement session-side, but
    # hunting-buddy.lic runs its own loop and is not guaranteed to be
    # wired to it, so stop_on is a legitimate belt-and-suspenders exit, not
    # dead weight.
    def hunting_info_entry(leg, duration)
      entry = { zone: [leg[:zone_key]], "stop_on" => leg[:skills] }
      entry[:duration] = duration unless duration.nil?
      entry
    end

    # Entries the leg's skills match in the uc_spells catalogue, selected by
    # the catalogue entry's own "skill" key. An empty list means either that
    # no catalogue was supplied or that this leg trains no skill the
    # catalogue covers. Both cases end the same way: offensive_spells is
    # omitted and the character's own setup value stands (user ruling,
    # Wave 8).
    # Two ways a spell reaches a leg (user, 2026-09-05), and the catalogue's
    # own cast_only_to_train flag decides which applies:
    #
    #   cast_only_to_train TRUE  -- the spell exists to train its skill, so it
    #     goes only where the leg trains that skill. Anywhere else CT would
    #     stop casting it anyway: on a no-gain streak it counts the spell and
    #     past magic_gain_check does
    #     `@offensive_spells.reject! { |s| s['skill'] == ... }`
    #     (combat-trainer.lic:2458-2468), removing the whole skill.
    #
    #   cast_only_to_train FALSE or absent -- the spell exists for its EFFECT,
    #     so it rides every leg.
    #
    # THE SECOND RULE IS DEBILITATION ONLY, and the reason is the user's own:
    # Debilitation does no damage by itself. It multiplies -- likelier to hit,
    # or likelier to be missed -- so carrying it onto a leg displaces nothing.
    # A damage spell carried everywhere would displace plenty: overlays set
    # prioritize_offensive_spells, so a Targeted Magic spell on a Brawling leg
    # means CT casts instead of swinging, and the leg trains the wrong skill.
    #
    # Debilitation never occupies a MAX_SKILLS_PER_LEG slot either, because
    # legs are clustered from KILLING_SET and it is not in that set
    # (uc_character.rb:77-81).
    SUPPORT_SKILL = "Debilitation"

    def spell_candidates(leg)
      return [] unless @uc_spells

      @uc_spells.select { |entry| trains_here?(leg, entry) || support_everywhere?(entry) }
    end

    def trains_here?(leg, entry)
      leg[:skills].include?(entry["skill"])
    end

    # != true rather than falsey, so a hand-edited "cast_only_to_train: yes"
    # -- a String in YAML, not the boolean -- is not read as a request to
    # carry a training-only spell onto every leg in the itinerary.
    # use_for_survivability places EXACTLY where cast_only_to_train places
    # (user, 2026-09-05), and the difference is only that combat-trainer keeps
    # casting. "Like cast_only_to_train, but do not stop casting."
    #
    # WHY THAT IS THE RIGHT PLACEMENT, and it is not the every-leg rule I first
    # built. The real criterion is "creatures that can challenge our defences",
    # meaning Parry, Shield Usage and Evasion sit below the creature's upper
    # rank. Rather than build that check, the user chose the placement the code
    # ALREADY computes as a proxy for it: a leg trains a skill only where the
    # zone band admits that skill's rank, and a zone that is rank-appropriate
    # is broadly the one whose creatures test the character's defences. The
    # proxy is imperfect and was chosen knowing that.
    #
    # So the flag NARROWS a Debilitation spell from every leg back to the legs
    # that train it. For any other skill it changes placement not at all, since
    # nothing but Debilitation ever rode every leg -- there it is documentation
    # of intent, and a reminder not to reach for cast_only_to_train.
    def support_everywhere?(entry)
      return false if entry["use_for_survivability"] == true

      entry["skill"] == SUPPORT_SKILL && entry["cast_only_to_train"] != true
    end

    # One entry per leg skill that has a uc_weapons entry. Keys are not
    # restricted to WEAPON_SKILLS -- Targeted Magic is a legitimate entry
    # (contract Q5; combat-trainer.lic:5177 reads @weapons_to_train as a
    # plain skill => weapon Hash with no skillset filtering).
    #
    # spell_skills are the skills this leg matched in the uc_spells
    # catalogue. A skill the catalogue covers trains by casting, not by
    # holding a weapon, so it is NOT a weapon gap. Debilitation is the
    # standing case: it can never lead a leg and always rides one
    # (uc_zone_picker.rb:84-87), and it trains through offensive_spells, so
    # a catalogue will never carry a weapon for it. Reporting it every time
    # would make the gap report fire on every magic leg, and a report that
    # always fires is one nobody reads.
    #
    # Membership is deliberately tested against the skills that MATCHED,
    # not against the ones that survived name validation. A matched entry
    # with a bad spell name already produces its own :unknown_spell_name
    # record, and one misconfiguration must not produce two gap records for
    # the same skill.
    def build_weapon_training(leg, spell_skills)
      weapon_training = {}
      gaps = []
      leg[:skills].each do |skill|
        if @uc_weapons.key?(skill)
          weapon_training[skill] = @uc_weapons[skill]
        elsif !spell_skills.include?(skill)
          gaps << { skill: skill, reason: :no_weapon_entry, detail: {} }
        end
      end
      [weapon_training, gaps]
    end

    # A :spread leg writes the character's live spread ordering under the
    # leg's stance key, exactly as combat-trainer reads it
    # (current_weapon_stance, combat-trainer.lic:5987-5989 ->
    # @stances[weapon_skill]).
    #
    # A :concentrated leg must leave @stances[key] nil so combat-trainer
    # falls through to priority_defense (combat-trainer.lic:328-337, the
    # if/elsif chain: "if game_state.current_weapon_stance ... elsif
    # @priority_defense"). The ONLY safe way to do that is to write
    # "stances" as an EMPTY Hash, never to omit the key entirely.
    #
    # Verified before relying on it (see the four checks below, each with
    # its own citation):
    #   1. base.yaml ships a top-level stances: hash with four weapon keys
    #      -- Bow, Crossbow, Slings, Offhand Weapon (base.yaml:79-96).
    #   2. Profile merge REPLACES a key wholesale, it does not deep-merge
    #      (setup_files.rb:76-111; the union_keys escape hatch is opt-in
    #      per key, and no profile file on this install -- base.yaml,
    #      base-empty.yaml, include-common.yaml, Zurvan-setup.yaml --
    #      declares "stances" in it, so the default replace behaviour
    #      applies here).
    #   3. combat-trainer tolerates @stances being an empty Hash:
    #      @stances.each_key (combat-trainer.lic:5242) simply does not
    #      iterate over {}, and current_weapon_stance's
    #      @stances[weapon_skill] (combat-trainer.lic:5987-5989) returns
    #      nil for any key when @stances is {}. A YAML "stances:" with no
    #      value would parse to nil instead of {}, and nil.each_key would
    #      raise -- so the generated overlay must carry the explicit empty
    #      Hash, never a bare key. This class writes {} literally, never
    #      nil, so that hazard cannot reach the emitter.
    #   4. priority_defense is read once into an ivar
    #      (combat-trainer.lic:24) and only reaches the priority chain in
    #      the elsif branch (combat-trainer.lic:337), which only runs when
    #      the `if game_state.current_weapon_stance` branch above it
    #      (combat-trainer.lic:328) is falsy -- i.e. only when
    #      @stances[weapon_skill] is nil.
    # All four checks held. Omitting "stances" on a concentrated leg would
    # let base.yaml's four-entry hash survive the merge, and if the leg's
    # stance key happens to be one of those four (Bow, Crossbow, Slings or
    # Offhand Weapon), @stances[key] would NOT be nil in combat-trainer and
    # priority_defense would never be consulted -- silently defended by the
    # wrong rule.
    # The ordering is written under EVERY weapon_training key, not under the
    # leg's single stance key. CT only ever consults @stances for a skill it is
    # currently training: @current_weapon_skill is assigned from the selection
    # pools built out of @weapons_to_train (combat-trainer.lic:281-294,
    # :5476-5477), and current_weapon_stance is @stances[weapon_skill]
    # (combat-trainer.lic:5907-5909). A key that is not in weapon_training is
    # therefore DEAD -- CT never looks it up, silently falls through to
    # priority_defense or to the fully dynamic branch, and the leg runs with a
    # stance nobody chose.
    #
    # This is not hypothetical. The picker's stance_key is the first weapon
    # skill in the leg (uc_zone_picker.rb:112-117), which can easily be a skill
    # the uc_weapons catalogue has no entry for. Zurvan's own leg 3 keys on
    # Polearms, which has no weapon, so it never reaches weapon_training.
    #
    # A leg carries ONE stance policy, so giving every trained skill the same
    # ordering is both correct and immune to which skill CT rotates to next.
    # Note that a weapon_training key need not be a weapon skill: Targeted
    # Magic is a real value of weapon_skill (combat-trainer.lic:405, :2693).
    def apply_stances(leg, settings)
      policy = leg[:stance][:policy]

      case policy
      when :spread
        # .dup per key, and it is NOT a style choice. Writing one array object
        # under several keys makes Ruby's YAML dumper emit an anchor and
        # aliases ("Brawling: &1 ... Crossbow: *1"), which has two costs.
        # First, the file stops being readable by a plain YAML.load, which
        # raises Psych::AliasesNotEnabled -- setup_files.rb:65 happens to use
        # unsafe_load_file and so survives, but nothing else that reads or
        # hand-edits the profile is guaranteed to. Second, and worse, every
        # aliased key loads as THE SAME Array object, and CT's normalisation
        # loop appends to stance_list IN PLACE (combat-trainer.lic:5169,
        # :5167), so a mutation through one key silently changes them all.
        order = @character.stance_order(:spread)
        settings["stances"] = settings["weapon_training"].keys.to_h { |skill| [skill, order.dup] }
      when :concentrated
        settings["stances"] = {}
        settings["priority_defense"] = concentrated_priority_defense
      else
        raise ArgumentError, "unknown stance policy: #{policy.inspect}"
      end
    end

    # The strongest defence, per the approved design: stance_order(:concentrated)
    # returns [strongest, middle, lagging] (uc_character.rb:129-136), and
    # .first is the strongest. Validated against VALID_PRIORITY_DEFENSES
    # before it is ever written -- combat-trainer does not validate
    # priority_defense itself (contract Q8), so a value outside the three
    # canonical strings would silently fail to subtract
    # (combat-trainer.lic:340) and leave the character with no defence at
    # all. In practice Character#stance_order can only return one of the
    # three DEFENSE_SKILLS strings (uc_character.rb:27), so this should
    # never fire -- it is a guard against that invariant drifting, not
    # against ordinary bad input.
    def concentrated_priority_defense
      priority = @character.stance_order(:concentrated).first
      unless VALID_PRIORITY_DEFENSES.include?(priority)
        raise ArgumentError, "priority_defense #{priority.inspect} is not one of #{VALID_PRIORITY_DEFENSES}"
      end

      priority
    end

    # candidates are already skill-selected (build's caller). An entry whose
    # "name" is not canonical is reported and dropped, never written: an
    # unmatched name never gets an abbrev filled in by the enrichment pass,
    # and combat-trainer.lic:2644 dereferences that nil with no guard the
    # first time it casts (contract Q6, correction #5). The name match is
    # case-insensitive, mirroring the real lookup (settings_transformer.rb,
    # "looked up case-insensitively against base-spells.yaml's spell
    # table"). The "skill" key is kept on every surviving entry -- it is a
    # real key combat-trainer reads, not just our own selector (see the
    # citations on the uc_spells: param above).
    # use_for_survivability asks for a spell to be cast for its EFFECT, on
    # every leg. cast_only_to_train asks combat-trainer to stop casting it once
    # it stops teaching. Both on one entry is a contradiction that resolves
    # against the user: CT wins, because it owns the casting.
    #
    # And it takes the whole skill down with it, not just this entry --
    # `@offensive_spells.reject! { |s| s['skill'] == ... }`
    # (combat-trainer.lic:2468) -- so ONE sibling spell of the same skill
    # carrying cast_only_to_train is enough to blacklist a survivability spell
    # that does not carry it. That is why this checks the whole candidate list
    # per skill rather than each entry alone.
    #
    # Reported rather than corrected. Silently dropping either flag would be
    # guessing which one the person meant.
    def survivability_conflicts(candidates)
      wanted = candidates.select { |entry| entry["use_for_survivability"] == true }
      return [] if wanted.empty?

      training = candidates.select { |entry| entry["cast_only_to_train"] == true }
                           .map { |entry| entry["skill"] }.uniq

      wanted.select { |entry| training.include?(entry["skill"]) }.map do |entry|
        { skill: entry["skill"], reason: :survivability_blacklisted,
          detail: { name: entry["name"],
                    because: "a #{entry['skill']} spell sets cast_only_to_train, and " \
                             "combat-trainer blacklists the whole skill on a no-gain streak" } }
      end
    end

    def validate_offensive_spells(candidates)
      known = @known_spell_names.map { |name| name.to_s.downcase }

      valid, invalid = candidates.partition { |entry| known.include?(entry["name"].to_s.downcase) }

      gaps = invalid.map do |entry|
        { skill: entry["skill"], reason: :unknown_spell_name, detail: { name: entry["name"] } }
      end

      [valid, gaps + survivability_conflicts(valid)]
    end
  end
end
