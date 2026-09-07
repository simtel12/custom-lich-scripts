# frozen_string_literal: true

# Spec: notes/uber-combat/37-zone-probe-spec.md sections 4, 5 and 7.
#
# A scriptable double for the world contract. Each zone's rooms and the
# scripted walk_to outcome for each room are set up per example; distances
# come from a plain Hash the example controls directly, so "the character
# moved" is simulated by simply swapping that Hash out between calls.
#
# Defined at file scope, not inside the RSpec.describe block below -- a
# class is a constant, and Lint/ConstantDefinitionInBlock rejects one
# defined inside a block.
class FakeWorld
  attr_accessor :current_room_id, :distances, :abort_reason, :now
  attr_reader :walk_calls, :announcements

  def initialize
    @announcements = []
    @room_tags = {}
    @walk_scripts = {}
    @blocking_line = nil
    @engaged = false
    @distances = {}
    @walk_calls = []
    @ferries = {}
    @now = Time.utc(2026, 9, 3, 14, 22, 7)
    @current_room_id = nil
    @abort_reason = nil
  end

  def tag(key, room_ids)
    @room_tags[key] = room_ids
  end

  # outcomes: an Array of [arrived, timed_out, elapsed, line, engaged,
  # new_current_room_id] tuples, consumed one per walk_to call to this
  # room, in order. The last tuple is reused once its list is exhausted.
  def script_walk(room_id, *outcomes)
    @walk_scripts[room_id] = outcomes
  end

  def rooms_for_tag(key)
    @room_tags.fetch(key, [])
  end

  # crossings: bescort invocation strings, as UberCombat::Ferry would classify
  # them. Held as ready-made Crossing objects because the world contract hands
  # the core objects, not strings.
  def ferry(room_id, *escorts)
    @ferries[room_id] = escorts.map do |escort|
      name, *mode = escort.split
      UberCombat::Ferry::Crossing.new(from: 0, to: room_id, escort: name, mode: mode, kind: :vehicle)
    end
  end

  def ferries_to(room_id)
    @ferries.fetch(room_id, [])
  end

  # Presentation only, so it is recorded rather than acted on -- but it IS
  # recorded, because "announced before every walk" is the whole point of it
  # and a silent no-op would let that regress unnoticed.
  def announce(zone, room_id, index, count)
    @announcements << [zone.key, room_id, index, count]
  end

  def distances_from(_room_id)
    @distances
  end

  def reset_capture
    @blocking_line = nil
    @engaged = false
  end

  def blocking_line
    @blocking_line
  end

  def engaged?
    @engaged
  end

  def walk_to(room_id, deadline)
    @walk_calls << [room_id, deadline]
    outcomes = @walk_scripts.fetch(room_id, [[false, false, 1.0, nil, false, current_room_id]])
    arrived, timed_out, elapsed, line, engaged, new_room = outcomes.length > 1 ? outcomes.shift : outcomes.first
    @blocking_line = line
    @engaged = engaged
    @current_room_id = new_room
    [arrived, timed_out, elapsed]
  end
end

