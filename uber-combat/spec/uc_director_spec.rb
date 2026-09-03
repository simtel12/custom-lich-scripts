# frozen_string_literal: true

# Spec: notes/uber-combat/42-director-spec.md section 9 (the test plan),
# against sections 2 to 7.
#
# The pure core has no Lich, so every example here drives a fake world. Only
# the WORLD is fake: build_itinerary returns a real ZonePicker::Itinerary,
# overlay_for runs the real LegOverlay, write_overlay runs the real, pure
# LegWriter.decide, and tracker_for returns a real LegTracker driven by a real
# Character over FakeSkills. A double that returned a hand-made Struct where
# the production code returns a real object would let a shape drift silently,
# which is the one bug this suite exists to catch.
#
# The spec's section 9 puts this class in spec/support/fake_director_world.rb.
# It lives here instead (see the report accompanying this file): support/ holds
# doubles that several spec files share, and this one has exactly one consumer.
# It is named FakeDirectorWorld rather than FakeWorld because spec/
# uc_probe_spec.rb already defines a file-scope FakeWorld, and the whole suite
# runs in one process -- two classes of the same name would silently be one.
#
# Defined at file scope, not inside the RSpec.describe block: a class is a
# constant, and Lint/ConstantDefinitionInBlock rejects one defined in a block.

# Counts the two tracker calls without changing what either one does. The
# director must call observe_tick exactly once per productive stint and must
# NEVER call observe_fight_end (decision 10), and both halves of that are
# unobservable from the outside of a real LegTracker.
class RecordingTracker
  attr_reader :ticks, :fight_ends

  def initialize(tracker)
    @tracker = tracker
    @ticks = 0
    @fight_ends = 0
  end

  def observe_tick
    @ticks += 1
    @tracker.observe_tick
  end

  def observe_fight_end
    @fight_ends += 1
    @tracker.observe_fight_end
  end
end

