# frozen_string_literal: true

require "ostruct"

# LegSettings is the one place that pins the get_settings / get_data key
# shape down. Every example here feeds it the shape LICH ACTUALLY HANDS
# OVER, reproduced hop by hop from setup_files.rb and settings_transformer.rb
# -- never YAML.load_file's shape, which is what the file has on disk and NOT
# what production code ever sees. This is the direct regression test for the
# bug that emptied UberCombat::ZoneTable in production while every test using
# YAML.load_file passed (see lib/uc_leg_settings.rb's file comment).
RSpec.describe UberCombat::LegSettings do
  # Hop 1: SetupFiles#safe_load_yaml, once per loaded profile file
  #   (setup_files.rb:63-65): OpenStruct.new(YAML.unsafe_load_file(fp)).to_h
  #   -- symbolises that file's top-level keys, leaves every nested value
  #   exactly as YAML parsed it.
  # Merge: SetupFiles#get_settings's file-reduce (setup_files.rb:96-104) is a
  #   plain Hash#merge -- folding one file's Hash here stands in for that,
  #   since #merge never touches a value's own shape.
  # Hop 2: SettingsTransformer.transform (settings_transformer.rb:29):
  #   OpenStruct.new(original_settings). uc_weapons and uc_spells are absent
  #   from every key list in settings_config.rb::TRANSFORM_CONFIG, so no
  #   later enrichment phase touches them.
  def get_settings_shape(profile_hash)
    hop1 = OpenStruct.new(profile_hash).to_h
    OpenStruct.new(hop1)
  end

  # get_data's own two hops: SetupFiles#safe_load_yaml (setup_files.rb:63-65)
  # then SetupFiles#transform_data (setup_files.rb ~298-300):
  #   data = OpenStruct.new(original_data)
  def get_data_shape(data_hash)
    hop1 = OpenStruct.new(data_hash).to_h
    OpenStruct.new(hop1)
  end

  # Everything now lives one level down, under uc_settings:. That level is
  # where the shape hazard actually bites: OpenStruct symbolises only the key
  # it wraps, so uc_settings itself arrives as a Symbol accessor while its own
  # keys stay Strings.
  describe ".uc_settings" do
    it "arrives as a Hash whose own keys are Strings, never Symbols" do
      settings = get_settings_shape(
        "uc_settings" => { "weapons" => { "Brawling" => "" }, "spells" => [] }
      )

      result = described_class.uc_settings(settings)

      expect(result.keys).to contain_exactly("weapons", "spells")
      expect(result[:weapons]).to be_nil
    end

    it "returns an empty Hash, not nil, when the profile has no uc_settings: key" do
      expect(described_class.uc_settings(get_settings_shape("hometown" => "Crossing"))).to eq({})
    end
  end

  describe ".weapons" do
    it "keeps String keys through the real get_settings pipeline" do
      settings = get_settings_shape(
        "uc_settings" => { "weapons" => { "Targeted Magic" => "steel scimitar", "Brawling" => "" } }
      )

      result = described_class.weapons(settings)

      expect(result).to eq("Targeted Magic" => "steel scimitar", "Brawling" => "")
      expect(result.key?("Targeted Magic")).to be true
      expect(result.key?(:"Targeted Magic")).to be false
    end

    it "keeps an empty-string bare-hands value, never drops it" do
      settings = get_settings_shape("uc_settings" => { "weapons" => { "Brawling" => "" } })

      expect(described_class.weapons(settings).key?("Brawling")).to be true
    end

    it "returns an empty Hash, not nil, when there is no catalogue" do
      expect(described_class.weapons(get_settings_shape("hometown" => "Crossing"))).to eq({})
      expect(described_class.weapons(get_settings_shape("uc_settings" => {}))).to eq({})
    end
  end

  describe ".spells" do
    it "keeps String keys on each entry through the real get_settings pipeline" do
      settings = get_settings_shape(
        "uc_settings" => { "spells" => [{ "skill" => "Targeted Magic", "name" => "Fists of Faenella" }] }
      )

      result = described_class.spells(settings)

      expect(result).to eq([{ "skill" => "Targeted Magic", "name" => "Fists of Faenella" }])
      expect(result.first.key?("skill")).to be true
      expect(result.first.key?(:skill)).to be false
    end

    # LegOverlay#spell_candidates keys this exact nil off "no catalogue at
    # all", distinct from an empty Array (lib/uc_leg_settings.rb comment).
    it "passes nil through as nil, not []" do
      expect(described_class.spells(get_settings_shape("hometown" => "Crossing"))).to be_nil
      expect(described_class.spells(get_settings_shape("uc_settings" => {}))).to be_nil
    end
  end

  # The account tier that gates premium-only hunting zones. Read through the
  # same real pipeline shape as everything else here: the value sits one level
  # down under uc_settings, where the keys are still Strings.
  describe ".in_province_only" do
    it "reads the province name" do
      settings = get_settings_shape("uc_settings" => { "in_province_only" => "Zoluren" })

      expect(described_class.in_province_only(settings)).to eq("Zoluren")
    end

    it "reads an absent setting as no restriction" do
      settings = get_settings_shape("uc_settings" => {})

      expect(described_class.in_province_only(settings)).to be_nil
    end

    it "reads an absent uc_settings block as no restriction" do
      expect(described_class.in_province_only(get_settings_shape({}))).to be_nil
    end

    # A blank value is somebody clearing the setting, not naming a province
    # that no zone can match. Treating it as a real name would admit nothing
    # at all, which looks exactly like a character with nowhere to hunt.
    it "reads a blank value as no restriction rather than an impossible one" do
      settings = get_settings_shape("uc_settings" => { "in_province_only" => "   " })

      expect(described_class.in_province_only(settings)).to be_nil
    end

    it "trims surrounding whitespace" do
      settings = get_settings_shape("uc_settings" => { "in_province_only" => " Ilithi " })

      expect(described_class.in_province_only(settings)).to eq("Ilithi")
    end

    # A YAML author who writes `in_province_only: true` has said something
    # meaningless, and a non-string must not be coerced into a name.
    it "ignores a non-string value" do
      settings = get_settings_shape("uc_settings" => { "in_province_only" => true })

      expect(described_class.in_province_only(settings)).to be_nil
    end
  end

  describe ".premium" do
    it "reads a declared premium account as true" do
      settings = get_settings_shape("uc_settings" => { "premium" => true })

      expect(described_class.premium(settings)).to be(true)
    end

    it "reads a declared non-premium account as false" do
      settings = get_settings_shape("uc_settings" => { "premium" => false })

      expect(described_class.premium(settings)).to be(false)
    end

    # The safe default: under-select zones rather than route a character
    # somewhere they cannot travel (lib/uc_leg_settings.rb).
    it "defaults to false when the profile has no uc_settings: key at all" do
      expect(described_class.premium(get_settings_shape("hometown" => "Crossing"))).to be(false)
    end

    it "defaults to false when uc_settings carries no premium: key" do
      settings = get_settings_shape("uc_settings" => { "weapons" => { "Brawling" => "" } })

      expect(described_class.premium(settings)).to be(false)
    end

    it "defaults to false for an explicit premium: null" do
      expect(described_class.premium(get_settings_shape("uc_settings" => { "premium" => nil }))).to be(false)
    end

    # A hand-edited "yes" is a String, not the YAML boolean. It must not
    # unlock the premium table off a typo.
    it "treats a non-boolean value as non-premium" do
      expect(described_class.premium(get_settings_shape("uc_settings" => { "premium" => "yes" }))).to be(false)
    end

    # The nested level keeps String keys, so a Symbol-keyed value is not the
    # setting -- and reading it as one would flip the default the wrong way.
    it "does not read a Symbol-keyed premium value" do
      settings = get_settings_shape("uc_settings" => { premium: true })

      expect(described_class.premium(settings)).to be(false)
    end
  end

  # A half-migrated profile fails silently and its symptom -- every skill
  # reporting :no_weapon_entry -- is indistinguishable from a character who
  # simply has no catalogue yet.
  describe ".legacy_keys" do
    it "names the old top-level keys still present" do
      settings = get_settings_shape("uc_weapons" => { "Brawling" => "" }, "uc_spells" => [])

      expect(described_class.legacy_keys(settings)).to contain_exactly(:uc_weapons, :uc_spells)
    end

    it "is empty for a fully migrated profile" do
      settings = get_settings_shape("uc_settings" => { "weapons" => { "Brawling" => "" } })

      expect(described_class.legacy_keys(settings)).to be_empty
    end
  end

  describe ".known_spell_names" do
    it "reads the name list from spell_data, not the data file's own top level" do
      data = get_data_shape(
        "spell_data" => {
          "Fists of Faenella" => { "skill" => "Targeted Magic", "abbrev" => "FF" },
          "Malediction"       => { "skill" => "Debilitation", "abbrev" => "malediction" }
        }
      )

      expect(described_class.known_spell_names(data)).to contain_exactly("Fists of Faenella", "Malediction")
    end

    it "returns an empty Array, not nil, when spell_data is absent" do
      data = get_data_shape("charge_messages" => {})

      expect(described_class.known_spell_names(data)).to eq([])
    end
  end
end
