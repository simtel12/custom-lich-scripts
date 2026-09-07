# frozen_string_literal: true

# The bescort calls below are copied verbatim out of the committed DR map file
# (lich-5/data/DR/map-*.json), not invented, so a change to the way Lich stores
# a crossing shows up here as a failure rather than as a silent no-op.
CROSSING_FERRY = ";e if Script.exists?('bescort'); start_script('bescort', ['ferry', 'leth']); " \
                 "wait_while{ running?('bescort') }; else; echo 'ESCORT REQUIRED'; end"
CROSSING_SEGOLTHA = ";e start_script('bescort', ['segoltha', 'west']);wait_while{running?('bescort')};"
CROSSING_FALDESU = ";e start_script('bescort', ['faldesu', 'crossing']);wait_while{running?('bescort')};"
CROSSING_SANDBARGE = ";e start_script('bescort', ['sandbarge', 'hvaral', 'muspari']);" \
                     "wait_while{running?('bescort')};"
CROSSING_SHARD_GATE = ";e start_script('bescort', ['shard_gate']);wait_while{running?('bescort')};"

# The two overridden methods that make StringProc lie about its own type
# (lich-5/lib/common/class_exts/stringproc.rb:16-22). Reproduced rather than
# stubbed loosely, because uc_ferry's LiveMap#source_of exists solely to cope
# with them and a friendlier double would let a real breakage pass.
class FakeStringProc
  def initialize(source)
    @source = source
  end

  def kind_of?(type)
    Proc.new {}.kind_of?(type)
  end

  def class
    Proc
  end

  def _dump(_depth = nil)
    @source
  end
end

# Enough of Map for LiveMap: findpath plus room lookup with a String-keyed
# wayto, which is how the real map stores it.
class FakeMap
  Room = Struct.new(:id, :wayto)

  def initialize(rooms, paths)
    @rooms = rooms
    @paths = paths
  end

  def [](id)
    @rooms[id.to_i]
  end

  # Map.findpath returns the rooms AFTER the source (map_base.rb:845-865).
  def findpath(from_id, to_id)
    @paths[[from_id.to_i, to_id.to_i]]
  end
end

class FakeFerrySettings
  def initialize(flying_mount)
    @flying_mount = flying_mount
  end

  attr_reader :flying_mount
end