class FakeDirectorWorld
  # A director bug that fails to terminate must fail LOUDLY rather than hang
  # the suite. Every example here is bounded by a budget, a failure counter or
  # a refusal, so any run that reaches either cap is a defect.
  MAX_STINTS = 40
  MAX_CYCLES = 120

  attr_accessor :abort_detail, :weapons, :existing_first_line, :write_error
  attr_writer :abort_reason
  attr_reader :events, :trace, :checkpoints, :timeouts, :overlay_calls, :snapshot_calls,
              :itinerary_calls, :recoveries, :trackers, :ranks, :mindstates

  # itinerary: the first ZonePicker::Itinerary build_itinerary hands back.
  #   queue_itinerary adds the ones a :reselect rebuild gets; the last one is
  #   reused once the queue is down to a single entry.
  # ranks / mindstates: held by reference and mutated by a scripted stint, so
  #   "the character trained during the hunt" is simulated the way
  #   uc_leg_tracker_spec.rb already simulates it.
  # bands: zone key -> [rank_min, rank_max] for the Zone a tracker is built
  #   over. The default band is wide enough that no leg is ever outgrown by
  #   accident.
  def initialize(itinerary, ranks: {}, mindstates: {}, bands: {})
    @itineraries = [itinerary]
    @itinerary_calls = 0
    @checkpoints = 0
    @cycles = 0
    @events = []
    @trace = []
    @timeouts = []
    @overlay_calls = []
    @snapshot_calls = []
    @recoveries = []
    @trackers = []
    @stints = []
    @bands = bands
    @weapons = nil
    @existing_first_line = nil
    @write_error = nil
    @abort_reason = nil
    @abort_detail = nil
    @now = Time.utc(2026, 9, 3, 8, 0, 0)
    @ranks = { "Evasion" => 200, "Shield Usage" => 180, "Parry Ability" => 160 }.merge(ranks)
    @mindstates = mindstates
  end

  def queue_itinerary(itinerary)
    @itineraries << itinerary
    self
  end

  # One scripted stint, consumed in order. The last entry is reused once the
  # queue is exhausted, so an example only scripts the stints it cares about.
  #
  # ranks / mindstates are applied DURING the stint, between the two
  # snapshots, which is exactly when a real character's numbers move.
  # abort sets the safety ladder afterwards, for the "stops mid-run" examples.
  def script_stint(outcome: :completed, stop_reason: :duration, exit_error: nil, elapsed: 1800.0,
                   ranks: {}, mindstates: {}, abort: nil, abort_detail: nil)
    @stints << { outcome: outcome, stop_reason: stop_reason, exit_error: exit_error,
                 elapsed: elapsed, ranks: ranks, mindstates: mindstates,
                 abort: abort, abort_detail: abort_detail }
    self
  end

  def character
    UberCombat::Character.new(FakeSkills.new(@ranks, {}, @mindstates))
  end

  # --- the section 3.1 contract, and nothing else -----------------------

  def now
    @now
  end

  # Traced, unlike #now, because WHERE the safety ladder is consulted is part
  # of the contract: after the checkpoint and before the leg is selected.
  def abort_reason
    @trace << :abort_reason
    @abort_reason
  end

  def checkpoint
    @checkpoints += 1
    @cycles += 1
    raise "checkpoint called #{@cycles} times: the director loop is not terminating" if @cycles > MAX_CYCLES

    @trace << :checkpoint
    nil
  end

  def build_itinerary
    @trace << :build_itinerary
    @itinerary_calls += 1
    @itineraries.length > 1 ? @itineraries.shift : @itineraries.first
  end

  def overlay_for(leg, duration:)
    @trace << :overlay_for
    @overlay_calls << [leg, duration]
    catalogue = @weapons || leg[:skills].to_h { |skill| [skill, "longsword"] }
    UberCombat::LegOverlay.new(character, catalogue).build(leg, duration: duration)
  end

  # The real, pure LegWriter.decide, which is everything LegWriter.write does
  # except touch the disk. A :gaps refusal therefore comes from the overlay's
  # own gap records and a :foreign_file refusal from a real first-line
  # comparison against the real MARKER.
  def write_overlay(overlay)
    @trace << :write_overlay
    raise @write_error if @write_error

    decision = UberCombat::LegWriter.decide(overlay, @existing_first_line)
    UberCombat::LegWriter::Result.new(written: decision.write, path: "/nonexistent/uc.yaml",
                                      reason: decision.reason)
  end

  def tracker_for(leg)
    @trace << :tracker_for
    band = @bands.fetch(leg[:zone_key], [0, 1000])
    zone = UberCombat::Zone.new(leg[:zone_key], { "rank" => { "min" => band[0], "max" => band[1] } })
    tracker = RecordingTracker.new(
      UberCombat::LegTracker.new(character, zone: zone, skills: leg[:skills])
    )
    @trackers << tracker
    tracker
  end

  def snapshot(skills)
    @trace << :snapshot
    @snapshot_calls << skills
    skills.to_h do |skill|
      [skill, { rank: @ranks.fetch(skill, 0).to_f, mindstate: @mindstates.fetch(skill, 0) }]
    end
  end

  def run_stint(timeout)
    @trace << :run_stint
    raise "run_stint called #{@timeouts.size + 1} times: the director loop is not terminating" if @timeouts.size >= MAX_STINTS

    @timeouts << timeout
    script = @stints.length > 1 ? @stints.shift : (@stints.first || default_stint)

    @now += script[:elapsed]
    script[:ranks].each { |skill, delta| @ranks[skill] = @ranks.fetch(skill, 0) + delta }
    script[:mindstates].each { |skill, value| @mindstates[skill] = value }
    @abort_reason = script[:abort] if script[:abort]
    @abort_detail = script[:abort_detail] if script[:abort_detail]

    UberCombat::Director::Launch.new(outcome: script[:outcome], stop_reason: script[:stop_reason],
                                     completed_successfully: script[:outcome] == :completed,
                                     exit_error: script[:exit_error])
  end

  def recover(reason)
    @trace << :recover
    @recoveries << reason
    nil
  end

  def announce(event, payload)
    @trace << :announce
    @events << [event, payload]
    nil
  end

  def event(name)
    @events.select { |recorded, _payload| recorded == name }.map(&:last)
  end

  def event_names
    @events.map(&:first)
  end

  private

  def default_stint
    { outcome: :completed, stop_reason: :duration, exit_error: nil, elapsed: 1800.0,
      ranks: {}, mindstates: {}, abort: nil, abort_detail: nil }
  end
