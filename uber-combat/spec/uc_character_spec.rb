# frozen_string_literal: true

# Test plan cases 1, 2 and 3 (33-zone-picker-spec.md section 7).
RSpec.describe UberCombat::Character do
  describe "#rank_of" do
    it "returns the plain rank when the skill carries no modifier" do
      character = described_class.new(FakeSkills.new("Evasion" => 168))

      expect(character.rank_of("Evasion")).to eq(168.0)
    end

    it "claims half of a buff by averaging base rank with modified rank" do
      character = described_class.new(FakeSkills.new({ "Evasion" => 100 }, { "Evasion" => 40 }))

      expect(character.rank_of("Evasion")).to eq(120.0)
    end

    it "returns zero for a skill the character does not have" do
      character = described_class.new(FakeSkills.new({}))

      expect(character.rank_of("Slings")).to eq(0.0)
    end
  end

  # The first list was built from one character's exp all, which is exactly the
  # thing the design forbids. Zurvan has Large Edged, which was missing, so the
  # skill could never have been given a leg or reported as unplaced.
  describe "the weapon skill list" do
    # drvariables.rb:116-135 minus Parry Ability (a defence) and the three
    # modifiers, which end no fight: Melee Mastery, Missile Mastery, Expertise.
    let(:canonical_weapons) do
      ["Small Edged", "Large Edged", "Twohanded Edged",
       "Small Blunt", "Large Blunt", "Twohanded Blunt",
       "Slings", "Bow", "Crossbow", "Staves", "Polearms",
       "Light Thrown", "Heavy Thrown", "Brawling", "Offhand Weapon"]
    end

    it "holds every weapon skill the game reports" do
      expect(described_class::WEAPON_SKILLS).to match_array(canonical_weapons)
    end

    it "excludes the masteries and Expertise, which modify rather than kill" do
      expect(described_class::KILLING_SET)
        .not_to include("Melee Mastery", "Missile Mastery", "Expertise")
    end

    it "excludes Parry Ability, which is a defence" do
      expect(described_class::TRAINING_SET).not_to include("Parry Ability")
    end
  end

  describe "#defensive_metric" do
    # Drazoken, unbuffed (fixtures/drazoken-exp-2026-08-14.md:87).
    let(:drazoken) do
      described_class.new(FakeSkills.new("Evasion" => 168, "Shield Usage" => 151, "Parry Ability" => 141))
    end

    it "computes the spread pole from the high and weighted low defences" do
      expect(drazoken.defensive_metric(:spread)).to eq(140.4)
    end

    it "computes the concentrated pole as the highest defence alone" do
      expect(drazoken.defensive_metric(:concentrated)).to eq(168.0)
    end

    it "does not fire the outlier rule when the low defence is close to the middle" do
      character = defences(300, 290, 280)

      expect(character.defensive_metric(:spread)).to eq(262.0)
    end

    it "substitutes the middle defence when the low defence is zero" do
      character = defences(400, 380, 0)

      expect(character.defensive_metric(:spread)).to eq(352.0)
    end

    it "substitutes the middle defence when one defence lags far behind" do
      character = defences(300, 290, 50)

      expect(character.defensive_metric(:spread)).to eq(266.0)
    end

    it "does not rescue a genuinely lopsided character" do
      character = defences(300, 60, 50)

      expect(character.defensive_metric(:spread)).to eq(170.0)
    end

    it "raises on an unknown stance rather than returning nil" do
      expect { drazoken.defensive_metric(:crouched) }.to raise_error(ArgumentError)
    end

    def defences(evasion, shield, parry)
      described_class.new(
        FakeSkills.new("Evasion" => evasion, "Shield Usage" => shield, "Parry Ability" => parry)
      )
    end
  end
end
