# frozen_string_literal: true

# Test plan cases 4 and 5 (33-zone-picker-spec.md section 7).
RSpec.describe UberCombat::ZonePicker, "admissibility" do
  # Defences of 200/200/200 give a spread pole of 180 and a concentrated pole
  # of 200. Round numbers keep the boundary cases readable.
  let(:character) do
    UberCombat::Character.new(
      FakeSkills.new("Evasion" => 200, "Shield Usage" => 200, "Parry Ability" => 200,
                     "Small Edged" => 190, "Bow" => 210)
    )
  end

  def zone(attributes)
    key = attributes.delete(:key) || "test_zone"
    UberCombat::Zone.new(key, { "rank" => { "min" => attributes[:min], "max" => attributes[:max] } }
      .merge(attributes[:extra] || {}))
  end

  def picker(zones)
    described_class.new(character, FakeZoneTable.new(zones))
  end

  describe "the band test" do
    it "admits a skill standing exactly on the hard upper bound" do
      target = zone(min: 100, max: 190)

      expect(picker([target]).admissible?(target, "Small Edged")).to be(true)
    end

    it "refuses a skill one rank above the hard upper bound" do
      target = zone(min: 100, max: 189)

      expect(picker([target]).admissible?(target, "Small Edged")).to be(false)
    end

    it "refuses a skill below the lower bound" do
      target = zone(min: 191, max: 250)

      expect(picker([target]).admissible?(target, "Small Edged")).to be(false)
    end

    it "refuses a zone with no band at all" do
      target = zone(min: nil, max: nil)

      expect(picker([target]).admissible?(target, "Small Edged")).to be(false)
    end

    it "refuses a zone with an open-ended band" do
      target = zone(min: 100, max: nil)

      expect(picker([target]).admissible?(target, "Small Edged")).to be(false)
    end
  end

  describe "the survivability test" do
    it "admits at spread stance when the spread pole exactly meets the lower bound" do
      target = zone(min: 180, max: 250)

      expect(picker([target]).stance_for(target)).to eq(:spread)
    end

    it "escalates to concentrated stance when the spread pole falls one below" do
      target = zone(min: 181, max: 250)

      expect(picker([target]).stance_for(target)).to eq(:concentrated)
    end

    it "refuses the zone when even the concentrated pole falls short" do
      target = zone(min: 201, max: 250)

      expect(picker([target]).stance_for(target)).to be_nil
      expect(picker([target]).admissible?(target, "Bow")).to be(false)
    end

    it "never treats the defensive metric as a floor on an easy zone" do
      target = zone(min: 100, max: 190)

      expect(picker([target]).admissible?(target, "Small Edged")).to be(true)
    end
  end

  describe "A3, the low rank confidence exclusion" do
    it "refuses a low confidence zone the skill otherwise fits" do
      target = zone(min: 100, max: 190, extra: { "rank_confidence" => "low" })

      expect(picker([target]).admissible?(target, "Small Edged")).to be(false)
    end

    it "re-admits a closed band low confidence zone that opts in" do
      target = zone(min: 100, max: 190,
                    extra: { "rank_confidence" => "low", "allow_low_confidence_auto_select" => true })

      expect(picker([target]).admissible?(target, "Small Edged")).to be(true)
    end

    it "still refuses an open-ended low confidence zone that opts in" do
      target = zone(min: 100, max: nil,
                    extra: { "rank_confidence" => "low", "allow_low_confidence_auto_select" => true })

      expect(picker([target]).admissible?(target, "Small Edged")).to be(false)
    end
  end

  describe "#admissible_zones_for" do
    it "returns only the zones that pass every test" do
      good = zone(key: "good", min: 100, max: 190)
      too_high = zone(key: "too_high", min: 100, max: 189)
      unsurvivable = zone(key: "unsurvivable", min: 201, max: 250)

      result = picker([good, too_high, unsurvivable]).admissible_zones_for("Small Edged")

      expect(result.map(&:key)).to eq(["good"])
    end
  end
end
