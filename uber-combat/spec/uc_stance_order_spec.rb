# frozen_string_literal: true

# Wave 7 packet 2. The defence ordering CT writes into @stances[key].
#
# CT pours the character's stance points into the list greedily: slot 1 takes up
# to 100, slot 2 takes the remainder, slot 3 takes what is left
# (combat-trainer.lic:350-354, the priority.each loop). Most characters hold
# fewer than 200 points, so slot 2 is a real allocation.
#
# With strict_weapon_stance false, which is the shipped default, CT re-sorts the
# FIRST TWO by learning need every combat cycle and leaves the third alone
# (CT:329-335). So the mode does not choose slot 1. It chooses which defence is
# BANISHED to slot 3, and CT splits the points between the two survivors.
RSpec.describe UberCombat::Character, "stance ordering" do
  def character(ranks, mindstates = {})
    described_class.new(FakeSkills.new(ranks, {}, mindstates))
  end

  # Evasion is the strong defence, Parry Ability the lagging one.
  let(:drazoken) do
    character({ "Evasion" => 168, "Shield Usage" => 151, "Parry Ability" => 141 },
              { "Evasion" => 20, "Shield Usage" => 30, "Parry Ability" => 10 })
  end

  describe ":concentrated" do
    it "banishes the lagging defence to slot 3, leaving the two strongest in play" do
      expect(drazoken.stance_order(:concentrated))
        .to eq(["Evasion", "Shield Usage", "Parry Ability"])
    end
  end

  describe ":spread" do
    it "banishes the middle defence to slot 3, keeping the lagging one in play" do
      expect(drazoken.stance_order(:spread))
        .to eq(["Evasion", "Parry Ability", "Shield Usage"])
    end
  end

  it "rejects an unknown ordering mode" do
    expect { drazoken.stance_order(:whatever) }.to raise_error(ArgumentError, /whatever/)
  end

  # CT already picks the second defence by learning need, every combat cycle,
  # for free. Our own version needed strict_weapon_stance true, which switches
  # CT's version off, so the two could never both run.
  it "no longer offers a dynamic mode, because CT owns that choice" do
    expect { drazoken.stance_order(:dynamic) }.to raise_error(ArgumentError, /dynamic/)
    expect(described_class::ORDER_MODES).to eq([:spread, :concentrated])
  end

  describe "#mindstate_of" do
    it "reads the skill's learning rate" do
      expect(drazoken.mindstate_of("Shield Usage")).to eq(30)
    end

    it "reports zero for a skill the character does not have" do
      expect(drazoken.mindstate_of("Slings")).to eq(0)
    end
  end
end