# Every module method under UberCombat::Probe is pure, so it is exercised
# with nothing but plain Zone objects and Hash/Array fixtures -- no game
# double needed at all. Session is the one class with a seam to the outside
# world, and FakeWorld above is that seam's only implementation this file
# needs: a plain Ruby object satisfying the world contract documented at the
# top of UberCombat::Probe::Session.
RSpec.describe UberCombat::Probe do
  # min/max default to nil, which is a zone with NO closed band -- the shape
  # most of these examples want, and a meaningful case in its own right once
  # a defence is supplied (see the band filter examples below).
  # premium defaults to nil, which is "nobody has checked yet" -- the state
  # the probe exists to change, and so the state most of these examples want.
  def zone(key, access: "plain", min: nil, max: nil, premium: nil, province: nil)
    UberCombat::Zone.new(key, { "access" => access, "premium" => premium, "province" => province,
                                "rank" => { "min" => min, "max" => max } })
  end

  describe ".partition" do
    it "puts an escort zone whose key is also a map tag into escort, never probeable" do
      z = zone("guarded_gate", access: "escort")
      partition = described_class.partition([z], ->(_key) { [101] })

      expect(partition.escort).to eq([z])
      expect(partition.probeable).to be_empty
    end

    it "puts a plain zone with no map tag into no_tag" do
      z = zone("untagged_zone")
      partition = described_class.partition([z], ->(_key) { [] })

      expect(partition.no_tag).to eq([z])
    end

    it "puts a plain, tagged zone into probeable" do
      z = zone("tree_snakes_spiders_baearholt")
      partition = described_class.partition([z], ->(_key) { [8469] })

      expect(partition.probeable).to eq([z])
    end

    it "sorts a full mixed set into all three buckets in one pass" do
      escort = zone("hara_run", access: "escort")
      untagged = zone("dryanoxie")
      probeable = zone("grave_worms")
      tags = { "grave_worms" => [500] }
      partition = described_class.partition([escort, untagged, probeable], ->(key) { tags.fetch(key, []) })

      expect(partition.escort).to eq([escort])
      expect(partition.no_tag).to eq([untagged])
      expect(partition.probeable).to eq([probeable])
    end

    # The probe exists to turn `premium: null` into an answer. A zone that
    # already has one has no signal left to give, and 30 of the 54 zones
    # left after the first live run were exactly that.
    context "with premium already known" do
      it "skips a zone already marked premium" do
        known = zone("undead_gerbils", min: 23, max: 27, premium: true)
        partition = described_class.partition([known], ->(_key) { [8441] }, defence: 68)

        expect(partition.answered).to eq([known])
        expect(partition.probeable).to be_empty
      end

      it "skips a zone already marked not premium" do
        known = zone("louts", min: 0, max: 35, premium: false)
        partition = described_class.partition([known], ->(_key) { [690] }, defence: 68)

        expect(partition.answered).to eq([known])
        expect(partition.probeable).to be_empty
      end

      it "still probes a zone whose premium is unknown" do
        unknown = zone("revenant_conscripts", min: 0, max: 35)
        partition = described_class.partition([unknown], ->(_key) { [706] }, defence: 68)

        expect(partition.probeable).to eq([unknown])
        expect(partition.answered).to be_empty
      end

      # answered outranks out_of_band: knowing the answer settles the zone
      # whatever the character's defences are, and filing it as merely
      # deferred would imply a stronger character should come back for it.
      it "prefers answered over out_of_band when both apply" do
        known = zone("bone_wyverns", min: 1500, max: 1750, premium: true)
        partition = described_class.partition([known], ->(_key) { [900] }, defence: 68)

        expect(partition.answered).to eq([known])
        expect(partition.out_of_band).to be_empty
      end
    end

    context "with a province limit" do
      it "holds back a zone outside the chosen province" do
        away = zone("dusk_ogres", min: 0, max: 30, province: "Forfedhdar")
        partition = described_class.partition([away], ->(_key) { [900] }, province: "Zoluren")

        expect(partition.out_of_province).to eq([away])
        expect(partition.probeable).to be_empty
      end

      it "keeps a zone inside it" do
        home = zone("louts", min: 0, max: 35, province: "Zoluren")
        partition = described_class.partition([home], ->(_key) { [690] }, province: "Zoluren")

        expect(partition.probeable).to eq([home])
      end

      it "admits every province when no limit is set" do
        away = zone("dusk_ogres", min: 0, max: 30, province: "Forfedhdar")
        partition = described_class.partition([away], ->(_key) { [900] })

        expect(partition.probeable).to eq([away])
        expect(partition.out_of_province).to be_empty
      end

      # The province is the hunter's own statement about where they will go.
      # A zone ruled out on those grounds must not ALSO be weighed for
      # danger, or the report suggests a stronger character could have it.
      it "prefers out_of_province over out_of_band when both apply" do
        away = zone("bone_wyverns", min: 1500, max: 1750, province: "Forfedhdar")
        partition = described_class.partition([away], ->(_key) { [900] },
                                              defence: 68, province: "Zoluren")

        expect(partition.out_of_province).to eq([away])
        expect(partition.out_of_band).to be_empty
      end
    end

    # The band filter. The first live plan run queued a rank 200-250 zone
    # second for a character whose defensive metric is 68, and the full
    # distance ordering reaches zones ranked 1500-1750. Distance says
    # nothing about danger, so the partition has to.
    context "with a defence given" do
      it "defers a zone whose floor is above the character's defences" do
        deadly = zone("bone_wyverns", min: 1500, max: 1750)
        partition = described_class.partition([deadly], ->(_key) { [900] }, defence: 68)

        expect(partition.out_of_band).to eq([deadly])
        expect(partition.probeable).to be_empty
      end

      it "keeps a zone the character can survive" do
        safe = zone("undead_gerbils", min: 23, max: 27)
        partition = described_class.partition([safe], ->(_key) { [8441] }, defence: 68)

        expect(partition.probeable).to eq([safe])
        expect(partition.out_of_band).to be_empty
      end

      # The boundary is inclusive, matching ZonePicker#admissible?'s own
      # "defensive_metric >= zone.rank_min" rather than being half a rank
      # stricter than the selector it exists to agree with.
      it "treats a floor exactly equal to the defence as survivable" do
        edge = zone("borderline", min: 68, max: 90)
        partition = described_class.partition([edge], ->(_key) { [1] }, defence: 68)

        expect(partition.probeable).to eq([edge])
      end

      # An unknown floor is an unknown danger. The picker will not select
      # such a zone either, so deferring it costs no decision.
      it "defers a zone with no closed band, because its danger is unknown" do
        vague = zone("silverfish")
        partition = described_class.partition([vague], ->(_key) { [6075] }, defence: 68)

        expect(partition.out_of_band).to eq([vague])
      end

      # Escort and no_tag are permanent facts about the zone; the band is a
      # fact about the character and expires as they train. A zone that can
      # never be walked to must not be filed as merely deferred, or a later,
      # stronger run keeps rediscovering it.
      it "settles escort and no_tag before it ever considers the band" do
        escort = zone("hara_run", access: "escort", min: 1500, max: 1750)
        untagged = zone("dryanoxie", min: 1500, max: 1750)
        partition = described_class.partition([escort, untagged], ->(_key) { [] }, defence: 68)

        expect(partition.escort).to eq([escort])
        expect(partition.no_tag).to eq([untagged])
        expect(partition.out_of_band).to be_empty
      end
    end

    it "applies no band filter at all when the defence is nil" do
      deadly = zone("bone_wyverns", min: 1500, max: 1750)
      partition = described_class.partition([deadly], ->(_key) { [900] })

      expect(partition.probeable).to eq([deadly])
      expect(partition.out_of_band).to be_empty
    end
  end

  describe ".deadline_for" do
    it "returns the floor for a nil distance" do
      expect(described_class.deadline_for(nil)).to eq(described_class::MIN_ATTEMPT_DEADLINE)
    end

    it "scales distance * factor + slack for a mid-range distance" do
      # 100 * 3 + 60 = 360, comfortably inside the floor/ceiling.
      expect(described_class.deadline_for(100)).to eq(360)
    end

    # The floor deliberately no longer overrides a real scaled value. It was
    # 180, and on the first live run that turned a 4.4-second trip into three
    # minutes of go2 restarting into the same guard. The scaled value governs
    # from a distance of one second upward.
    it "lets a tiny distance keep its scaled value rather than forcing the floor" do
      expect(described_class.deadline_for(1)).to eq(63)
    end

    it "still keeps a near-instant trip near the scale of the first live run" do
      # The zone that wedged was 4.4 travel-seconds away: 4.4 * 3 + 60.
      expect(described_class.deadline_for(4.4)).to be_within(0.01).of(73.2)
    end

    it "clamps a huge distance down to the ceiling" do
      expect(described_class.deadline_for(1_000)).to eq(described_class::MAX_ATTEMPT_DEADLINE)
    end
  end

  describe ".rank" do
    it "drops a tagged room dijkstra could not reach at all" do
      z = zone("z1")
      tags = { "z1" => [1, 2] }
      distances = { 1 => 10.0 }
      ranking = described_class.rank([z], distances, ->(key) { tags.fetch(key, []) })

      expect(ranking.next_zone).to eq(z)
      expect(ranking.rooms).to eq([[1, 10.0]])
    end

    it "sorts a zone's reachable rooms ascending by distance" do
      z = zone("z1")
      tags = { "z1" => [1, 2, 3] }
      distances = { 1 => 30.0, 2 => 10.0, 3 => 20.0 }
      ranking = described_class.rank([z], distances, ->(key) { tags.fetch(key, []) })

      expect(ranking.rooms.map(&:first)).to eq([2, 3, 1])
    end

    it "truncates a zone's rooms to MAX_ROOMS_PER_ZONE" do
      z = zone("z1")
      tags = { "z1" => [1, 2, 3, 4, 5] }
      distances = { 1 => 1.0, 2 => 2.0, 3 => 3.0, 4 => 4.0, 5 => 5.0 }
      ranking = described_class.rank([z], distances, ->(key) { tags.fetch(key, []) })

      expect(ranking.rooms.size).to eq(described_class::MAX_ROOMS_PER_ZONE)
      expect(ranking.rooms.map(&:first)).to eq([1, 2, 3])
    end

    it "puts a zone with zero reachable tagged rooms into unreachable, not next_zone" do
      z = zone("retan_hara")
      tags = { "retan_hara" => [11411, 11412] }
      ranking = described_class.rank([z], {}, ->(key) { tags.fetch(key, []) })

      expect(ranking.unreachable).to eq([z])
      expect(ranking.next_zone).to be_nil
      expect(ranking.rooms).to be_nil
    end

    it "picks the zone whose nearest room is nearest overall as next_zone" do
      near = zone("near_zone")
      far = zone("far_zone")
      tags = { "near_zone" => [1], "far_zone" => [2] }
      distances = { 1 => 5.0, 2 => 50.0 }
      ranking = described_class.rank([far, near], distances, ->(key) { tags.fetch(key, []) })

      expect(ranking.next_zone).to eq(near)
    end
  end

  describe ".verdict" do
    it "returns :timeout when timed_out is true, regardless of anything else" do
      verdict = described_class.verdict(arrived: true, current_room_id: 1, zone_rooms: [1],
                                        blocking_line: "a block", timed_out: true)

      expect(verdict).to eq(:timeout)
    end

    it "returns :reached when the current room is in the zone's tagged set" do
      verdict = described_class.verdict(arrived: true, current_room_id: 8469, zone_rooms: [8469],
                                        blocking_line: nil, timed_out: false)

      expect(verdict).to eq(:reached)
    end

    # The load-bearing case: go2 plans against the planned room, not the
    # actual one, so it can legitimately stop in a DIFFERENT room of the
    # same zone. arrived (walk_to's own narrower target-equality boolean) is
    # false, but the verdict is still :reached because it never overrides
    # the set-membership check.
    it "returns :reached by set membership even when walk_to's own arrived is false" do
      verdict = described_class.verdict(arrived: false, current_room_id: 8470,
                                        zone_rooms: [8469, 8470, 8471],
                                        blocking_line: nil, timed_out: false)

      expect(verdict).to eq(:reached)
    end

    it "returns :blocked when a non-empty blocking line was captured" do
      verdict = described_class.verdict(arrived: false, current_room_id: 1, zone_rooms: [8469],
                                        blocking_line: "bars your way", timed_out: false)

      expect(verdict).to eq(:blocked)
    end

    it "returns :blocked_silent when no blocking line was captured" do
      verdict = described_class.verdict(arrived: false, current_room_id: 1, zone_rooms: [8469],
                                        blocking_line: nil, timed_out: false)

      expect(verdict).to eq(:blocked_silent)
    end

    it "returns :blocked_silent when the blocking line is an empty string" do
      verdict = described_class.verdict(arrived: false, current_room_id: 1, zone_rooms: [8469],
                                        blocking_line: "", timed_out: false)

      expect(verdict).to eq(:blocked_silent)
    end
  end

  describe ".record" do
    let(:meta) { { character: "Zurvan", game: "DR", map: "map-1788352278.json", at: "2026-09-03T14:22:07Z" } }

    it "keys the result under reachability -> tier, with string keys throughout" do
      result = described_class.record(zone_key: "tree_snakes_spiders_baearholt", verdict: :blocked,
                                      tier: "basic", meta: meta, room: 8469, rooms_tried: [8469],
                                      line: "bars your way")

      expect(result.keys).to eq(%w[reachability provenance])
      expect(result["reachability"].keys).to eq(["basic"])
      entry = result["reachability"]["basic"]
      expect(entry["verdict"]).to eq("blocked")
      expect(entry["verdict"]).to be_a(String)
    end

    it "stamps the provenance token on reachability only" do
      result = described_class.record(zone_key: "z1", verdict: :reached, tier: "basic", meta: meta)

      expect(result["provenance"]).to eq({ "reachability" => described_class::PROVENANCE_TOKEN })
    end

    it "never writes premium or provenance.premium" do
      result = described_class.record(zone_key: "z1", verdict: :reached, tier: "basic", meta: meta)

      expect(result).not_to have_key("premium")
      expect(result["provenance"]).not_to have_key("premium")
    end

    it "omits the line key entirely when line is nil, rather than writing line: nil" do
      result = described_class.record(zone_key: "z1", verdict: :no_path, tier: "basic", meta: meta)

      expect(result["reachability"]["basic"]).not_to have_key("line")
    end

    it "includes the line verbatim when present" do
      result = described_class.record(zone_key: "z1", verdict: :blocked, tier: "basic", meta: meta,
                                      line: "A worried-looking farmhand bars your way")

      expect(result["reachability"]["basic"]["line"]).to eq("A worried-looking farmhand bars your way")
    end

    # Same rule as `line`, for the same reason: a route with no boat on it and
    # a route nobody checked must stay distinguishable, and every record
    # written before the field existed is honestly in the second category.
    it "omits the crossings key entirely when no ferry is on the route" do
      result = described_class.record(zone_key: "z1", verdict: :reached, tier: "basic", meta: meta,
                                      crossings: [])

      expect(result["reachability"]["basic"]).not_to have_key("crossings")
    end

    it "stores crossings as bescort invocations, not as objects, so the YAML stays readable" do
      crossing = UberCombat::Ferry::Crossing.new(from: 957, to: 1904, escort: "ferry",
                                                 mode: ["leth"], kind: :vehicle)
      result = described_class.record(zone_key: "z1", verdict: :reached, tier: "basic", meta: meta,
                                      crossings: [crossing])

      expect(result["reachability"]["basic"]["crossings"]).to eq(["ferry leth"])
    end

    it "keeps rooms_tried even when it holds a single room equal to room" do
      result = described_class.record(zone_key: "z1", verdict: :blocked, tier: "basic", meta: meta,
                                      room: 8469, rooms_tried: [8469])

      expect(result["reachability"]["basic"]["rooms_tried"]).to eq([8469])
    end

    it "takes the timestamp from meta, never from the clock" do
      result = described_class.record(zone_key: "z1", verdict: :reached, tier: "basic", meta: meta)

      expect(result["reachability"]["basic"]["at"]).to eq("2026-09-03T14:22:07Z")
    end

    it "reads character, game and map straight from meta" do
      result = described_class.record(zone_key: "z1", verdict: :reached, tier: "premium", meta: meta)
      entry = result["reachability"]["premium"]

      expect(entry["character"]).to eq("Zurvan")
      expect(entry["game"]).to eq("DR")
      expect(entry["map"]).to eq("map-1788352278.json")
    end

    it "carries engaged and elapsed through" do
      result = described_class.record(zone_key: "z1", verdict: :blocked, tier: "basic", meta: meta,
                                      engaged: true, elapsed: 42.1)
      entry = result["reachability"]["basic"]

      expect(entry["engaged"]).to be true
      expect(entry["elapsed"]).to eq(42.1)
    end
  end

  describe UberCombat::Probe::Session do
    let(:meta) { { character: "Zurvan", game: "DR", map: "map-1788352278.json" } }

    def session(zones, world, tier: "basic", defence: nil)
      described_class.new(zones, world, tier: tier, meta: meta, defence: defence)
    end

    # The distinction the band filter turns on. escort and no_tag are
    # ANSWERS -- there is nothing to walk to, ever. out_of_band is the
    # absence of an answer, so recording one would settle the zone forever:
    # uc-probe.lic subtracts every recorded zone from the next run's
    # candidates, and a stronger character would then never reconsider it.
    it "skips an already-answered zone WITHOUT recording it or walking to it" do
      world = FakeWorld.new
      world.current_room_id = 100
      world.distances = { 690 => 1.0 }
      known = zone("louts", min: 0, max: 35, premium: false)
      world.tag("louts", [690])

      outcome = session([known], world).run

      expect(outcome.records).to be_empty
      expect(outcome.answered).to eq(1)
      expect(world.walk_calls).to be_empty
      expect(world.announcements).to be_empty
    end

    it "defers an out-of-band zone WITHOUT recording it, so a later run can retry it" do
      world = FakeWorld.new
      world.current_room_id = 100
      world.distances = { 900 => 1.0 }
      deadly = zone("bone_wyverns", min: 1500, max: 1750)
      world.tag("bone_wyverns", [900])

      outcome = session([deadly], world, defence: 68).run

      expect(outcome.records).to be_empty
      expect(outcome.deferred).to eq(1)
      expect(world.walk_calls).to be_empty
    end

    it "still probes the survivable zones in the same run" do
      world = FakeWorld.new
      world.current_room_id = 100
      world.distances = { 900 => 1.0, 8441 => 2.0 }
      deadly = zone("bone_wyverns", min: 1500, max: 1750)
      safe = zone("undead_gerbils", min: 23, max: 27)
      world.tag("bone_wyverns", [900])
      world.tag("undead_gerbils", [8441])
      world.script_walk(8441, [true, false, 5.0, nil, false, 8441])

      outcome = session([deadly, safe], world, defence: 68).run

      expect(outcome.records.keys).to eq(["undead_gerbils"])
      expect(outcome.deferred).to eq(1)
      expect(world.walk_calls.map(&:first)).to eq([8441])
    end

    it "records an escort zone as no_tag without any walk_to call" do
      world = FakeWorld.new
      z = zone("hara_run", access: "escort")
      world.tag("hara_run", [11411]) # even a matching tag must not route it into probeable

      outcome = session([z], world).run

      expect(outcome.records["hara_run"]["reachability"]["basic"]["verdict"]).to eq("no_tag")
      expect(world.walk_calls).to be_empty
    end

    it "records an untagged plain zone as no_tag without any walk_to call" do
      world = FakeWorld.new
      z = zone("dryanoxie")

      outcome = session([z], world).run

      expect(outcome.records["dryanoxie"]["reachability"]["basic"]["verdict"]).to eq("no_tag")
      expect(world.walk_calls).to be_empty
      expect(outcome.visited).to eq(0)
    end

    it "records a zone with no reachable tagged room as no_path without walking" do
      world = FakeWorld.new
      world.current_room_id = 100
      world.distances = {} # nothing reachable, including the zone's own rooms
      z = zone("retan_hara")
      world.tag("retan_hara", [11411, 11412])

      outcome = session([z], world).run

      expect(outcome.records["retan_hara"]["reachability"]["basic"]["verdict"]).to eq("no_path")
      expect(world.walk_calls).to be_empty
      expect(outcome.visited).to eq(0)
    end

    # Detection only: the ferry is recorded next to the verdict and never
    # taken into account when producing it.
    it "records the ferry on the route it walked, without changing the verdict" do
      world = FakeWorld.new
      world.current_room_id = 8246
      world.distances = { 10_041 => 13.8 }
      z = zone("ossein_amalgams")
      world.tag("ossein_amalgams", [10_041])
      world.ferry(10_041, "ferry leth")
      world.script_walk(10_041, [true, false, 90.0, nil, false, 10_041])

      entry = session([z], world).run.records["ossein_amalgams"]["reachability"]["basic"]

      expect(entry["verdict"]).to eq("reached")
      expect(entry["crossings"]).to eq(["ferry leth"])
    end

    it "writes no crossings key for a zone the character walks to dry-shod" do
      world = FakeWorld.new
      world.current_room_id = 100
      world.distances = { 201 => 10.0 }
      z = zone("z1")
      world.tag("z1", [201])
      world.script_walk(201, [true, false, 5.0, nil, false, 201])

      entry = session([z], world).run.records["z1"]["reachability"]["basic"]

      expect(entry).not_to have_key("crossings")
    end

    # walk_to is about to move the character, so a route priced afterwards is
    # the route home, not the route taken.
    it "asks for the route before walking it, not after" do
      world = FakeWorld.new
      world.current_room_id = 100
      world.distances = { 201 => 10.0 }
      z = zone("z1")
      world.tag("z1", [201])
      world.ferry(201, "ferry leth")
      world.script_walk(201, [true, false, 5.0, nil, false, 201])
      asked_at = nil
      allow(world).to receive(:ferries_to).and_wrap_original do |original, room_id|
        asked_at = world.walk_calls.size
        original.call(room_id)
      end

      session([z], world).run

      expect(asked_at).to eq(0)
    end

    it "stops trying rooms the instant one attempt reaches the zone" do
      world = FakeWorld.new
      world.current_room_id = 100
      world.distances = { 201 => 10.0, 202 => 20.0 }
      z = zone("z1")
      world.tag("z1", [201, 202])
      world.script_walk(201, [true, false, 5.0, nil, false, 201])

      outcome = session([z], world).run
      entry = outcome.records["z1"]["reachability"]["basic"]

      expect(entry["verdict"]).to eq("reached")
      expect(entry["room"]).to eq(201)
      expect(world.walk_calls.map(&:first)).to eq([201])
      expect(outcome.visited).to eq(1)
    end

    # rats_lumber has three tagged rooms and every route to all three runs
    # through one step out of room 6054. The probe paid the full stall
    # timeout three times for a single doorway, while a ship's rat walked up.
    it "stops after a second attempt that ends in the same room with the same refusal" do
      world = FakeWorld.new
      world.current_room_id = 6054
      world.distances = { 13171 => 1.0, 13172 => 2.0, 13173 => 3.0 }
      z = zone("rats_lumber", min: 0, max: 30)
      world.tag("rats_lumber", [13171, 13172, 13173])

      outcome = session([z], world).run
      entry = outcome.records["rats_lumber"]["reachability"]["basic"]

      expect(world.walk_calls.map(&:first)).to eq([13171, 13172])
      expect(entry["rooms_tried"]).to eq([13171, 13172])
    end

    it "announces every room it is about to try, naming the zone" do
      world = FakeWorld.new
      world.current_room_id = 100
      world.distances = { 201 => 10.0, 202 => 20.0 }
      z = zone("rats_lumber", min: 0, max: 30)
      world.tag("rats_lumber", [201, 202])
      world.script_walk(201, [false, false, 1.0, "bars your way", false, 301])
      world.script_walk(202, [false, false, 1.0, "bars your way", false, 302])

      session([z], world).run

      expect(world.announcements).to eq([["rats_lumber", 201, 1, 2], ["rats_lumber", 202, 2, 2]])
    end

    # An announcement is a promise that a walk follows. Zones settled without
    # moving must stay silent, or the operator reads travel that never happens.
    it "announces nothing for a zone it never walks to" do
      world = FakeWorld.new
      world.current_room_id = 100
      world.distances = {}
      escort = zone("hara_run", access: "escort")
      unreachable = zone("retan_hara", min: 0, max: 30)
      world.tag("retan_hara", [11411])

      session([escort, unreachable], world).run

      expect(world.announcements).to be_empty
    end

    it "tries every room up to MAX_ROOMS_PER_ZONE before recording a blocked verdict" do
      world = FakeWorld.new
      world.current_room_id = 100
      world.distances = { 201 => 10.0, 202 => 20.0, 203 => 30.0, 204 => 40.0 }
      z = zone("z1")
      world.tag("z1", [201, 202, 203, 204])
      # Each failed attempt leaves the character somewhere DIFFERENT, so the
      # same-barrier rule above never fires and the room cap is what stops
      # this -- which is the thing this example is guarding. Four rooms are
      # tagged and only three may be tried.
      [201, 202, 203].each_with_index do |room, index|
        world.script_walk(room, [false, false, 1.0, "bars your way", false, 300 + index])
      end

      outcome = session([z], world).run
      entry = outcome.records["z1"]["reachability"]["basic"]

      expect(entry["verdict"]).to eq("blocked")
      expect(entry["rooms_tried"]).to eq([201, 202, 203])
      expect(entry["line"]).to eq("bars your way")
      expect(world.walk_calls.map(&:first)).to eq([201, 202, 203])
    end

    it "records blocked_silent when no room ever captured a blocking line" do
      world = FakeWorld.new
      world.current_room_id = 100
      world.distances = { 201 => 10.0 }
      z = zone("z1")
      world.tag("z1", [201])
      world.script_walk(201, [false, false, 1.0, nil, false, 100])

      outcome = session([z], world).run

      expect(outcome.records["z1"]["reachability"]["basic"]["verdict"]).to eq("blocked_silent")
    end

    it "records timeout, not blocked, when the deadline expires" do
      world = FakeWorld.new
      world.current_room_id = 100
      world.distances = { 201 => 10.0 }
      z = zone("z1")
      world.tag("z1", [201])
      world.script_walk(201, [false, true, 180.0, nil, false, 100])

      outcome = session([z], world).run

      expect(outcome.records["z1"]["reachability"]["basic"]["verdict"]).to eq("timeout")
    end

    it "aborts with :position_lost and keeps every record already made" do
      world = FakeWorld.new
      world.current_room_id = nil
      done = zone("dryanoxie") # settles for free before position is even checked
      stuck = zone("z1")
      world.tag("z1", [201])

      outcome = session([done, stuck], world).run

      expect(outcome.aborted).to eq(:position_lost)
      expect(outcome.records.keys).to eq(["dryanoxie"])
      expect(outcome.records).not_to have_key("z1")
    end

    it "aborts with :dijkstra_failed when distances_from returns nil" do
      world = FakeWorld.new
      world.current_room_id = 100
      def world.distances_from(_room_id)
        nil
      end
      z = zone("z1")
      world.tag("z1", [201])

      outcome = session([z], world).run

      expect(outcome.aborted).to eq(:dijkstra_failed)
      expect(outcome.records).to be_empty
    end

    it "stops the run when world.abort_reason fires between zones, keeping partial results" do
      world = FakeWorld.new
      world.current_room_id = 100
      world.distances = { 201 => 10.0, 301 => 999.0 }
      near = zone("near_zone")
      far = zone("far_zone")
      world.tag("near_zone", [201])
      world.tag("far_zone", [301])
      world.script_walk(201, [true, false, 5.0, nil, false, 201])
      world.abort_reason = nil

      # Fires abort_reason only after the first zone is done, by flipping it
      # inside a scripted walk_to for the room the SECOND zone would attempt.
      original_walk = world.method(:walk_to)
      world.define_singleton_method(:walk_to) do |room_id, deadline|
        world.abort_reason = :health_critical if room_id == 201
        original_walk.call(room_id, deadline)
      end

      outcome = session([near, far], world).run

      expect(outcome.aborted).to eq(:health_critical)
      expect(outcome.records.keys).to eq(["near_zone"])
      expect(outcome.records["near_zone"]["reachability"]["basic"]["verdict"]).to eq("reached")
    end

    it "stops trying further rooms in one zone when abort_reason fires mid-attempt" do
      world = FakeWorld.new
      world.current_room_id = 100
      world.distances = { 201 => 10.0, 202 => 20.0 }
      z = zone("z1")
      world.tag("z1", [201, 202])
      world.script_walk(201, [false, false, 1.0, "bars your way", false, 100])

      original_walk = world.method(:walk_to)
      world.define_singleton_method(:walk_to) do |room_id, deadline|
        result = original_walk.call(room_id, deadline)
        world.abort_reason = :health_critical
        result
      end

      outcome = session([z], world).run

      expect(world.walk_calls.map(&:first)).to eq([201])
      expect(outcome.records["z1"]["reachability"]["basic"]["verdict"]).to eq("blocked")
      expect(outcome.aborted).to eq(:health_critical)
    end

    it "re-derives the ranking after every move instead of sorting once up front" do
      world = FakeWorld.new
      world.current_room_id = 100
      a = zone("zone_a")
      b = zone("zone_b")
      world.tag("zone_a", [201])
      world.tag("zone_b", [301])

      # From the start, b looks nearer than a.
      world.distances = { 201 => 50.0, 301 => 10.0 }
      world.script_walk(301, [true, false, 5.0, nil, false, 301])
      # After reaching b (now standing at 301), a is close from there --
      # the second dijkstra call must reflect the move, not the original
      # distances hash.
      world.script_walk(201, [true, false, 5.0, nil, false, 201])

      original_distances = world.method(:distances_from)
      world.define_singleton_method(:distances_from) do |room_id|
        if room_id == 301
          { 201 => 5.0 }
        else
          original_distances.call(room_id)
        end
      end

      outcome = session([a, b], world).run

      expect(world.walk_calls.map(&:first)).to eq([301, 201])
      expect(outcome.records["zone_a"]["reachability"]["basic"]["verdict"]).to eq("reached")
      expect(outcome.records["zone_b"]["reachability"]["basic"]["verdict"]).to eq("reached")
    end

    it "never probes the same zone twice in one run" do
      world = FakeWorld.new
      world.current_room_id = 100
      world.distances = { 201 => 10.0 }
      z = zone("z1")
      world.tag("z1", [201])
      world.script_walk(201, [true, false, 5.0, nil, false, 201])

      session([z], world).run

      expect(world.walk_calls.size).to eq(1)
    end

    it "counts visited as the number of zones actually attempted, excluding no_tag and no_path" do
      world = FakeWorld.new
      world.current_room_id = 100
      untagged = zone("dryanoxie")
      no_path = zone("retan_hara")
      world.tag("retan_hara", [11411])
      walked = zone("z1")
      world.tag("z1", [201])
      world.distances = { 201 => 10.0 }
      world.script_walk(201, [true, false, 5.0, nil, false, 201])

      outcome = session([untagged, no_path, walked], world).run

      expect(outcome.visited).to eq(1)
    end
  end
end
