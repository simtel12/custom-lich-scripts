# frozen_string_literal: true

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
