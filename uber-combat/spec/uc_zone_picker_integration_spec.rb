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

  # KILLING skills only. Debilitation is deliberately exempt: it rides every
  # leg whose band admits it (user, 2026-09-05), because it is a multiplier
  # whose value is spread across the itinerary rather than banked on one leg.
  # The invariant still matters for everything that kills -- a weapon on two
  # legs would be trained twice per cycle at another weapon's expense.
  it "places each trained killing skill on at most one leg" do
    placed = itinerary.legs.flat_map { |leg| leg[:skills] }
                      .select { |skill| UberCombat::Character::KILLING_SET.include?(skill) }

    expect(placed.uniq).to eq(placed)
  end

  it "accounts for every trained offense skill exactly once" do
    placed = itinerary.legs.flat_map { |leg| leg[:skills] }
                      .select { |skill| UberCombat::Character::KILLING_SET.include?(skill) }
    reported = itinerary.unplaced.map { |row| row[:skill] }
    trained = UberCombat::Character::KILLING_SET.select { |skill| drazoken_ranks.key?(skill) }

    expect((placed + reported - ["Debilitation"]).sort).to eq(trained.sort)
  end

  # Debilitation is reported as unplaced ONLY when no leg can train it. If any
  # leg admits its rank, every such leg carries it and nothing is reported.
  it "carries Debilitation on every leg that admits it, or reports it once" do
    carriers = itinerary.legs.count { |leg| leg[:skills].include?("Debilitation") }
    reported = itinerary.unplaced.count { |row| row[:skill] == "Debilitation" }

    expect(carriers.positive? ^ reported.positive?).to be(true)
    expect(reported).to be <= 1
  end

  # Widened deliberately, not to make anything pass. :escort_access and
  # :unknown_critter_band joined ZonePicker#exclusion_record and are valid
  # reasons, but this list did not gain them and kept passing, because the
  # Drazoken fixture happens to produce neither. A later rank change or data
  # edit would then fail here for a reason that is perfectly correct.
  it "gives every unplaced skill a reason from the known set" do
    known = [:no_band_in_range, :escort_access, :unknown_critter_band,
             :confidence_excluded, :premium_excluded, :province_excluded,
             :defense_ceiling, :no_carrier, :not_configured]

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

  # REGRESSION. assign_debilitation used to ask whether ANY of the leg's zone
  # CANDIDATES admitted Debilitation's rank, while present then chose the
  # narrowest candidate -- usually a different zone. That put Debilitation at
  # rank 138 on a leg whose chosen zone was young_ogres, banded 80-120, which
  # cannot teach it. One carrier hid the bug; making it ride every admitting
  # leg exposed it. Both now ask chosen_zone.
  it "lists Debilitation only on legs whose CHOSEN zone can teach it" do
    itinerary.legs.each do |leg|
      next unless leg[:skills].include?("Debilitation")

      zone = table.zone(leg[:zone_key])
      expect(zone.rank_min).to be <= drazoken_ranks["Debilitation"]
      expect(zone.rank_max).to be >= drazoken_ranks["Debilitation"]
    end
  end

  it "never puts Debilitation at the head of a leg" do
    expect(itinerary.legs.map { |leg| leg[:skills].first }).not_to include("Debilitation")
  end
end
