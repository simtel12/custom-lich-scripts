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

  describe ".uc_weapons" do
    it "keeps String keys through the real get_settings pipeline" do
      settings = get_settings_shape(
        "uc_weapons" => { "Targeted Magic" => "steel scimitar", "Brawling" => "" }
      )

      result = described_class.uc_weapons(settings)

      expect(result).to eq("Targeted Magic" => "steel scimitar", "Brawling" => "")
      expect(result.key?("Targeted Magic")).to be true
      expect(result.key?(:"Targeted Magic")).to be false
    end

    it "keeps an empty-string bare-hands value, never drops it" do
      settings = get_settings_shape("uc_weapons" => { "Brawling" => "" })

      expect(described_class.uc_weapons(settings).key?("Brawling")).to be true
    end

    it "returns an empty Hash, not nil, when the profile has no uc_weapons: key" do
      settings = get_settings_shape("hometown" => "Crossing")

      expect(described_class.uc_weapons(settings)).to eq({})
    end
  end

  describe ".uc_spells" do
    it "keeps String keys on each entry through the real get_settings pipeline" do
      settings = get_settings_shape(
        "uc_spells" => [{ "skill" => "Targeted Magic", "name" => "Fists of Faenella" }]
      )

      result = described_class.uc_spells(settings)

      expect(result).to eq([{ "skill" => "Targeted Magic", "name" => "Fists of Faenella" }])
      expect(result.first.key?("skill")).to be true
      expect(result.first.key?(:skill)).to be false
    end

    # LegOverlay#spell_candidates keys this exact nil off "no catalogue at
    # all", distinct from an empty Array (lib/uc_leg_settings.rb comment).
    it "passes nil through as nil, not []" do
      settings = get_settings_shape("hometown" => "Crossing")

      expect(described_class.uc_spells(settings)).to be_nil
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