RSpec.describe UberCombat::Ferry do
  describe ".call_args" do
    it "reads the escort and its modes out of a bescort step" do
      expect(described_class.call_args(CROSSING_FERRY)).to eq(%w[ferry leth])
    end

    it "reads a multi-argument escort" do
      expect(described_class.call_args(CROSSING_SANDBARGE)).to eq(%w[sandbarge hvaral muspari])
    end

    it "reads a single-argument escort" do
      expect(described_class.call_args(CROSSING_SHARD_GATE)).to eq(%w[shard_gate])
    end

    it "ignores a plain direction step" do
      expect(described_class.call_args("west")).to be_nil
      expect(described_class.call_args("go dark forge")).to be_nil
    end

    it "ignores a StringProc step that starts some other script" do
      expect(described_class.call_args(";e start_script('gosafe', ['crossing']);")).to be_nil
    end

    it "ignores a missing step" do
      expect(described_class.call_args(nil)).to be_nil
    end
  end

  describe ".kind" do
    it "calls a scheduled vehicle a vehicle whatever the character can do" do
      expect(described_class.kind("ferry", athletics: 900, flying_mount: true)).to eq(:vehicle)
    end

    # The whole reason SWIMS exists. bescort's segoltha (bescort.lic:1533)
    # swims or flies and never boards anything; the Crossing ferry is the
    # separate `ferry` escort. Reporting it as a ferry would be a wait the
    # character never actually has.
    it "never calls the Segoltha a ferry, because bescort swims or flies it" do
      expect(described_class.kind("segoltha", athletics: 0, flying_mount: false)).to eq(:own_power)
    end

    it "calls a maze or a gate neither" do
      expect(described_class.kind("shard_gate")).to eq(:overland)
      expect(described_class.kind("cave_trolls")).to eq(:overland)
      expect(described_class.kind("velaka_dunes")).to eq(:overland)
    end

    # bescort.lic:1112-1133: swim_faldesu when there is a flying mount or
    # Athletics modrank >= 140, take_rh_ferry otherwise. One map edge, two
    # completely different trips, and Map.findpath cannot tell them apart
    # because the branch is inside bescort.
    context "with faldesu, which bescort decides at run time" do
      it "is a ferry for a character who cannot swim it" do
        expect(described_class.kind("faldesu", athletics: 139)).to eq(:vehicle)
      end

      it "is under the character's own power at the threshold" do
        expect(described_class.kind("faldesu", athletics: 140)).to eq(:own_power)
      end

      it "is under the character's own power with a flying mount at any rank" do
        expect(described_class.kind("faldesu", athletics: 0, flying_mount: true)).to eq(:own_power)
      end

      # Naming a ferry that turns out to be a swim costs a line of output.
      # Missing one costs an unexplained wait in the middle of a run.
      it "assumes the ferry when the rank is unknown" do
        expect(described_class.kind("faldesu", athletics: nil)).to eq(:vehicle)
      end
    end
  end

  describe ".why" do
    it "says nothing about an escort that was never in doubt" do
      expect(described_class.why("ferry", athletics: 10)).to be_nil
    end

    it "names the rank and the threshold that decided a conditional escort" do
      expect(described_class.why("faldesu", athletics: 96)).to eq("Athletics 96 < 140")
      expect(described_class.why("faldesu", athletics: 300)).to eq("Athletics 300 >= 140")
      expect(described_class.why("faldesu", athletics: 96, flying_mount: true)).to eq("flying mount")
    end
  end

  describe ".crossings" do
    let(:route) do
      [[8246, 922, "west"],
       [922, 957, "go dock"],
       [957, 1904, CROSSING_FERRY],
       [1904, 10_041, "south"]]
    end

    it "picks the bescort legs out of a route and leaves the walking alone" do
      crossings = described_class.crossings(route)

      expect(crossings.size).to eq(1)
      expect(crossings.first.from).to eq(957)
      expect(crossings.first.to).to eq(1904)
      expect(crossings.first.escort).to eq("ferry")
      expect(crossings.first.mode).to eq(["leth"])
      expect(crossings.first.to_s).to eq("ferry leth")
    end

    it "returns nothing for a route that only walks" do
      expect(described_class.crossings([[1, 2, "west"], [2, 3, "north"]])).to be_empty
    end
  end

  describe ".ferries" do
    let(:route) do
      [[1, 2, CROSSING_SEGOLTHA],
       [2, 3, CROSSING_FERRY],
       [3, 4, CROSSING_SHARD_GATE]]
    end

    it "keeps only the legs that put the character on a vehicle" do
      expect(described_class.ferries(route).map(&:to_s)).to eq(["ferry leth"])
    end

    # The user's requirement stated directly: a character who swims is not
    # slowed by a ferry and must not be reported as if they were.
    it "drops a conditional crossing the character can swim" do
      swim_route = [[1, 2, CROSSING_FALDESU]]

      expect(described_class.ferries(swim_route, athletics: 300)).to be_empty
      expect(described_class.ferries(swim_route, athletics: 100).map(&:to_s)).to eq(["faldesu crossing"])
    end
  end

  describe ".path_from" do
    # 1 -> 2 -> 3 -> 4
    let(:previous) { { 2 => 1, 3 => 2, 4 => 3 } }

    it "reconstructs the rooms after the source, findpath's own shape" do
      expect(described_class::LiveMap.path_from(previous, 1, 4)).to eq([2, 3, 4])
    end

    it "returns an empty path for the room the character is already in" do
      expect(described_class::LiveMap.path_from(previous, 1, 1)).to eq([])
    end

    it "returns nil for a room the search never reached" do
      expect(described_class::LiveMap.path_from(previous, 1, 99)).to be_nil
    end

    # A chain that never reaches the source, or that revisits a room, would
    # otherwise loop forever. Dijkstra should produce neither; this is a public
    # entry point, so it must not depend on that.
    it "returns nil rather than looping on a chain that never reaches the source" do
      expect(described_class::LiveMap.path_from({ 4 => 3, 3 => 4 }, 1, 4)).to be_nil
    end
  end

  describe UberCombat::Ferry::LiveMap do
    # The Crossing ferry as the map actually stores it: 8246 -> ... -> 10041,
    # with the boarding step on 957 -> 1904.
    let(:map) do
      FakeMap.new(
        { 8246   => FakeMap::Room.new(8246, { "957" => "west" }),
          957    => FakeMap::Room.new(957, { "1904" => FakeStringProc.new(CROSSING_FERRY[3..]) }),
          1904   => FakeMap::Room.new(1904, { "10041" => "south" }),
          10_041 => FakeMap::Room.new(10_041, {}) },
        { [8246, 10_041] => [957, 1904, 10_041] }
      )
    end

    def live_map(athletics: 50, flying_mount: nil)
      described_class.new(map: map,
                          skills: FakeSkills.new({ "Athletics" => athletics }),
                          settings: FakeFerrySettings.new(flying_mount))
    end

    it "finds the ferry on the route from a saferoom to a hunting zone" do
      expect(live_map.ferries(8246, 10_041).map(&:to_s)).to eq(["ferry leth"])
    end

    it "reports no ferry for a route with no path" do
      expect(live_map.ferries(8246, 99_999)).to be_nil
    end

    it "reads a StringProc step even though it claims to be a Proc" do
      step = map[957].wayto["1904"]

      # Guard on the double itself: if these ever stop lying, the production
      # code's careful handling of them stops being necessary and this spec
      # stops testing anything.
      expect(step.class).to eq(Proc)
      expect(step.kind_of?(UberCombat::Ferry::LiveMap)).to be(false)
      expect(live_map.steps(8246, 10_041)[1][2]).to include("bescort")
    end

    it "runs the path search once per pair" do
      subject = live_map
      expect(map).to receive(:findpath).once.and_call_original

      2.times { subject.ferries(8246, 10_041) }
    end

    it "reads Athletics once, not once per question" do
      skills = FakeSkills.new({ "Athletics" => 50 })
      subject = described_class.new(map: map, skills: skills,
                                    settings: FakeFerrySettings.new(nil))
      expect(skills).to receive(:modrank).once.and_call_original

      subject.ferries(8246, 10_041)
      subject.ferries(8246, 10_041)
    end

    it "uses an injected path finder instead of searching, when given one" do
      calls = []
      subject = described_class.new(
        map: map, skills: FakeSkills.new({ "Athletics" => 50 }),
        settings: FakeFerrySettings.new(nil),
        findpath: ->(from, to) { calls << [from, to] and [957, 1904, 10_041] }
      )

      expect(subject.ferries(8246, 10_041).map(&:to_s)).to eq(["ferry leth"])
      expect(calls).to eq([[8246, 10_041]])
    end

    it "treats a profile with no flying_mount key as no mount" do
      subject = described_class.new(map: map, skills: FakeSkills.new({ "Athletics" => 50 }),
                                    settings: Object.new)

      expect(subject.flying_mount?).to be(false)
    end
  end
end
