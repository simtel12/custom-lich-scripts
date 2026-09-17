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

  describe ".label" do
    it "prints a known distance to one decimal place" do
      expect(described_class.label(12.345)).to eq("12.3")
    end

    it "prints unknown for a nil distance" do
      expect(described_class.label(nil)).to eq("unknown")
    end
  end
end
