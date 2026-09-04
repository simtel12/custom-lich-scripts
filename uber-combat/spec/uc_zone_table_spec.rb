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

  # A zone reachable only by an escort. The key is not a room tag, so
  # hunting-buddy resolves no hunting room from it and exits immediately
  # (hunting-buddy.lic:383-386). Read through the get_data shape for the same
  # reason Zone#premium is: `access` is a NESTED key, so it stays a String in
  # production while the top level does not.
  describe "Zone#escort_access?" do
    def zone_with(entry)
      parsed = { "zones" => { "gated" => { "rank" => { "min" => 10, "max" => 20 } }.merge(entry) } }

      described_class.new(OpenStruct.new(parsed).to_h).zone("gated")
    end

    it "reads true for an escort-only zone" do
      expect(zone_with("access" => "escort").escort_access?).to be(true)
    end

    it "reads false for a zone that can be walked to" do
      expect(zone_with("access" => "plain").escort_access?).to be(false)
    end

    # Absent must not read as escort. That direction excludes a walkable zone
    # for no reason, and every row in the table carries the key today, so
    # nothing but a typo would land here.
    it "reads false when the key is absent entirely" do
      expect(zone_with({}).escort_access?).to be(false)
    end
  end

  # A zone band is the INTERSECTION of its critters' bands, so it already
  # means "the window in which every creature here still teaches". That is
  # only true while every critter HAS a band: an intersection silently ignores
  # a nil, so golden_atiket reads 120-170 from the atik'et alone while the
  # westanuryn's band is nil/nil. A character sent there fights something that
  # teaches nothing, and combat-trainer then DELETES that weapon from
  # weapons_to_train (CT:5821-5833), disarming the character.
  #
  # Built through the get_data shape because `rank`, `min` and `max` on a
  # critter record are all nested and stay Strings in production.
  describe "#critter_bands_known?" do
    def table_with(refs, critters)
      zone = { "rank" => { "min" => 10, "max" => 20 }, "critter_refs" => refs }
      parsed = { "critters" => critters, "zones" => { "mixed" => zone } }

      described_class.new(OpenStruct.new(parsed).to_h)
    end

    def known?(refs, critters)
      table = table_with(refs, critters)

      table.critter_bands_known?(table.zone("mixed"))
    end

    # One creature cannot diverge from itself, so a lone unknown band leaves
    # the zone band exactly as trustworthy as the comment it came from. 5
    # zones are in that state and none of them is at risk.
    it "trusts a single-critter zone even when that critter's band is unknown" do
      expect(known?({ "lone beast" => "Lone_beast" },
                    { "Lone_beast" => { "rank" => { "min" => nil, "max" => nil } } })).to be(true)
    end

    it "trusts a zone whose several critters all carry a closed band" do
      expect(known?({ "one" => "One", "two" => "Two" },
                    { "One" => { "rank" => { "min" => 10, "max" => 20 } },
                      "Two" => { "rank" => { "min" => 15, "max" => 25 } } })).to be(true)
    end

    it "refuses a zone where one of several critters has no lower bound" do
      expect(known?({ "one" => "One", "two" => "Two" },
                    { "One" => { "rank" => { "min" => 10, "max" => 20 } },
                      "Two" => { "rank" => { "min" => nil, "max" => 25 } } })).to be(false)
    end

    it "refuses a zone where one of several critters has no upper bound" do
      expect(known?({ "one" => "One", "two" => "Two" },
                    { "One" => { "rank" => { "min" => 10, "max" => 20 } },
                      "Two" => { "rank" => { "min" => 15, "max" => nil } } })).to be(false)
    end

    # A dangling ref is not a closed band by another name. Nothing is known
    # about a record that is not there, so it has to fail the same way an
    # explicit nil/nil does rather than resolve to nil and be treated as
    # absent from the roster.
    it "refuses a zone whose ref points at a critter record that does not exist" do
      expect(known?({ "one" => "One", "ghost" => "Missing_record" },
                    { "One" => { "rank" => { "min" => 10, "max" => 20 } } })).to be(false)
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
