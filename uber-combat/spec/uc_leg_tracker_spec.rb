# frozen_string_literal: true

# Wave 7 packet 1. Leg advancement (33-zone-picker-spec.md section 3).
#
# The tracker owns no cadence. The caller decides when a tick happens and when a
# fight ends, so the tracker stays a pure function of live character state plus
# its own counters. It needs no game runtime.
RSpec.describe UberCombat::LegTracker do
  # The hashes are held by reference, so a test mutates them to move a rank or a
  # mindstate between samples. That is how the character advances mid-leg.
  def tracker_for(ranks, mindstates, zone_band, skills, gain_check: 3)
    @ranks = { "Evasion" => 200, "Shield Usage" => 200, "Parry Ability" => 200 }.merge(ranks)
    @mindstates = mindstates
    character = UberCombat::Character.new(FakeSkills.new(@ranks, {}, @mindstates))
    zone = UberCombat::Zone.new("test_zone", { "rank" => { "min" => zone_band[0], "max" => zone_band[1] } })
    described_class.new(character, zone: zone, skills: skills, gain_check: gain_check)
  end

  describe "the hard exit" do
    it "advances the leg when the leading skill passes the zone's upper bound" do
      tracker = tracker_for({ "Small Edged" => 148 }, {}, [100, 150], ["Small Edged"])
      @ranks["Small Edged"] = 151

      verdict = tracker.observe_tick

      expect(verdict.status).to eq(:advance)
      expect(verdict.reason).to eq(:rank_max_exceeded)
      expect(verdict.detail).to eq(skill: "Small Edged", rank: 151.0, rank_max: 150)
    end

    it "keeps the leg while the leading skill sits exactly on the upper bound" do
      tracker = tracker_for({ "Small Edged" => 150 }, {}, [100, 150], ["Small Edged"])

      expect(tracker.observe_tick.status).to eq(:continue)
    end

    it "leads on the highest-ranked killing skill in the leg" do
      tracker = tracker_for({ "Small Edged" => 148, "Bow" => 120 }, {}, [100, 130], ["Small Edged", "Bow"])

      expect(tracker.observe_tick.reason).to eq(:rank_max_exceeded)
    end

    it "never leads on Debilitation, which cannot finish a fight" do
      tracker = tracker_for({ "Bow" => 120, "Debilitation" => 155 }, {}, [100, 150],
                            ["Bow", "Debilitation"])

      expect(tracker.observe_tick.status).to eq(:continue)
    end
  end

  describe "the mindlock backstop" do
    it "advances the leg once every skill on it is mindlocked" do
      tracker = tracker_for({ "Bow" => 120, "Debilitation" => 130 },
                            { "Bow" => 34, "Debilitation" => 34 }, [100, 150],
                            ["Bow", "Debilitation"])

      expect(tracker.observe_tick.reason).to eq(:mindlocked)
    end

    it "keeps the leg while one skill on it still learns" do
      tracker = tracker_for({ "Bow" => 120, "Debilitation" => 130 },
                            { "Bow" => 34, "Debilitation" => 20 }, [100, 150],
                            ["Bow", "Debilitation"])

      expect(tracker.observe_tick.status).to eq(:continue)
    end
  end

  describe "the no-gain backstop" do
    it "counts a stall at a completed fight, never at a plain tick" do
      tracker = tracker_for({ "Bow" => 120 }, { "Bow" => 12 }, [100, 150], ["Bow"], gain_check: 1)
      10.times { tracker.observe_tick }

      expect(tracker.observe_tick.status).to eq(:continue)
    end

    it "advances the leg once every skill has stalled past uc_gain_check" do
      tracker = tracker_for({ "Bow" => 120 }, { "Bow" => 12 }, [100, 150], ["Bow"], gain_check: 2)

      verdicts = 3.times.map { tracker.observe_fight_end }

      expect(verdicts.map(&:status)).to eq([:continue, :continue, :advance])
      expect(verdicts.last.reason).to eq(:no_gain)
    end

    it "resets a skill's stall counter when its mindstate rises" do
      tracker = tracker_for({ "Bow" => 120 }, { "Bow" => 12 }, [100, 150], ["Bow"], gain_check: 2)
      2.times { tracker.observe_fight_end }
      @mindstates["Bow"] = 18

      expect(tracker.observe_fight_end.status).to eq(:continue)
      expect(tracker.observe_fight_end.status).to eq(:continue)
    end

    it "counts a drained mindstate as a stall, matching CT's own rule" do
      tracker = tracker_for({ "Bow" => 120 }, { "Bow" => 12 }, [100, 150], ["Bow"], gain_check: 1)
      tracker.observe_fight_end
      @mindstates["Bow"] = 9

      expect(tracker.observe_fight_end.reason).to eq(:no_gain)
    end

    it "treats a mindlocked skill as already stalled instead of counting it" do
      tracker = tracker_for({ "Bow" => 120, "Debilitation" => 130 },
                            { "Bow" => 12, "Debilitation" => 34 }, [100, 150],
                            ["Bow", "Debilitation"], gain_check: 1)

      expect(tracker.observe_fight_end.status).to eq(:continue)
      expect(tracker.observe_fight_end.reason).to eq(:no_gain)
    end

    it "keeps the leg while one skill on it still gains" do
      tracker = tracker_for({ "Bow" => 120, "Small Edged" => 130 },
                            { "Bow" => 12, "Small Edged" => 12 }, [100, 150],
                            ["Bow", "Small Edged"], gain_check: 1)
      3.times do
        @mindstates["Small Edged"] += 1
        tracker.observe_fight_end
      end

      expect(tracker.observe_fight_end.status).to eq(:continue)
    end
  end

  describe "mid-hunt re-evaluation" do
    it "asks for a reselect when a defensive rank rises" do
      tracker = tracker_for({ "Bow" => 120 }, { "Bow" => 12 }, [100, 150], ["Bow"])
      tracker.observe_tick
      @ranks["Evasion"] = 210

      verdict = tracker.observe_tick

      expect(verdict.status).to eq(:reselect)
      expect(verdict.reason).to eq(:defense_rank_increase)
    end

    it "ignores a rank rise in a skill that belongs to another leg" do
      tracker = tracker_for({ "Bow" => 120, "Slings" => 32 }, { "Bow" => 12 }, [100, 150], ["Bow"])
      tracker.observe_tick
      @ranks["Slings"] = 40

      expect(tracker.observe_tick.status).to eq(:continue)
    end

    it "keeps the leg when the current offence skill rises inside the band" do
      tracker = tracker_for({ "Bow" => 120 }, { "Bow" => 12 }, [100, 150], ["Bow"])
      tracker.observe_tick
      @ranks["Bow"] = 140

      expect(tracker.observe_tick.status).to eq(:continue)
    end

    it "keeps reporting the reselect until the caller replaces the tracker" do
      tracker = tracker_for({ "Bow" => 120 }, { "Bow" => 12 }, [100, 150], ["Bow"])
      tracker.observe_tick
      @ranks["Evasion"] = 210
      tracker.observe_tick

      expect(tracker.observe_tick.status).to eq(:reselect)
    end

    it "reports the hard exit ahead of a pending reselect" do
      tracker = tracker_for({ "Bow" => 120 }, { "Bow" => 12 }, [100, 150], ["Bow"])
      tracker.observe_tick
      @ranks["Evasion"] = 210
      @ranks["Bow"] = 160

      expect(tracker.observe_tick.reason).to eq(:rank_max_exceeded)
    end
  end

  describe "a zone with no parseable band" do
    it "falls back to the no-gain backstop when the zone has no upper bound" do
      tracker = tracker_for({ "Bow" => 120 }, { "Bow" => 12 }, [100, nil], ["Bow"], gain_check: 1)
      @ranks["Bow"] = 900

      expect(tracker.observe_tick.status).to eq(:continue)
      tracker.observe_fight_end

      expect(tracker.observe_fight_end.reason).to eq(:no_gain)
    end
  end
end
