# frozen_string_literal: true

# End to end: the real committed zone table, driven by the real captured
# character. Fixture: notes/uber-combat/fixtures/drazoken-exp-2026-08-14.md.
#
# The fixture is TEST DATA ONLY. Nothing in lib/ reads it, and no production
# value is pegged to it. The character advances, so these tests assert
# invariants that survive advancement, not a frozen leg table.
RSpec.describe UberCombat::ZonePicker, "against the committed zone table" do
  let(:drazoken_ranks) do
    {
      "Evasion" => 168, "Shield Usage" => 151, "Parry Ability" => 141,
      "Small Edged" => 148, "Small Blunt" => 36, "Large Blunt" => 92, "Twohanded Blunt" => 44,
      "Slings" => 32, "Bow" => 120, "Crossbow" => 72, "Polearms" => 47,
      "Light Thrown" => 47, "Heavy Thrown" => 100, "Brawling" => 135, "Offhand Weapon" => 40,
      "Targeted Magic" => 160, "Debilitation" => 138
    }
  end

  let(:table) { UberCombat::ZoneTable.load }
  let(:character) { UberCombat::Character.new(FakeSkills.new(drazoken_ranks)) }
  let(:itinerary) { described_class.new(character, table).build_itinerary }

  it "builds an itinerary with at least one leg" do
    expect(itinerary.legs).not_to be_empty
  end

  it "gives every leg a zone that admits every skill on that leg" do
    picker = described_class.new(character, table)

    itinerary.legs.each do |leg|
      zone = table.zone(leg[:zone_key])
      leg[:skills].reject { |skill| skill == "Debilitation" }.each do |skill|
        expect(picker.admissible?(zone, skill)).to be(true), "#{leg[:zone_key]} rejects #{skill}"
      end
    end
  end

  it "never selects a low confidence zone" do
    expect(itinerary.legs.map { |leg| table.zone(leg[:zone_key]).low_confidence? }).to all(be(false))
  end

  it "never selects a zone without a closed band" do
    expect(itinerary.legs.map { |leg| table.zone(leg[:zone_key]) }).to all(be_closed_band)
  end

  it "gives every leg a stance policy and a real weapon key" do
    itinerary.legs.each do |leg|
      expect(leg[:stance][:policy]).to(satisfy { |policy| UberCombat::Character::STANCES.include?(policy) })
      expect(UberCombat::Character::WEAPON_SKILLS).to include(leg[:stance][:key])
    end
  end

  it "places each trained skill on at most one leg" do
    placed = itinerary.legs.flat_map { |leg| leg[:skills] }

    expect(placed.uniq).to eq(placed)
  end

  it "accounts for every trained offense skill exactly once" do
    placed = itinerary.legs.flat_map { |leg| leg[:skills] }
    reported = itinerary.unplaced.map { |row| row[:skill] }
    trained = UberCombat::Character::TRAINING_SET.select { |skill| drazoken_ranks.key?(skill) }

    expect((placed + reported).sort).to eq(trained.sort)
  end

  it "gives every unplaced skill a reason from the known set" do
    known = [:no_band_in_range, :confidence_excluded, :premium_excluded, :province_excluded,
             :defense_ceiling, :no_carrier]

    expect(itinerary.unplaced.map { |row| row[:reason] }).to all(be_in(known))
  end

  # The default account is non-premium, so no leg may be routed to a zone the
  # data knows is premium-only. Zones with an unknown status are admitted on
  # purpose and are covered by the unresolved report instead.
  it "never selects a known premium zone for a non-premium character" do
    expect(itinerary.legs.map { |leg| table.zone(leg[:zone_key]).premium }).to all(satisfy { |v| v != true })
  end

  it "names every selected zone whose premium status is still unknown" do
    unknown_keys = itinerary.legs.map { |leg| leg[:zone_key] }
                            .select { |key| table.zone(key).premium_unknown? }

    expect(itinerary.unresolved_premium.map { |row| row[:zone_key] }).to match_array(unknown_keys)
  end

  it "never puts Debilitation at the head of a leg" do
    expect(itinerary.legs.map { |leg| leg[:skills].first }).not_to include("Debilitation")
  end
end
