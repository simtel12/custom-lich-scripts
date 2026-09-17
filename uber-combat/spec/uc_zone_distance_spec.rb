# frozen_string_literal: true

RSpec.describe UberCombat::ZoneDistance do
  let(:rooms) { { "near_zone" => [10, 11], "far_zone" => [20], "cut_off" => [30], "empty" => [] } }
  let(:distances) { { 10 => 7.5, 11 => 3.0, 20 => 250.0 } }
  let(:lookup) { described_class.new(distances, rooms.method(:fetch)) }

  it "answers with the zone's nearest reachable room" do
    expect(lookup.call("near_zone")).to eq(3.0)
    expect(lookup.call("far_zone")).to eq(250.0)
  end

  it "answers nil when none of the zone's rooms is reachable" do
    expect(lookup.call("cut_off")).to be_nil
  end

  it "answers nil for a zone with no rooms" do
    expect(lookup.call("empty")).to be_nil
  end

  describe "#nearest_room" do
    it "answers the room the distance was measured to, with its cost" do
      expect(lookup.nearest_room("near_zone")).to eq([11, 3.0])
    end

    it "answers nil when none of the zone's rooms is reachable" do
      expect(lookup.nearest_room("cut_off")).to be_nil
    end
  end

  describe UberCombat::ZoneDistance::Live do
    # Room#dijkstra's shape: [previous, distances]. Counts its searches,
    # because one search per room is the whole point of the cache.
    let(:room_class) do
      Struct.new(:id, :previous, :distances, :searches) do
        def dijkstra
          self.searches += 1
          [previous, distances]
        end
      end
    end

    let(:here) { room_class.new(1, { 11 => 1 }, { 11 => 3.0, 20 => 9.0 }, 0) }
    let(:there) { room_class.new(2, { 20 => 2 }, { 20 => 1.0 }, 0) }

    # Each call to current_room takes the next room; the last one repeats.
    def live_at(*rooms)
      zone_rooms = { "near_zone" => [11], "far_zone" => [20] }
      described_class.new(zone_rooms.method(:fetch),
                          current_room: -> { rooms.size > 1 ? rooms.shift : rooms.first })
    end

    it "searches once per room, however many zones are asked about" do
      live = live_at(here)
      live.call("near_zone")
      live.call("far_zone")

      expect(here.searches).to eq(1)
    end

    it "searches again once the character has moved" do
      live = live_at(here, there)

      expect(live.call("far_zone")).to eq(9.0)
      expect(live.call("far_zone")).to eq(1.0)
      expect(there.searches).to eq(1)
    end

    it "keeps the search tree and the room it started from" do
      survey = live_at(here).survey

      expect(survey.previous).to eq({ 11 => 1 })
      expect(survey.origin).to eq(1)
    end

    it "answers nil for every zone when the room is unknown" do
      live = described_class.new(->(_key) { [11] }, current_room: -> {})

      expect(live.call("near_zone")).to be_nil
      expect(live.survey).to be_nil
    end
  end

  describe ".label" do
    it "prints a known distance to one decimal place" do
      expect(described_class.label(12.345)).to eq("12.3")
    end

    it "prints unknown for a nil distance" do
      expect(described_class.label(nil)).to eq("unknown")
    end
  end
end
