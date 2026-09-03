# frozen_string_literal: true

require "ostruct"

# The zone table is the loader for base-uc-zones.yaml.
# Spec: notes/uber-combat/33-zone-picker-spec.md section 1.5 and 1.6.
RSpec.describe UberCombat::ZoneTable do
  subject(:table) { described_class.load(described_class::DEFAULT_PATH) }

  describe "loading the committed data file" do
    it "loads every zone" do
      expect(table.zones.size).to eq(363)
    end

    it "loads every critter record" do
      expect(table.critters.size).to eq(306)
    end

    it "exposes a zone band as numbers" do
      zone = table.zone("grave_worms")

      expect([zone.rank_min, zone.rank_max]).to eq([90, 130])
    end

    it "reports the zone key on the zone itself" do
      expect(table.zone("grave_worms").key).to eq("grave_worms")
    end

    it "counts the zones excluded by low rank confidence" do
      expect(table.zones.count(&:low_confidence?)).to eq(35)
    end

    it "counts the zones with no band at all" do
      expect(table.zones.count { |zone| zone.rank_min.nil? && zone.rank_max.nil? }).to eq(26)
    end

    it "counts the zones with an open-ended band" do
      open_ended = table.zones.select { |zone| !zone.rank_min.nil? && zone.rank_max.nil? }

      expect(open_ended.map(&:key)).to contain_exactly("shadow_master", "spiny_bloodfish")
    end

    it "finds no zone opted in to low-confidence auto-selection" do
      expect(table.zones.count(&:allow_low_confidence_auto_select?)).to eq(0)
    end
  end

  # ZoneTable.load reads the YAML directly, so every test above sees STRING
  # keys. Production does not: get_data returns an OpenStruct
  # (setup_files.rb:295-298), and OpenStruct#to_h symbolises the TOP LEVEL
  # only, leaving the nested keys as strings. That mismatch silently emptied
  # the table for a real character, and no test caught it because
  # from_game_data was the one method with no coverage.
  describe "the key shape get_data actually returns" do
    let(:game_shape) do
      OpenStruct.new(YAML.load_file(described_class::DEFAULT_PATH, aliases: true)).to_h
    end

    it "loads every zone from a hash with symbol top-level keys" do
      expect(described_class.new(game_shape).zones.size).to eq(363)
    end

    it "loads every critter record from that same hash" do
      expect(described_class.new(game_shape).critters.size).to eq(306)
    end

    it "still reads a band through the nested string keys" do
      zone = described_class.new(game_shape).zone("grave_worms")

      expect([zone.rank_min, zone.rank_max]).to eq([90, 130])
    end
  end

  # premium: is three-state -- true, false, and nil for "nobody has checked
  # yet". Built through the get_data shape rather than through .load, because
  # the reader has to survive the exact hazard described just above: the key
  # is NESTED, so it stays a String in production while the top level does
  # not. A reader spelled data[:premium] passes any test that only asserts
  # nil-means-unknown, and fails open for the whole table in game.
  describe "Zone#premium" do
    def zone_with(entry)
      parsed = { "zones" => { "gated" => { "rank" => { "min" => 10, "max" => 20 } }.merge(entry) } }

      described_class.new(OpenStruct.new(parsed).to_h).zone("gated")
    end

    it "reads true for a zone known to be premium-only" do
      expect(zone_with("premium" => true).premium).to be(true)
    end

    it "reads false for a zone known to be open to every account" do
      expect(zone_with("premium" => false).premium).to be(false)
    end

    it "reads nil for an explicit premium: null" do
      expect(zone_with("premium" => nil).premium).to be_nil
    end

    it "reads nil when the key is absent entirely" do
      expect(zone_with({}).premium).to be_nil
    end

    # The distinction the picker's fail-open rule is built on. Collapsing nil
    # to false here would make an unchecked zone indistinguishable from a
    # checked one and retire the unresolved report with it.
    it "never collapses an unknown into a known false" do
      expect(zone_with({}).premium_unknown?).to be(true)
      expect(zone_with("premium" => nil).premium_unknown?).to be(true)
      expect(zone_with("premium" => false).premium_unknown?).to be(false)
      expect(zone_with("premium" => true).premium_unknown?).to be(false)
    end
  end

  describe ".from_game_data" do
    it "refuses an empty table instead of reporting zero candidates" do
      allow(described_class).to receive(:fetch_game_data).and_return({})

      expect { described_class.from_game_data }
        .to raise_error(described_class::EmptyTable, /base-uc-zones\.yaml/)
    end

    it "builds the table when the game data arrives" do
      allow(described_class).to receive(:fetch_game_data)
        .and_return(OpenStruct.new(YAML.load_file(described_class::DEFAULT_PATH, aliases: true)).to_h)

      expect(described_class.from_game_data.zones.size).to eq(363)
    end
  end

  describe "#critter_for" do
    # 13 in-game nouns map to 2 or 3 records with different bands. The zone
    # disambiguates through critter_refs. A bare noun lookup is wrong.
    it "resolves a shared noun to the tier the zone actually holds" do
      leucro1 = table.critter_for(table.zone("leucro1"), "giant black leucro")

      expect([leucro1["slug"], leucro1["rank"]["min"], leucro1["rank"]["max"]])
        .to eq(["Giant_black_leucro", 160, 215])
    end

    it "resolves the same noun to a different tier in a different zone" do
      mill = table.critter_for(table.zone("black_leucro_mill"), "giant black leucro")

      expect([mill["slug"], mill["rank"]["min"], mill["rank"]["max"]])
        .to eq(["Giant_black_leucro_(2)", 180, 230])
    end

    it "returns nil for a noun the zone roster does not carry" do
      expect(table.critter_for(table.zone("leucro1"), "grave worm")).to be_nil
    end
  end
end
