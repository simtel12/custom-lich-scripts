# frozen_string_literal: true

# Wave 8. Contract: notes/uber-combat/35-overlay-contract.md.
#
# A character double whose stance_order can be made to return something
# outside the three canonical defence strings. Real Character can never do
# this (it always sorts DEFENSE_SKILLS, uc_character.rb:27), so this is the
# only way to exercise LegOverlay's own guard against that invariant
# drifting.
class BadOrderCharacter
  def initialize(order)
    @order = order
  end

  def stance_order(_mode)
    @order
  end
end

RSpec.describe UberCombat::LegOverlay do
  # Drazoken's real defence vector (uc_stance_order_spec.rb:20-23). Evasion is
  # strongest, Parry Ability lags.
  let(:character) do
    UberCombat::Character.new(
      FakeSkills.new({ "Evasion" => 168, "Shield Usage" => 151, "Parry Ability" => 141 },
                     {}, { "Evasion" => 20, "Shield Usage" => 30, "Parry Ability" => 10 })
    )
  end

  let(:uc_weapons) do
    {
      "Targeted Magic"  => "steel scimitar",
      "Small Edged"     => "steel scimitar",
      "Twohanded Blunt" => "war mattock",
      "Brawling"        => ""
    }
  end

  # The example leg from the brief, exactly as ZonePicker#present emits it.
  let(:concentrated_leg) do
    { skills: ["Targeted Magic", "Small Edged", "Twohanded Blunt", "Debilitation"],
      zone_key: "tree_snakes_spiders_baearholt",
      stance: { policy: :concentrated, key: "Small Edged" },
      min_mana: nil }
  end

  let(:spread_leg) do
    { skills: ["Small Edged", "Brawling"],
      zone_key: "some_zone",
      stance: { policy: :spread, key: "Small Edged" },
      min_mana: 10 }
  end

  def overlay(**kwargs)
    described_class.new(character, uc_weapons, **kwargs)
  end

  describe "hunting_info" do
    it "is a one-element list mixing a Symbol :zone key and a String stop_on key" do
      settings = overlay.build(concentrated_leg).settings

      entry = settings["hunting_info"].first
      expect(settings["hunting_info"].size).to eq(1)
      expect(entry[:zone]).to eq(["tree_snakes_spiders_baearholt"])
      expect(entry["stop_on"]).to eq(concentrated_leg[:skills])
    end

    it "carries the leg's skills verbatim, Debilitation included" do
      entry = overlay.build(concentrated_leg).settings["hunting_info"].first
      expect(entry["stop_on"]).to include("Debilitation")
    end

    it "omits :duration: when the caller supplies none" do
      entry = overlay.build(concentrated_leg).settings["hunting_info"].first
      expect(entry.key?(:duration)).to be false
    end

    it "writes :duration: only when the caller supplies one, even 0" do
      entry = overlay.build(concentrated_leg, duration: 0).settings["hunting_info"].first
      expect(entry[:duration]).to eq(0)
    end

    it "writes a real duration when given" do
      entry = overlay.build(concentrated_leg, duration: 30).settings["hunting_info"].first
      expect(entry[:duration]).to eq(30)
    end
  end

  describe "args" do
    it "is never written -- hunting-buddy.lic appends the suffix itself" do
      settings = overlay.build(concentrated_leg).settings
      expect(settings.key?("args")).to be false
      expect(settings["hunting_info"].first.key?("args")).to be false
    end
  end

  describe "weapon_training" do
    it "carries one entry per leg skill that has a uc_weapons entry" do
      settings = overlay.build(concentrated_leg).settings
      expect(settings["weapon_training"]).to eq(
        "Targeted Magic"  => "steel scimitar",
        "Small Edged"     => "steel scimitar",
        "Twohanded Blunt" => "war mattock"
      )
    end

    it "keeps an empty-string bare-hands entry, never drops it" do
      leg = { skills: ["Brawling"], zone_key: "z", stance: { policy: :spread, key: "Brawling" }, min_mana: nil }
      settings = overlay.build(leg).settings
      expect(settings["weapon_training"]).to eq("Brawling" => "")
      expect(settings["weapon_training"].key?("Brawling")).to be true
    end

    it "reports, never silently drops, a leg skill with no uc_weapons entry" do
      result = overlay.build(concentrated_leg)
      expect(result.gaps).to include(skill: "Debilitation", reason: :no_weapon_entry, detail: {})
      expect(result.settings["weapon_training"].key?("Debilitation")).to be false
    end

    it "is not restricted to WEAPON_SKILLS -- Targeted Magic is a legitimate entry" do
      settings = overlay.build(concentrated_leg).settings
      expect(settings["weapon_training"]).to have_key("Targeted Magic")
    end
  end

  describe "hunting_room_min_mana" do
    it "is omitted when the leg's min_mana is nil" do
      settings = overlay.build(concentrated_leg).settings
      expect(settings.key?("hunting_room_min_mana")).to be false
    end

    it "is written when the leg carries a non-nil min_mana" do
      settings = overlay.build(spread_leg).settings
      expect(settings["hunting_room_min_mana"]).to eq(10)
    end

    it "is written even when the leg's min_mana is 0" do
      leg = concentrated_leg.merge(min_mana: 0)
      settings = overlay.build(leg).settings
      expect(settings["hunting_room_min_mana"]).to eq(0)
    end
  end

  describe "combat_spell_training" do
    it "is never written under any circumstance" do
      settings = overlay(uc_spells: [{ "skill" => "Targeted Magic", "name" => "Fists of Faenella" }],
                         known_spell_names: ["Fists of Faenella"]).build(concentrated_leg).settings
      expect(settings.key?("combat_spell_training")).to be false
    end
  end

  describe "stances and priority_defense, spread" do
    it "writes the character's live spread ordering under EVERY weapon_training key" do
      settings = overlay.build(spread_leg).settings
      order = ["Evasion", "Parry Ability", "Shield Usage"]

      expect(settings["stances"].keys).to match_array(settings["weapon_training"].keys)
      expect(settings["stances"].values).to all(eq(order))
    end

    # CT only consults @stances for a skill it is currently training
    # (combat-trainer.lic:281-294, :5476-5477, :5907-5909), so an ordering
    # written under a skill that never reaches weapon_training is dead: CT
    # falls through to priority_defense or the dynamic branch and the leg runs
    # with a stance nobody chose. The picker's stance_key is simply the first
    # weapon skill in the leg (uc_zone_picker.rb:112-117), and it can name a
    # skill the catalogue has no weapon for. Zurvan's own leg 3 does exactly
    # that: it keys on Polearms, which has no weapon.
    it "never writes a stance key that weapon_training does not carry" do
      leg = { skills: ["Polearms", "Small Edged"], zone_key: "z",
              stance: { policy: :spread, key: "Polearms" }, min_mana: nil }
      settings = overlay.build(leg).settings

      expect(settings["weapon_training"]).not_to have_key("Polearms")
      expect(settings["stances"]).not_to have_key("Polearms")
      expect(settings["stances"].keys).to eq(["Small Edged"])
    end

    # Found by the first real in-game run. One array object written under
    # several keys makes Ruby's YAML dumper emit an anchor and aliases, which
    # (a) breaks a plain YAML.load with Psych::AliasesNotEnabled, and (b) loads
    # every key as THE SAME Array, which CT's normalisation loop then mutates
    # in place through all of them at once (combat-trainer.lic:5167, :5169).
    it "gives every stance key its own array, so the dump carries no YAML alias" do
      require "yaml"
      settings = overlay.build(spread_leg).settings
      lists = settings["stances"].values

      expect(lists.map(&:object_id).uniq.size).to eq(lists.size)
      expect(settings.to_yaml).not_to match(/: [&*]\d/)
    end

    it "does not write priority_defense on a spread leg" do
      settings = overlay.build(spread_leg).settings
      expect(settings.key?("priority_defense")).to be false
    end
  end

  describe "stances and priority_defense, concentrated" do
    it "writes stances as an EMPTY Hash, not omitted, so it replaces base.yaml's four-key hash" do
      settings = overlay.build(concentrated_leg).settings
      expect(settings["stances"]).to eq({})
    end

    it "writes priority_defense to the strongest defence" do
      settings = overlay.build(concentrated_leg).settings
      expect(settings["priority_defense"]).to eq("Evasion")
    end

    it "raises rather than emit a priority_defense outside the three canonical strings" do
      bad_character = BadOrderCharacter.new(["Bogus", "Evasion", "Parry Ability"])
      bad_overlay = described_class.new(bad_character, uc_weapons)

      expect { bad_overlay.build(concentrated_leg) }.to raise_error(ArgumentError, /Bogus/)
    end
  end

  describe "an unknown stance policy" do
    it "raises rather than silently doing nothing" do
      leg = concentrated_leg.merge(stance: { policy: :dynamic, key: "Small Edged" })
      expect { overlay.build(leg) }.to raise_error(ArgumentError, /dynamic/)
    end
  end

  describe "offensive_spells and prioritize_offensive_spells" do
    let(:uc_spells) do
      [
        { "skill" => "Targeted Magic", "name" => "Fists of Faenella", "cast_only_to_train" => true },
        { "skill" => "Debilitation", "name" => "Malediction", "mana" => 5 },
        { "skill" => "Bow", "name" => "Whatever Bow Spell" }
      ]
    end
    let(:known_spell_names) { ["Fists of Faenella", "Malediction"] }

    it "omits both keys when no catalogue is given" do
      settings = overlay.build(concentrated_leg).settings
      expect(settings.key?("offensive_spells")).to be false
      expect(settings.key?("prioritize_offensive_spells")).to be false
    end

    it "omits both keys when the catalogue has no entry for this leg's skills" do
      leg = { skills: ["Crossbow"], zone_key: "z", stance: { policy: :spread, key: "Crossbow" }, min_mana: nil }
      settings = overlay(uc_spells: uc_spells, known_spell_names: known_spell_names).build(leg).settings

      expect(settings.key?("offensive_spells")).to be false
      expect(settings.key?("prioritize_offensive_spells")).to be false
    end

    it "emits only the catalogue entries whose skill is in this leg" do
      settings = overlay(uc_spells: uc_spells, known_spell_names: known_spell_names).build(concentrated_leg).settings

      expect(settings["offensive_spells"]).to contain_exactly(
        { "skill" => "Targeted Magic", "name" => "Fists of Faenella", "cast_only_to_train" => true },
        { "skill" => "Debilitation", "name" => "Malediction", "mana" => 5 }
      )
    end

    it "keeps the skill key on the emitted entry -- combat-trainer reads spell['skill'] directly" do
      settings = overlay(uc_spells: uc_spells, known_spell_names: known_spell_names).build(concentrated_leg).settings

      expect(settings["offensive_spells"].map { |entry| entry["skill"] }).to contain_exactly(
        "Targeted Magic", "Debilitation"
      )
    end

    # Always true when spells are written, never a caller's choice (user,
    # Wave 8). A leg only emits spells because one of its own skills trains by
    # casting, so the spells are the point of the leg. There is deliberately no
    # constructor parameter, so no caller can turn it off.
    it "always writes prioritize_offensive_spells true alongside offensive_spells" do
      settings = overlay(uc_spells: uc_spells, known_spell_names: known_spell_names)
                 .build(concentrated_leg).settings

      expect(settings["prioritize_offensive_spells"]).to be true
    end

    it "takes no constructor parameter that could switch prioritisation off" do
      expect(described_class.instance_method(:initialize).parameters.map(&:last))
        .not_to include(:prioritize_offensive_spells)
    end

    it "reports and drops an entry whose name is not in the known-name set" do
      leg = { skills: ["Bow"], zone_key: "z", stance: { policy: :spread, key: "Bow" }, min_mana: nil }
      result = overlay(uc_spells: uc_spells, known_spell_names: known_spell_names).build(leg)

      expect(result.settings["offensive_spells"]).to be_nil
      expect(result.gaps).to include(
        skill: "Bow", reason: :unknown_spell_name, detail: { name: "Whatever Bow Spell" }
      )
    end

    # NEVER write an empty list here. offensive_spells REPLACES the character's
    # own value rather than merging with it, so [] leaves a magic leg casting
    # nothing at all. Omitting the key falls back to the character's own setup
    # spells, and the gap record says why.
    it "omits offensive_spells entirely when no candidate survives validation" do
      leg = { skills: ["Bow"], zone_key: "z", stance: { policy: :spread, key: "Bow" }, min_mana: nil }
      settings = overlay(uc_spells: uc_spells, known_spell_names: known_spell_names).build(leg).settings

      expect(settings.key?("offensive_spells")).to be false
      expect(settings.key?("prioritize_offensive_spells")).to be false
    end

    it "emits the survivors when only some candidates fail validation" do
      leg = { skills: ["Targeted Magic", "Bow"], zone_key: "z",
              stance: { policy: :spread, key: "Bow" }, min_mana: nil }
      result = overlay(uc_spells: uc_spells, known_spell_names: known_spell_names).build(leg)

      expect(result.settings["offensive_spells"].map { |entry| entry["name"] }).to eq(["Fists of Faenella"])
      expect(result.gaps.map { |gap| gap[:reason] }).to include(:unknown_spell_name)
    end

    it "matches names case-insensitively, like the real enrichment lookup" do
      leg = { skills: ["Targeted Magic"], zone_key: "z", stance: { policy: :spread, key: "Targeted Magic" },
              min_mana: nil }
      spells = [{ "skill" => "Targeted Magic", "name" => "fists of faenella" }]

      settings = overlay(uc_spells: spells, known_spell_names: ["Fists of Faenella"]).build(leg).settings

      expect(settings["offensive_spells"]).to eq([{ "skill" => "Targeted Magic", "name" => "fists of faenella" }])
    end

    it "with an empty known_spell_names set, reports every candidate and emits none (fail-safe direction)" do
      result = overlay(uc_spells: uc_spells).build(concentrated_leg)

      expect(result.settings.key?("offensive_spells")).to be false
      expect(result.gaps.select { |gap| gap[:reason] == :unknown_spell_name }.size).to eq(2)
    end
  end

  # Debilitation can never lead a leg and always rides one
  # (uc_zone_picker.rb:84-87), and it trains by casting, so no weapon
  # catalogue will ever carry an entry for it. Reporting it as a missing
  # weapon would fire the gap report on every single magic leg, and a report
  # that always fires is one nobody reads.
  describe "a skill the spell catalogue covers" do
    let(:uc_spells) do
      [
        { "skill" => "Targeted Magic", "name" => "Fists of Faenella", "cast_only_to_train" => true },
        { "skill" => "Debilitation", "name" => "Malediction", "mana" => 5 }
      ]
    end
    let(:known_spell_names) { ["Fists of Faenella", "Malediction"] }

    it "is not reported as a missing weapon" do
      result = overlay(uc_spells: uc_spells, known_spell_names: known_spell_names).build(concentrated_leg)

      expect(result.gaps.map { |gap| gap[:skill] }).not_to include("Debilitation")
      expect(result.gaps).to be_empty
    end

    it "is still reported when no catalogue covers it" do
      result = overlay.build(concentrated_leg)

      expect(result.gaps).to contain_exactly(skill: "Debilitation", reason: :no_weapon_entry, detail: {})
    end

    it "gets no weapon_training entry either, because it trains by casting" do
      settings = overlay(uc_spells: uc_spells, known_spell_names: known_spell_names)
                 .build(concentrated_leg).settings

      expect(settings["weapon_training"]).not_to have_key("Debilitation")
    end

    it "produces exactly one gap, not two, when its spell name is bad" do
      spells = [{ "skill" => "Debilitation", "name" => "Typo Spell" }]
      result = overlay(uc_spells: spells, known_spell_names: known_spell_names).build(concentrated_leg)

      deb = result.gaps.select { |gap| gap[:skill] == "Debilitation" }
      expect(deb.size).to eq(1)
      expect(deb.first[:reason]).to eq(:unknown_spell_name)
    end
  end

  describe "combining several gap reasons in one build" do
    it "never drops one gap in favor of another" do
      uc_spells = [{ "skill" => "Small Edged", "name" => "Unknown Spell" }]
      result = overlay(uc_spells: uc_spells, known_spell_names: []).build(concentrated_leg)

      expect(result.gaps).to contain_exactly(
        { skill: "Debilitation", reason: :no_weapon_entry, detail: {} },
        { skill: "Small Edged", reason: :unknown_spell_name, detail: { name: "Unknown Spell" } }
      )
    end
  end

  describe "the returned Overlay" do
    it "is a Struct that always carries both settings and gaps, even when gaps is empty" do
      leg = { skills: ["Small Edged", "Twohanded Blunt"], zone_key: "z",
              stance: { policy: :spread, key: "Small Edged" }, min_mana: nil }
      result = overlay.build(leg)

      expect(result).to be_a(UberCombat::LegOverlay::Overlay)
      expect(result.gaps).to eq([])
      expect(result.settings).to be_a(Hash)
    end
  end
end