end

RSpec.describe UberCombat::Director do
  # ZonePicker#present's exact output shape (uc_zone_picker.rb:271-277).
  def leg(skills, zone_key: "crossing_rats", policy: :spread)
    { skills: skills, zone_key: zone_key,
      stance: { policy: policy, key: skills.first }, min_mana: nil }
  end

  def itinerary(*legs)
    UberCombat::ZonePicker::Itinerary.new(legs: legs, unplaced: [], unresolved_premium: [])
  end

  def launch(outcome: :completed, stop_reason: nil, exit_error: nil)
    UberCombat::Director::Launch.new(outcome: outcome, stop_reason: stop_reason,
                                     completed_successfully: outcome == :completed,
                                     exit_error: exit_error)
  end

  def sample(rank, mindstate = 0)
    { rank: rank, mindstate: mindstate }
  end

  def session_for(world)
    UberCombat::Director::Session.new(world)
  end

  describe ".timeout_for" do
    it "adds the slack to the duration in seconds" do
      expect(described_class.timeout_for(30)).to eq((30 * 60) + described_class::STINT_SLACK_SECONDS)
    end

    # hunting-buddy's own stop counts loop iterations rather than the clock
    # (hunting-buddy.lic:622, :670-671), so a stint always overruns its
    # duration. A timeout equal to the duration would fire on every good stint.
    it "is strictly greater than the duration alone" do
      expect(described_class.timeout_for(30)).to be > 30 * 60
    end
  end

  describe ".wrap" do
    it "returns the next index" do
      expect(described_class.wrap(1, 3)).to eq(1)
    end

    it "wraps the last index back to zero" do
      expect(described_class.wrap(3, 3)).to eq(0)
    end

    it "returns zero for a single-leg itinerary" do
      expect(described_class.wrap(1, 1)).to eq(0)
    end
  end

  describe ".next_playable" do
    it "returns the current index when it is not refused" do
      expect(described_class.next_playable(1, 3, {})).to eq(1)
    end

    it "skips a refused index and returns the next playable one" do
      expect(described_class.next_playable(0, 3, { 0 => :gaps })).to eq(1)
    end

    it "wraps past the end to find a playable index" do
      expect(described_class.next_playable(2, 3, { 2 => :gaps, 0 => :failed_to_hunt })).to eq(1)
    end

    # Section 6.5: a loop that kept selecting here would spin at full speed
    # with no game contact at all.
    it "returns nil when every index is refused" do
      expect(described_class.next_playable(0, 2, { 0 => :gaps, 1 => :gaps })).to be_nil
    end
  end

  describe ".gained?" do
    def stint_with(skills, before, after)
      described_class::Stint.new(leg: leg(skills), before: before, after: after)
    end

    it "is true when one leg skill's rank rose" do
      stint = stint_with(["Bow", "Brawling"],
                         { "Bow" => sample(100.0), "Brawling" => sample(90.0) },
                         { "Bow" => sample(100.0), "Brawling" => sample(90.5) })

      expect(described_class.gained?(stint)).to be(true)
    end

    it "is false when no leg skill's rank rose" do
      stint = stint_with(["Bow"], { "Bow" => sample(100.0) }, { "Bow" => sample(100.0) })

      expect(described_class.gained?(stint)).to be(false)
    end

    # Mindstate is pending experience, not rank. A leg that fills mindstate
    # for three stints without converting a rank is exactly what BARREN_LIMIT
    # is for.
    it "is false when only a mindstate rose" do
      stint = stint_with(["Bow"], { "Bow" => sample(100.0, 5) }, { "Bow" => sample(100.0, 20) })

      expect(described_class.gained?(stint)).to be(false)
    end

    it "ignores a rank rise in a skill that is not on the leg" do
      stint = stint_with(["Bow"],
                         { "Bow" => sample(100.0), "Evasion" => sample(200.0) },
                         { "Bow" => sample(100.0), "Evasion" => sample(201.0) })

      expect(described_class.gained?(stint)).to be(false)
    end
  end

  describe ".classify" do
    def classify(launch_value, elapsed: 1800.0, before: nil, after: nil, skills: ["Bow"])
      before ||= { "Bow" => sample(100.0, 10) }
      after ||= { "Bow" => sample(100.0, 10) }
      described_class.classify(launch: launch_value, elapsed: elapsed, before: before,
                               after: after, skills: skills)
    end

    it "returns :launch_refused on a start error" do
      expect(classify(launch(outcome: :start_error))).to eq(:launch_refused)
    end

    it "returns :timed_out on a timeout" do
      expect(classify(launch(outcome: :timeout))).to eq(:timed_out)
    end

    it "returns :crashed when exit_error is set" do
      expect(classify(launch(stop_reason: :duration, exit_error: RuntimeError.new("boom")))).to eq(:crashed)
    end

    # A non-nil reason is proof the hunt loop RAN (@hunt_stop_reason is only
    # ever assigned inside hunt, hunting-buddy.lic:576 and below), which is a
    # claim about control flow rather than about why the hunt stopped.
    it "returns :productive whenever the stop reason is non-nil, however short the stint" do
      expect(classify(launch(stop_reason: :boxes_full), elapsed: 3.0)).to eq(:productive)
    end

    it "returns :failed_to_hunt on a nil reason and an elapsed under MIN_PRODUCTIVE_STINT" do
      expect(classify(launch, elapsed: described_class::MIN_PRODUCTIVE_STINT - 1)).to eq(:failed_to_hunt)
    end

    it "returns :failed_to_hunt on a nil reason when no leg skill moved at all" do
      expect(classify(launch)).to eq(:failed_to_hunt)
    end

    # Mindstate FALLS while experience absorbs into ranks during the walk home
    # (uc_leg_tracker.rb:47-50), and a fall is still evidence there was
    # experience to absorb.
    it "returns :productive on a nil reason when a mindstate FELL (drain is still movement)" do
      verdict = classify(launch, before: { "Bow" => sample(100.0, 30) },
                                 after: { "Bow" => sample(100.0, 4) })

      expect(verdict).to eq(:productive)
    end

    it "returns :productive on a nil reason with a long stint and moved skills" do
      verdict = classify(launch, before: { "Bow" => sample(100.0, 10) },
                                 after: { "Bow" => sample(101.0, 10) })

      expect(verdict).to eq(:productive)
    end
  end

  describe ".decide" do
    def verdict(status)
      UberCombat::LegTracker::Verdict.new(status: status)
    end

    it "returns :advance for a tracker :advance verdict" do
      expect(described_class.decide(verdict(:advance), 0, 3)).to eq(:advance)
    end

    it "returns :advance when the barren count reaches the limit" do
      expect(described_class.decide(verdict(:continue), 3, 3)).to eq(:advance)
    end

    it "prefers :advance over :reselect when both apply" do
      expect(described_class.decide(verdict(:advance), 0, 3)).to eq(:advance)
    end

    # The livelock guard, section 5.4. LegTracker's :reselect is sticky and a
    # rebuild resets the director's per-index counters, so checking :reselect
    # first would let a character whose defences keep rising rebuild, reset
    # barren, hunt, rebuild again -- and never advance a barren leg.
    it "prefers the barren backstop over :reselect" do
      expect(described_class.decide(verdict(:reselect), 3, 3)).to eq(:advance)
    end

    it "returns :reselect for a sticky reselect verdict below the barren limit" do
      expect(described_class.decide(verdict(:reselect), 2, 3)).to eq(:reselect)
    end

    it "returns :continue otherwise" do
      expect(described_class.decide(verdict(:continue), 1, 3)).to eq(:continue)
    end
  end

  describe ".resume_index" do
    it "finds the leg with the same skills in a rebuilt itinerary" do
      rebuilt = itinerary(leg(["Brawling"]), leg(["Bow"]))

      expect(described_class.resume_index(rebuilt, leg(["Bow"]))).to eq(1)
    end

    it "returns zero when the previous leg is gone" do
      rebuilt = itinerary(leg(["Brawling"]), leg(["Slings"]))

      expect(described_class.resume_index(rebuilt, leg(["Bow"]))).to eq(0)
    end
  end

  describe ".safety_stop?" do
    it "is true for :health, :spirit and :dead" do
      expect([:health, :spirit, :dead].map { |reason| described_class.safety_stop?(reason) })
        .to eq([true, true, true])
    end

    it "is false for :budget_spent, :no_legs, :all_legs_refused and every writer reason" do
      reasons = [:budget_spent, :no_legs, :all_legs_refused, :foreign_file, :write_error,
                 :overlay_error, :launch_refused]

      expect(reasons.map { |reason| described_class.safety_stop?(reason) }).to all(be(false))
    end
  end

  describe UberCombat::Director::Session do
    let(:bow) { leg(["Bow"], zone_key: "crossing_rats") }
    let(:brawling) { leg(["Brawling"], zone_key: "sand_beetles") }

    def world_for(*legs, **options)
      ranks = { "Bow" => 100, "Brawling" => 90 }.merge(options.delete(:ranks) || {})
      FakeDirectorWorld.new(itinerary(*legs), ranks: ranks, **options)
    end

    describe "the loop" do
      it "builds the itinerary exactly once when nothing reselects" do
        world = world_for(bow)
        session_for(world).run(2)

        expect(world.itinerary_calls).to eq(1)
      end

      it "writes an overlay before every stint" do
        world = world_for(bow)
        session_for(world).run(3)

        expect(world.trace.count(:write_overlay)).to eq(world.trace.count(:run_stint))
      end

      it "passes DURATION_MINUTES to overlay_for on every leg" do
        world = world_for(bow, brawling)
        session_for(world).run(4)

        expect(world.overlay_calls.map(&:last)).to all(eq(UberCombat::Director::DURATION_MINUTES))
      end

      it "passes timeout_for(DURATION_MINUTES) to run_stint" do
        world = world_for(bow)
        session_for(world).run(2)

        expected = UberCombat::Director.timeout_for(UberCombat::Director::DURATION_MINUTES)
        expect(world.timeouts).to all(eq(expected))
      end

      # C3. Neither `pause` nor DRC.message routes through Script.current, so
      # without this call `;p uc-director` would have no effect anywhere.
      it "calls checkpoint before every cycle" do
        world = world_for(bow)
        session_for(world).run(3)

        expect(world.checkpoints).to eq(3)
        expect(world.trace.first(2)).to eq([:build_itinerary, :checkpoint])
      end

      it "calls abort_reason before selecting a leg" do
        world = world_for(bow)
        session_for(world).run(1)

        expect(world.trace.index(:abort_reason)).to be < world.trace.index(:overlay_for)
      end

      # Decision 15: a director paused for an hour between cycles must not
      # measure the next stint against ranks read before the pause.
      it "snapshots after the checkpoint and before run_stint" do
        world = world_for(bow)
        session_for(world).run(1)

        expect(world.trace.first(9)).to eq([:build_itinerary, :checkpoint, :abort_reason, :announce,
                                            :overlay_for, :write_overlay, :tracker_for, :snapshot,
                                            :run_stint])
      end

      # Mindstate drains into ranks while the character stands there, so
      # anything printed first is measurement lost.
      it "snapshots again immediately after run_stint" do
        world = world_for(bow)
        session_for(world).run(1)

        expect(world.trace[world.trace.index(:run_stint) + 1]).to eq(:snapshot)
      end

      it "stops when the productive budget is spent" do
        world = world_for(bow)
        outcome = session_for(world).run(2)

        expect(outcome.stopped).to eq(:budget_spent)
        expect(outcome.productive).to eq(2)
        expect(outcome.stints.size).to eq(2)
        expect(world.event(:stopped).last[:reason]).to eq(:budget_spent)
      end

      it "stops with :no_legs on an empty itinerary" do
        world = FakeDirectorWorld.new(itinerary)
        outcome = session_for(world).run(2)

        expect(outcome.stopped).to eq(:no_legs)
        expect(world.trace).not_to include(:run_stint)
      end
    end

    describe "advancement" do
      it "calls observe_tick exactly once per productive stint" do
        world = world_for(bow)
        session_for(world).run(3)

        expect(world.trackers.sum(&:ticks)).to eq(3)
      end

      # Decision 10. D1 has no fight boundary at all, and calling this would
      # advance the tracker's stall counters on a cadence nothing measures.
      it "NEVER calls observe_fight_end" do
        world = world_for(bow, brawling)
        session_for(world).run(6)

        expect(world.trackers.sum(&:fight_ends)).to eq(0)
      end

      it "advances on a tracker :rank_max_exceeded verdict" do
        world = world_for(bow, brawling, bands: { "crossing_rats" => [0, 120] })
        world.script_stint(ranks: { "Bow" => 60 })
        session_for(world).run(2)

        expect(world.event(:verdict).first[:decision]).to eq(:advance)
        expect(world.overlay_calls.map { |call| call.first[:skills] }).to eq([["Bow"], ["Brawling"]])
      end

      # The primary rotation mechanism in D1 (correction C2), not a safety net.
      it "advances after BARREN_LIMIT productive stints with no rank gain" do
        world = world_for(bow, brawling)
        session_for(world).run(4)

        expect(world.overlay_calls.map { |call| call.first[:skills] })
          .to eq([["Bow"], ["Bow"], ["Bow"], ["Brawling"]])
      end

      it "resets the barren count when a rank rises" do
        world = world_for(bow, brawling)
        world.script_stint
             .script_stint
             .script_stint(ranks: { "Bow" => 2 })
             .script_stint
        session_for(world).run(4)

        expect(world.overlay_calls.map { |call| call.first[:skills] }).to all(eq(["Bow"]))
      end

      it "replaces the tracker when the leg changes" do
        world = world_for(bow, brawling)
        session_for(world).run(4)

        expect(world.trackers.size).to eq(2)
      end

      it "rebuilds the itinerary on a :reselect verdict" do
        world = world_for(bow)
        world.script_stint(ranks: { "Evasion" => 10 }).script_stint
        session_for(world).run(2)

        expect(world.itinerary_calls).to eq(2)
        expect(world.event(:verdict).first[:decision]).to eq(:reselect)
      end

      it "resumes on the same leg after a rebuild when that leg still exists" do
        world = world_for(bow, brawling)
        world.queue_itinerary(itinerary(brawling, bow))
        world.script_stint(ranks: { "Evasion" => 10 })
        session_for(world).run(2)

        expect(world.overlay_calls.map { |call| call.first[:skills] }).to eq([["Bow"], ["Bow"]])
      end

      it "resumes at leg one when the previous leg is gone from the rebuild" do
        world = world_for(bow, brawling)
        world.queue_itinerary(itinerary(brawling))
        world.script_stint(ranks: { "Evasion" => 10 })
        session_for(world).run(2)

        expect(world.overlay_calls.map { |call| call.first[:skills] }).to eq([["Bow"], ["Brawling"]])
      end

      # The indices name positions in an array that no longer exists. If
      # `refused` survived the rebuild, the last cycle below would find no
      # playable leg at all and stop with :all_legs_refused instead of
      # hunting leg one again.
      it "clears the refused, failure and barren maps on a rebuild" do
        world = world_for(bow, brawling)
        world.script_stint(stop_reason: nil, elapsed: 5.0)
             .script_stint(stop_reason: nil, elapsed: 5.0)
             .script_stint(ranks: { "Evasion" => 10 })
             .script_stint(stop_reason: nil, elapsed: 5.0)
             .script_stint(stop_reason: nil, elapsed: 5.0)
             .script_stint
        outcome = session_for(world).run(2)

        expect(outcome.stopped).to eq(:budget_spent)
        expect(world.overlay_calls.last.first[:skills]).to eq(["Bow"])
      end

      it "wraps from the last leg back to the first" do
        world = world_for(bow, brawling)
        session_for(world).run(7)

        expect(world.overlay_calls.map { |call| call.first[:skills] })
          .to eq([["Bow"], ["Bow"], ["Bow"], ["Brawling"], ["Brawling"], ["Brawling"], ["Bow"]])
      end
    end

    describe "refusals" do
      # No uc_weapons entry for Bow, so the real LegOverlay reports a
      # :no_weapon_entry gap and the real LegWriter.decide refuses it.
      def gapped_world(*legs)
        world = world_for(*legs)
        world.weapons = { "Brawling" => "knuckles" }
        world
      end

      it "skips only the refused leg on a :gaps result and continues with the next" do
        world = gapped_world(bow, brawling)
        outcome = session_for(world).run(1)

        expect(outcome.stopped).to eq(:budget_spent)
        expect(world.trace.count(:run_stint)).to eq(1)
        expect(world.event(:leg_refused).first[:leg_index]).to eq(0)
      end

      it "reports the gap records for a :gaps refusal" do
        world = gapped_world(bow, brawling)
        session_for(world).run(1)

        payload = world.event(:leg_refused).first
        expect(payload[:reason]).to eq(:gaps)
        expect(payload[:gaps]).to eq([{ skill: "Bow", reason: :no_weapon_entry, detail: {} }])
      end

      # Every leg targets the same path (uc-leg.lic:327), so the refusal is
      # permanent for all of them until a human moves the file.
      it "stops the whole run on a :foreign_file result" do
        world = world_for(bow, brawling)
        world.existing_first_line = "# my own hand-written overlay\n"
        outcome = session_for(world).run(2)

        expect(outcome.stopped).to eq(:foreign_file)
        expect(world.trace).not_to include(:run_stint)
      end

      it "stops with :write_error when write_overlay raises" do
        world = world_for(bow)
        world.write_error = Errno::EACCES.new("/nonexistent/uc.yaml")
        outcome = session_for(world).run(2)

        expect(outcome.stopped).to eq(:write_error)
        expect(world.trace).not_to include(:run_stint)
      end

      # A real LegOverlay invariant guard: an unknown stance policy raises
      # ArgumentError from apply_stances (uc_leg_overlay.rb:283).
      it "stops with :overlay_error when overlay_for raises ArgumentError" do
        world = world_for(leg(["Bow"], policy: :sideways))
        outcome = session_for(world).run(2)

        expect(outcome.stopped).to eq(:overlay_error)
        expect(world.trace).not_to include(:run_stint)
      end

      it "stops with :all_legs_refused when every leg has been refused" do
        world = world_for(bow, brawling)
        world.weapons = {}
        outcome = session_for(world).run(2)

        expect(outcome.stopped).to eq(:all_legs_refused)
      end

      it "never spins when every leg is refused" do
        world = world_for(bow, brawling)
        world.weapons = {}
        session_for(world).run(5)

        expect(world.trace).not_to include(:run_stint)
        expect(world.overlay_calls.size).to eq(2)
        expect(world.checkpoints).to eq(3)
      end
    end

    describe "failures" do
      # `;uc-director run 8` means eight stints that actually hunted, not
      # eight attempts (decision 7).
      it "does not spend budget on a non-productive stint" do
        world = world_for(bow)
        world.script_stint(stop_reason: nil, elapsed: 5.0).script_stint
        outcome = session_for(world).run(1)

        expect(outcome.stints.map(&:classification)).to eq([:failed_to_hunt, :productive])
        expect(outcome.productive).to eq(1)
      end

      it "counts consecutive failures per leg" do
        world = world_for(bow, brawling)
        world.script_stint(stop_reason: nil, elapsed: 5.0)
             .script_stint(stop_reason: nil, elapsed: 5.0)
             .script_stint
        session_for(world).run(1)

        expect(world.event(:leg_skipped).first[:failures]).to eq(UberCombat::Director::MAX_LEG_FAILURES)
      end

      it "skips a leg after MAX_LEG_FAILURES consecutive failures" do
        world = world_for(bow, brawling)
        world.script_stint(stop_reason: nil, elapsed: 5.0)
             .script_stint(stop_reason: nil, elapsed: 5.0)
             .script_stint
        session_for(world).run(1)

        expect(world.event(:leg_skipped).first[:leg_index]).to eq(0)
        expect(world.overlay_calls.last.first[:skills]).to eq(["Brawling"])
      end

      it "resets the failure count after one productive stint" do
        world = world_for(bow)
        world.script_stint(stop_reason: nil, elapsed: 5.0)
             .script_stint
             .script_stint(stop_reason: nil, elapsed: 5.0)
             .script_stint
        outcome = session_for(world).run(2)

        expect(world.event_names).not_to include(:leg_skipped)
        expect(outcome.stints.size).to eq(4)
      end

      it "counts a :timed_out stint as a failure" do
        world = world_for(bow, brawling)
        world.script_stint(outcome: :timeout, stop_reason: nil)
             .script_stint(outcome: :timeout, stop_reason: nil)
             .script_stint
        outcome = session_for(world).run(1)

        expect(outcome.stints.first.classification).to eq(:timed_out)
        expect(world.event(:leg_skipped).first[:leg_index]).to eq(0)
      end

      it "counts a :crashed stint as a failure" do
        world = world_for(bow, brawling)
        world.script_stint(outcome: :error, stop_reason: nil, exit_error: RuntimeError.new("boom"))
             .script_stint(outcome: :error, stop_reason: nil, exit_error: RuntimeError.new("boom"))
             .script_stint
        outcome = session_for(world).run(1)

        expect(outcome.stints.first.classification).to eq(:crashed)
        expect(world.event(:leg_skipped).first[:leg_index]).to eq(0)
      end

      # Script::StartError covers hunting-buddy ALREADY RUNNING, which means
      # something other than the director is driving this character. Retrying
      # would fight it (section 6.4).
      it "stops the run immediately on :launch_refused and does not retry" do
        world = world_for(bow, brawling)
        world.script_stint(outcome: :start_error, stop_reason: nil)
        outcome = session_for(world).run(4)

        expect(outcome.stopped).to eq(:launch_refused)
        expect(world.trace.count(:run_stint)).to eq(1)
      end
    end

    describe "safety" do
      it "stops and calls recover when abort_reason returns :health" do
        world = world_for(bow)
        world.abort_reason = :health
        world.abort_detail = 41
        outcome = session_for(world).run(2)

        expect(outcome.stopped).to eq(:health)
        expect(outcome.detail).to eq(41)
        expect(world.recoveries).to eq([:health])
        expect(world.trace).not_to include(:run_stint)
      end

      it "does not call recover when the run ends on :budget_spent" do
        world = world_for(bow)
        session_for(world).run(1)

        expect(world.recoveries).to be_empty
      end

      it "does not call recover on :all_legs_refused" do
        world = world_for(bow)
        world.weapons = {}
        session_for(world).run(1)

        expect(world.recoveries).to be_empty
      end

      # A partial run's measurements are the only data the UNMEASURED
      # constants in section 8 can ever be tuned from.
      it "returns the stints collected so far when it stops on a safety reason" do
        world = world_for(bow)
        world.script_stint(abort: :spirit, abort_detail: 12)
        outcome = session_for(world).run(4)

        expect(outcome.stopped).to eq(:spirit)
        expect(outcome.stints.size).to eq(1)
        expect(world.event(:stopped).last[:stints].size).to eq(1)
      end
    end
  end
end
