# frozen_string_literal: true

# Wave 7 packet 2. The defence ordering CT writes into @stances[key].
#
# CT pours the character's stance points into the list greedily: slot 1 takes up
# to 100, slot 2 takes the remainder, slot 3 takes what is left
# (combat-trainer.lic:350-354, the priority.each loop). Most characters hold
# fewer than 200 points, so slot 2 is a real allocation and the order is
# load-bearing.
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
    it "orders the defences by descending rank and puts the lagging one last" do
      expect(drazoken.stance_order(:concentrated))
        .to eq(["Evasion", "Shield Usage", "Parry Ability"])
    end
  end

  describe ":spread" do
    it "puts the lagging defence second so that it takes the leftover points" do
      expect(drazoken.stance_order(:spread))
        .to eq(["Evasion", "Parry Ability", "Shield Usage"])
    end
  end

  describe ":dynamic" do
    it "picks the second slot by lowest mindstate, not by lowest rank" do
      subject = character({ "Evasion" => 168, "Shield Usage" => 151, "Parry Ability" => 141 },
                          { "Evasion" => 20, "Shield Usage" => 5, "Parry Ability" => 25 })

      expect(subject.stance_order(:dynamic))
        .to eq(["Evasion", "Shield Usage", "Parry Ability"])
    end

    it "keeps the highest-ranked defence first even when it has the lowest mindstate" do
      subject = character({ "Evasion" => 168, "Shield Usage" => 151, "Parry Ability" => 141 },
                          { "Evasion" => 2, "Shield Usage" => 30, "Parry Ability" => 12 })

      expect(subject.stance_order(:dynamic))
        .to eq(["Evasion", "Parry Ability", "Shield Usage"])
    end

    it "agrees with :spread when the lagging defence also has the lowest mindstate" do
      expect(drazoken.stance_order(:dynamic)).to eq(drazoken.stance_order(:spread))
    end

    it "breaks a mindstate tie in the second slot by lower rank" do
      subject = character({ "Evasion" => 168, "Shield Usage" => 151, "Parry Ability" => 141 },
                          { "Evasion" => 20, "Shield Usage" => 15, "Parry Ability" => 15 })

      expect(subject.stance_order(:dynamic))
        .to eq(["Evasion", "Parry Ability", "Shield Usage"])
    end
  end

  it "rejects an unknown ordering mode" do
    expect { drazoken.stance_order(:whatever) }.to raise_error(ArgumentError, /whatever/)
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
