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

  def picker(zones, premium = false, province: nil)
    described_class.new(character, FakeZoneTable.new(zones), premium, province: province)
  end

  # Keeps a hunt near its home town instead of sending it somewhere wildly
  # distant that merely fits the rank band.
  describe "the province limit" do
    it "admits any province when none is set" do
      target = zone(min: 100, max: 190, extra: { "province" => "Forfedhdar" })

      expect(picker([target]).admissible?(target, "Small Edged")).to be(true)
    end

    it "admits a zone in the chosen province" do
      target = zone(min: 100, max: 190, extra: { "province" => "Zoluren" })

      expect(picker([target], province: "Zoluren").admissible?(target, "Small Edged")).to be(true)
    end

    it "refuses a zone in another province" do
      target = zone(min: 100, max: 190, extra: { "province" => "Forfedhdar" })

      expect(picker([target], province: "Zoluren").admissible?(target, "Small Edged")).to be(false)
    end

    # Qi'Reshalia is the one name nobody types the same way twice, and a
    # strict compare would silently admit nothing rather than complain.
    it "ignores case and punctuation when comparing province names" do
      target = zone(min: 100, max: 190, extra: { "province" => "Qi'Reshalia" })

      expect(picker([target], province: "qi reshalia").admissible?(target, "Small Edged")).to be(true)
    end

    # Excluding is the safe direction: the setting exists to stay near home,
    # and a zone with no province recorded cannot promise that.
    it "refuses a zone with no province recorded once a limit is set" do
      target = zone(min: 100, max: 190)

      expect(picker([target], province: "Zoluren").admissible?(target, "Small Edged")).to be(false)
    end

    # Reached through build_itinerary rather than by calling the private
    # exclusion_record directly, which is how a caller actually sees it.
    it "names province_excluded when the limit is what emptied the list" do
      target = zone(min: 100, max: 190, extra: { "province" => "Forfedhdar" })
      unplaced = picker([target], province: "Zoluren").build_itinerary.unplaced
      record = unplaced.find { |row| row[:skill] == "Small Edged" }

      expect(record[:reason]).to eq(:province_excluded)
      expect(record[:detail][:zones_after_province]).to eq(0)
    end
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

  # A premium-only zone cannot be travelled to by a non-premium character at
  # all, so admitting one produces a leg that never starts.
  describe "the premium account exclusion" do
    let(:premium_zone) { zone(min: 100, max: 190, extra: { "premium" => true }) }
    let(:open_zone) { zone(min: 100, max: 190, extra: { "premium" => false }) }
    let(:unknown_zone) { zone(min: 100, max: 190) }

    it "refuses a premium zone the skill otherwise fits, for a non-premium character" do
      expect(picker([premium_zone]).admissible?(premium_zone, "Small Edged")).to be(false)
      expect(picker([premium_zone]).premium_locked?(premium_zone)).to be(true)
    end

    it "admits that same zone for a premium character" do
      expect(picker([premium_zone], true).admissible?(premium_zone, "Small Edged")).to be(true)
      expect(picker([premium_zone], true).premium_locked?(premium_zone)).to be(false)
    end

    # Fail open on purpose. Most of a 363-zone table is unknown on the first
    # harvest pass, so excluding unknowns would leave almost nothing to hunt.
    it "admits a zone whose premium status is unknown" do
      expect(picker([unknown_zone]).admissible?(unknown_zone, "Small Edged")).to be(true)
      expect(picker([unknown_zone]).premium_locked?(unknown_zone)).to be(false)
    end

    it "admits a zone known not to be premium, gating nothing" do
      expect(picker([open_zone]).admissible?(open_zone, "Small Edged")).to be(true)
      expect(picker([open_zone]).premium_locked?(open_zone)).to be(false)
    end

    # Defaulting the constructor argument must gate, never unlock: a caller
    # that has not been taught the argument is a non-premium character.
    it "defaults an unspecified account to non-premium" do
      unspecified = described_class.new(character, FakeZoneTable.new([premium_zone]))

      expect(unspecified.admissible?(premium_zone, "Small Edged")).to be(false)
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

    it "drops the premium zones for a non-premium character and keeps them for a premium one" do
      open_zone = zone(key: "open", min: 100, max: 190, extra: { "premium" => false })
      gated = zone(key: "gated", min: 100, max: 190, extra: { "premium" => true })
      unknown = zone(key: "unknown", min: 100, max: 190)

      expect(picker([open_zone, gated, unknown]).admissible_zones_for("Small Edged").map(&:key))
        .to contain_exactly("open", "unknown")
      expect(picker([open_zone, gated, unknown], true).admissible_zones_for("Small Edged").map(&:key))
        .to contain_exactly("open", "gated", "unknown")
    end
  end
end
