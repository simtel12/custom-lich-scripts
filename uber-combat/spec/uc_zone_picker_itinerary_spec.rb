# frozen_string_literal: true

# Test plan cases 6, 7, 8 and 13 (33-zone-picker-spec.md section 7).
RSpec.describe UberCombat::ZonePicker, "the itinerary builder" do
  # Drazoken's real weapon vector (fixtures/drazoken-exp-2026-08-14.md:122).
  let(:weapon_vector) do
    {
      "Small Edged"     => 148,
      "Brawling"        => 135,
      "Bow"             => 120,
      "Heavy Thrown"    => 100,
      "Large Blunt"     => 92,
      "Crossbow"        => 72,
      "Polearms"        => 47,
      "Light Thrown"    => 47,
      "Twohanded Blunt" => 44,
      "Offhand Weapon"  => 40,
      "Small Blunt"     => 36,
      "Slings"          => 32
    }
  end

  let(:open_zone) { UberCombat::Zone.new("anywhere", { "rank" => { "min" => 0, "max" => 1000 } }) }

  def picker_with(zones, skills = {}, premium = false)
    character = UberCombat::Character.new(
      FakeSkills.new({ "Evasion" => 200, "Shield Usage" => 200, "Parry Ability" => 200 }.merge(skills))
    )
    described_class.new(character, FakeZoneTable.new(zones), premium)
  end

  describe "#build_legs, width-bounded clustering" do
    # Every skill can hunt anywhere, so this isolates the width rule itself --
    # and max_skills is nil for the same reason. MAX_SKILLS_PER_LEG would split
    # these clusters before the width rule finished expressing itself, so every
    # example below would really be measuring the cap. The cap has its own
    # block, over this same fixture, further down.
    def leg_skills(width, max_skills = nil)
      zones_by_skill = weapon_vector.keys.to_h { |skill| [skill, [open_zone]] }
      picker_with([open_zone])
        .build_legs(weapon_vector, zones_by_skill, width, max_skills)
        .map { |leg| leg[:skills] }
    end

    it "reproduces the fixture's three legs at the default width" do
      expect(leg_skills(40)).to eq(
        [
          ["Small Edged", "Brawling", "Bow"],
          ["Heavy Thrown", "Large Blunt", "Crossbow"],
          ["Polearms", "Light Thrown", "Twohanded Blunt", "Offhand Weapon", "Small Blunt", "Slings"]
        ]
      )
    end

    # CORRECTION to fixtures/drazoken-exp-2026-08-14.md:127 and to the test plan
    # at 33-zone-picker-spec.md section 7 case 6. Both claim the legs are
    # identical for every width in 30 to 50. Measured against this
    # implementation, the true stable band is 28 to 47. At width 48 the leader
    # gap of 148 minus 100 closes and Heavy Thrown joins leg 1.
    it "gives the same legs at every width in the measured stable band" do
      (28..47).each do |width|
        expect(leg_skills(width)).to eq(leg_skills(40))
      end
    end

    it "changes the leg membership at the top of that band" do
      expect(leg_skills(48)).not_to eq(leg_skills(40))
      expect(leg_skills(48).map(&:size)).to eq([4, 5, 3])
    end

    it "keeps the leg count at three well past the stable band" do
      (28..55).each do |width|
        expect(leg_skills(width).size).to eq(3)
      end
    end

    # The production cap, over the same 12-weapon fixture. Without it the third
    # leg carries SIX skills, so a 30-minute stint gives each about five
    # minutes -- the starvation the limit exists to stop (user, 2026-09-05).
    it "splits an oversized cluster at MAX_SKILLS_PER_LEG" do
      capped = leg_skills(40, described_class::MAX_SKILLS_PER_LEG)

      expect(capped.map(&:size)).to all(be <= described_class::MAX_SKILLS_PER_LEG)
    end

    # Splitting must never DROP a skill. Clustering is an optimisation, and the
    # oversized cluster's tail becomes the next leg rather than going untrained.
    it "keeps every skill when it splits a cluster" do
      capped = leg_skills(40, described_class::MAX_SKILLS_PER_LEG)

      expect(capped.flatten.sort).to eq(leg_skills(40).flatten.sort)
    end

    # The split follows rank order, so the tail of an oversized cluster becomes
    # the next leg's leader rather than being scattered.
    it "splits the six-skill leg into two, in rank order" do
      uncapped = leg_skills(40)
      capped = leg_skills(40, described_class::MAX_SKILLS_PER_LEG)

      expect(uncapped.last.size).to eq(6)
      expect(capped.last(2)).to eq([uncapped.last.first(3), uncapped.last.last(3)])
    end

    it "keeps the default width inside the stable band" do
      expect(described_class::LEG_WIDTH_RANKS).to be_between(28, 47)
    end

    it "gives a skill its own leg when no other skill is within the width" do
      ranks = { "Small Edged" => 148, "Slings" => 32 }
      zones_by_skill = ranks.keys.to_h { |skill| [skill, [open_zone]] }

      legs = picker_with([open_zone]).build_legs(ranks, zones_by_skill, 40)

      expect(legs.map { |leg| leg[:skills] }).to eq([["Small Edged"], ["Slings"]])
    end

    it "refuses to cluster two skills that share no admissible zone" do
      near = UberCombat::Zone.new("near", { "rank" => { "min" => 100, "max" => 160 } })
      far = UberCombat::Zone.new("far", { "rank" => { "min" => 100, "max" => 160 } })
      ranks = { "Small Edged" => 148, "Brawling" => 135 }
      zones_by_skill = { "Small Edged" => [near], "Brawling" => [far] }

      legs = picker_with([near, far]).build_legs(ranks, zones_by_skill, 40)

      expect(legs.map { |leg| leg[:skills] }).to eq([["Small Edged"], ["Brawling"]])
    end
  end

  # REGRESSION GUARD. Gap-chaining must never be reintroduced. This helper is
  # test-only code and must never appear in lib/.
  describe "the gap-chaining failure mode this design rejects" do
    def gap_chained_legs(threshold)
      ordered = weapon_vector.keys.sort_by { |skill| -weapon_vector[skill] }
      legs = [[ordered.first]]
      ordered.each_cons(2) do |previous, current|
        if weapon_vector[previous] - weapon_vector[current] > threshold
          legs << [current]
        else
          legs.last << current
        end
      end
      legs
    end

    it "collapses the whole weapon vector into one leg at any threshold of 25 or more" do
      expect(gap_chained_legs(25).size).to eq(1)
      expect(gap_chained_legs(40).size).to eq(1)
    end

    it "is why width-bounded clustering is the algorithm of record" do
      expect(gap_chained_legs(25).size).to eq(1)
      expect(leg_count_at_default_width).to eq(3)
    end

    # max_skills nil for the same reason the width block lifts it: the contrast
    # being drawn is gap-chaining against WIDTH-bounded clustering. Leaving the
    # cap on would add its own splits to the count and blur which rule produced
    # them.
    def leg_count_at_default_width
      zones_by_skill = weapon_vector.keys.to_h { |skill| [skill, [open_zone]] }
      picker_with([open_zone]).build_legs(weapon_vector, zones_by_skill, 40, nil).size
    end
  end

  describe "#assign_debilitation" do
    it "attaches Debilitation to a leg whose zone band admits it" do
      zone = UberCombat::Zone.new("mid", { "rank" => { "min" => 120, "max" => 148 } })
      legs = [{ skills: ["Small Edged"], zone_candidates: [zone] }]

      carrier = picker_with([zone]).assign_debilitation(legs, 138)

      expect(carrier[:skills]).to eq(["Small Edged", "Debilitation"])
    end

    it "leaves Debilitation untrained when no leg's zone admits it" do
      zone = UberCombat::Zone.new("high", { "rank" => { "min" => 200, "max" => 250 } })
      legs = [{ skills: ["Small Edged"], zone_candidates: [zone] }]

      carrier = picker_with([zone]).assign_debilitation(legs, 138)

      expect(carrier).to be_nil
      expect(legs.first[:skills]).to eq(["Small Edged"])
    end

    it "never gives Debilitation a leg of its own" do
      zone = UberCombat::Zone.new("high", { "rank" => { "min" => 200, "max" => 250 } })
      legs = [{ skills: ["Small Edged"], zone_candidates: [zone] }]

      picker_with([zone]).assign_debilitation(legs, 138)

      expect(legs.size).to eq(1)
    end
  end

  describe "#build_itinerary" do
    let(:zones) do
      [
        UberCombat::Zone.new("tight", { "rank" => { "min" => 140, "max" => 150 } }),
        UberCombat::Zone.new("wide", { "rank" => { "min" => 100, "max" => 200 } })
      ]
    end

    it "picks the narrowest band when several zones admit the same leg" do
      itinerary = picker_with(zones, "Small Edged" => 148).build_itinerary

      expect(itinerary.legs.map { |leg| leg[:zone_key] }).to eq(["tight"])
    end

    it "orders the legs by descending rank" do
      itinerary = picker_with(zones, "Small Edged" => 148, "Bow" => 105).build_itinerary

      expect(itinerary.legs.map { |leg| leg[:skills].first }).to eq(["Small Edged", "Bow"])
    end

    it "records the stance policy and the weapon key the policy is written under" do
      itinerary = picker_with(zones, "Small Edged" => 148).build_itinerary

      expect(itinerary.legs.first[:stance]).to eq(policy: :spread, key: "Small Edged")
    end

    it "keys a magic-led leg's stance on the highest weapon skill" do
      itinerary = picker_with(zones, "Targeted Magic" => 148, "Bow" => 30).build_itinerary

      expect(itinerary.legs.first[:stance]).to eq(policy: :spread, key: "Bow")
    end

    it "records the concentrated policy when the zone floor beats the spread pole" do
      # Defences of 200 give a spread pole of 180, so a floor of 190 forces
      # the concentrated policy.
      steep = UberCombat::Zone.new("steep", { "rank" => { "min" => 190, "max" => 210 } })
      itinerary = picker_with([steep], "Small Edged" => 195).build_itinerary

      expect(itinerary.legs.first[:stance]).to eq(policy: :concentrated, key: "Small Edged")
    end

    it "reports a skill whose rank no zone band covers" do
      itinerary = picker_with(zones, "Small Edged" => 900).build_itinerary

      expect(itinerary.unplaced).to contain_exactly(
        hash_including(skill: "Small Edged", reason: :no_band_in_range)
      )
    end

    it "reports a skill blocked only by low rank confidence" do
      low = UberCombat::Zone.new("low_conf",
                                 { "rank" => { "min" => 140, "max" => 150 }, "rank_confidence" => "low" })

      itinerary = picker_with([low], "Small Edged" => 148).build_itinerary

      expect(itinerary.unplaced).to contain_exactly(
        hash_including(skill: "Small Edged", reason: :confidence_excluded)
      )
    end

    it "reports a skill blocked only by the defensive ceiling" do
      character = UberCombat::Character.new(
        FakeSkills.new("Evasion" => 10, "Shield Usage" => 10, "Parry Ability" => 10,
                       "Small Edged" => 148)
      )
      picker = described_class.new(character, FakeZoneTable.new(zones))

      expect(picker.build_itinerary.unplaced).to contain_exactly(
        hash_including(skill: "Small Edged", reason: :defense_ceiling)
      )
    end

    it "returns no legs at all when the defensive metric admits nothing" do
      character = UberCombat::Character.new(
        FakeSkills.new("Evasion" => 10, "Shield Usage" => 10, "Parry Ability" => 10,
                       "Small Edged" => 148, "Bow" => 105)
      )
      picker = described_class.new(character, FakeZoneTable.new(zones))
      itinerary = picker.build_itinerary

      expect(itinerary.legs).to be_empty
      expect(itinerary.unplaced.map { |row| row[:skill] }).to contain_exactly("Small Edged", "Bow")
    end

    it "does not report a skill the character has never trained" do
      itinerary = picker_with(zones, "Small Edged" => 148).build_itinerary

      expect(itinerary.unplaced.map { |row| row[:skill] }).not_to include("Slings")
    end
  end

  # Both directions of the premium gate, at the itinerary level: the hard
  # exclusion has to name itself in the same reason channel the other
  # exclusions use, and the fail-open admission has to name itself too.
  describe "#build_itinerary and the premium gate" do
    def band(extra = {})
      { "rank" => { "min" => 140, "max" => 150 } }.merge(extra)
    end

    let(:gated) { UberCombat::Zone.new("gated", band("premium" => true)) }
    let(:open_zone) { UberCombat::Zone.new("open", band("premium" => false)) }
    let(:unknown) { UberCombat::Zone.new("unknown", band) }

    it "reports a skill blocked only by the premium gate" do
      itinerary = picker_with([gated], "Small Edged" => 148).build_itinerary

      expect(itinerary.legs).to be_empty
      expect(itinerary.unplaced).to contain_exactly(
        hash_including(skill: "Small Edged", reason: :premium_excluded)
      )
    end

    # The reason names the first stage that emptied the set, so a skill whose
    # only zone is BOTH low-confidence and premium reads as the confidence
    # problem -- one actionable cause per record.
    it "keeps the confidence exclusion ahead of the premium one" do
      both = UberCombat::Zone.new("both", band("rank_confidence" => "low", "premium" => true))

      itinerary = picker_with([both], "Small Edged" => 148).build_itinerary

      expect(itinerary.unplaced).to contain_exactly(
        hash_including(skill: "Small Edged", reason: :confidence_excluded)
      )
    end

    it "gives the same zone to a premium character with no exclusion at all" do
      itinerary = picker_with([gated], { "Small Edged" => 148 }, true).build_itinerary

      expect(itinerary.legs.map { |leg| leg[:zone_key] }).to eq(["gated"])
      expect(itinerary.unplaced).to be_empty
    end

    # Fail open, then say so. The admission is deliberate; the report is what
    # turns the unknown into a known one on the next harvest pass.
    it "admits a zone of unknown premium status and reports it as unresolved" do
      itinerary = picker_with([unknown], "Small Edged" => 148).build_itinerary

      expect(itinerary.legs.map { |leg| leg[:zone_key] }).to eq(["unknown"])
      expect(itinerary.unresolved_premium).to contain_exactly(
        hash_including(zone_key: "unknown", reason: :premium_unknown,
                       detail: { skills: ["Small Edged"] })
      )
    end

    it "stays silent about a zone known not to be premium" do
      itinerary = picker_with([open_zone], "Small Edged" => 148).build_itinerary

      expect(itinerary.legs.map { |leg| leg[:zone_key] }).to eq(["open"])
      expect(itinerary.unresolved_premium).to be_empty
    end

    # A premium account hides the consequence of an unknown, not the missing
    # datum. The harvest still wants it.
    it "reports an unresolved zone for a premium character too" do
      itinerary = picker_with([unknown], { "Small Edged" => 148 }, true).build_itinerary

      expect(itinerary.unresolved_premium).to contain_exactly(
        hash_including(zone_key: "unknown", reason: :premium_unknown)
      )
    end

    # The report is scoped to the zones the itinerary will actually travel to.
    # An unknown zone nothing is routed to is a data statistic, not a hunt
    # about to fail.
    it "reports only the unknown zones the itinerary actually selected" do
      elsewhere = UberCombat::Zone.new("elsewhere", { "rank" => { "min" => 300, "max" => 400 } })

      itinerary = picker_with([open_zone, elsewhere], "Small Edged" => 148).build_itinerary

      expect(itinerary.legs.map { |leg| leg[:zone_key] }).to eq(["open"])
      expect(itinerary.unresolved_premium).to be_empty
    end
  end
end
