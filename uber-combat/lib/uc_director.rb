# frozen_string_literal: true

# The decision core for uc-director.lic: the D1 hunt spine.
#
#   build itinerary -> choose leg -> write overlay -> run one bounded stint
#   -> measure -> advance or repeat
#
# Spec: notes/uber-combat/42-director-spec.md. Sections 2 (the loop and the
# state table), 3 (the world contract), 4 (the stint), 5 (advancement), 6
# (refusals and failures) and 8 (the constants). Every rule below cites the
# section it comes from, so a disagreement between this file and the spec can
# be checked against the source instead of against memory.
#
# PURE, with one exception, exactly as lib/uc_probe.rb is. Every module method
# here (.timeout_for, .wrap, .next_playable, .gained?, .classify, .record,
# .decide, .resume_index, .safety_stop?) takes plain data and returns plain
# data -- no Lich, no DRC, no DRStats, no Script, no XMLData, no Map, no
# CharSettings and no filesystem anywhere in this file. Session is the one
# class that reaches anything outside it, and it does so through exactly one
# seam: the `world` object its constructor is handed (see Session's own header
# comment). uc-director.lic supplies a real world; every example in
# spec/uc_director_spec.rb supplies a fake one and drives this class the way
# the real script will.
module UberCombat
  module Director
    # The stint length written into the overlay as `:duration:`, in MINUTES --
    # hunting-buddy's own unit, because its loop body is `counter += 1;
    # pause 1` and the check is `counter / 60 >= duration`
    # (hunting-buddy.lic:670-671, :622).
    #
    # Nothing writes this key today: uc-leg.lic calls build(leg) with no
    # duration:, so the guard at uc_leg_overlay.rb:153 never fires and every
    # stint launched from `;uc-leg go` is UNBOUNDED. The director must pass
    # the keyword. 0 is not a substitute -- `(counter / 60) >= 0` is true on
    # the first check.
    #
    # UNMEASURED GUESS (spec section 8, open question (a)). Taken from the
    # live Zurvan-tm.yaml shape and nothing else. Too short and every stint
    # pays the fixed overhead (tannery, restock, travel, the 30 s
    # combat-trainer readiness wait, the walk home) for little hunting; too
    # long and a leg that has stopped teaching burns half an hour before the
    # director notices.
    DURATION_MINUTES = 30

    # Added to the duration to get run_child's timeout. It must cover every
    # cost between run_child starting the child and the child reaching its own
    # duration check, plus the walk home: the bundling-rope tannery trip
    # (hunting-buddy.lic:129), the BLOCKING restock (:130, sell_loot_skip_bank
    # is false in base.yaml), travel to the zone (:231), the up-to-30 s
    # combat-trainer readiness wait (:573-574), the counter-versus-clock
    # overshoot (:622 with :670-671, which makes the stop strictly >= duration
    # and never ==), and DRCT.walk_to(safe_room) (:273).
    #
    # The timeout is not a nicety. DRCT.find_empty_room's inner step is
    # `walk_to(room_id); pause 0.1 until room_id == Room.current.id`
    # (common-travel.rb:323-324) with no timeout, no message and no stop
    # reason, and hunting-buddy walks into it from find_hunting_room?
    # (:231, :389-446). run_child's timeout: is the ONLY thing in the whole
    # stack that breaks that loop.
    #
    # AND IT IS NOT THE WORST CASE. The user reports (2026-09-04) that go2
    # can spin FOREVER trying to reach Riverhaven from Crossing with too few
    # Lirums for the ferry and too little Swimming to cross. That defeats
    # every progress-based detector in the stack, because the character keeps
    # MOVING: walk_to resets its own 90-second stall timer whenever the room
    # changes (common-travel.rb:253), so walk_to never returns, and
    # find_empty_room is never even reached. Only a bound on TOTAL elapsed
    # time catches a loop that makes progress. That is this constant.
    #
    # NOT a scheduler, and not a second opinion on the hunt. hunting-buddy
    # bounds its own hunting at :622, but that check lives INSIDE hunt
    # (:576-670) -- the tannery trip (:129), the blocking restock (:130),
    # travel (:231) and the walk home (:273) are all untimed. This is the
    # envelope around those, so it should be generous rather than tight: a
    # stint that ends normally never touches it.
    #
    # 1800 (user, 2026-09-04), raised from 900. Measured round-trip travel to
    # endrus_serpents alone is about 600 s (5 minutes each way, ferry
    # included), which left 300 s of the old value for the tannery trip and
    # the restock, and neither has ever been measured.
    #
    # The cost of a large value is bounded and known: a wedged leg burns
    # duration + slack per attempt, and MAX_LEG_FAILURES attempts before the
    # leg is skipped. At these values that is two hours to abandon one
    # unreachable leg. Tightening the loop is D5's job, not this constant's.
    STINT_SLACK_SECONDS = 1800

    # Seconds. A SECONDARY catch only, applied only when the stop reason is
    # nil (classification rule 5).
    #
    # Decision 7's recommended 60 is REJECTED, and so is any other value used
    # as a primary discriminator: every no-hunt path in hunting-buddy runs
    # AFTER the blocking restock trip at :130, so a stint that never hunts at
    # all still pays a full town round trip -- minutes, not seconds. Elapsed
    # time cannot separate "hunted" from "did not hunt" at any threshold
    # (spec correction C5). This value only catches the instant-return cases.
    #
    # UNMEASURED GUESS (open question (e)).
    MIN_PRODUCTIVE_STINT = 120

    # Consecutive PRODUCTIVE stints on one leg with no rank increase in any of
    # the leg's skills before the director advances the leg itself.
    #
    # This counter belongs to the DIRECTOR, not to LegTracker. README rule 6
    # and uc_leg_tracker.rb:7-10 both state that the tracker owns no cadence,
    # and a per-stint counter IS a cadence, so putting it there would break
    # the one rule that makes the tracker testable without a game runtime.
    #
    # It is the PRIMARY rotation mechanism in D1, not a safety net (spec
    # correction C2). D1 never calls observe_fight_end, so the tracker's
    # no_gain backstop can never fire, and its mindlock backstop is sampled
    # after hunting-buddy has already walked home and drained mindstate into
    # ranks. That leaves `outgrown` as the tracker's only realistic :advance,
    # and for a freshly selected leg that can be many hours of hunting away --
    # long enough for the director to spin on leg 1 while legs 2..N starve.
    #
    # UNMEASURED GUESS (open question (f)). At DURATION_MINUTES = 30 this is
    # at least 90 minutes of measured, productive hunting with zero rank
    # movement across every skill on the leg before the leg is set aside.
    BARREN_LIMIT = 3

    # Consecutive non-productive stints on one leg before the leg is refused
    # for the rest of the run. One failure can be a transient occupied zone;
    # two is a pattern (decision 7's "two consecutive failures").
    MAX_LEG_FAILURES = 2

    # PRODUCTIVE stints one leg may run before the director moves on, whether
    # or not anything says the leg is finished.
    #
    # ONE (user, 2026-09-05). Every productive stint hands over, so the
    # itinerary is a plain round robin and no leg can starve another.
    #
    # The two ways a leg slows down are both NORMAL, and neither is a reason
    # to hold the character there:
    #
    #   A skill trains more slowly as it approaches the upper bound of the
    #   creature it trains on. The character eventually ages out of that
    #   creature, moves on, and speeds up again. Waiting for that inside one
    #   leg starves every other leg meanwhile.
    #
    #   More skills on a leg means less experience per skill in a run of it.
    #   That is arithmetic, not a fault, and the answer is a limit on how many
    #   skills a leg may carry, not more stints on the leg.
    #
    # BARREN_LIMIT cannot do this job. It counts only stints that gained
    # NOTHING, so a leg gaining a rank every stint resets it every time and
    # holds the character until `outgrown` fires. Zurvan's leg 1 was Targeted
    # Magic at rank 84 in a 50-90 zone: six ranks of productive stints before
    # its only exit, while legs 2 and 3 held skills at ranks 11 to 30 that
    # would never have run at all.
    #
    # CONSEQUENCE, stated plainly: at 1 this fires on every productive stint,
    # so it reaches its limit before BARREN_LIMIT, before `outgrown` and
    # before `mindlocked` can decide anything. LegTracker no longer influences
    # ADVANCEMENT in D1 at all; its remaining job is :reselect, which still
    # rebuilds the itinerary when a defence rank rises. The other rules are
    # kept because they are correct and tested, and they become live again the
    # moment this number is raised.
    MAX_STINTS_PER_LEG = 1

    # The stop reasons that mean the CHARACTER is in trouble, as opposed to
    # the run merely being over or the configuration being wrong. Only these
    # run the recovery (world.recover -> gosafe). The list is exactly the
    # rungs of the adapter's abort ladder (spec section 7.1); :budget_spent,
    # :no_legs, :all_legs_refused, :foreign_file, :write_error,
    # :overlay_error and :launch_refused are deliberately NOT here -- walking
    # a healthy character to its safe room because an itinerary came back
    # empty would be a surprise, not a rescue.
    SAFETY_STOPS = [:dead, :health, :spirit].freeze

    # ------------------------------------------------------------- plugins
    #
    # The plugin system, in the shape the dr-scripts wiki page
    # "Implementing a Plugin System" describes and combat-trainer.lic and
    # hunting-buddy.lic already ship. See:
    # https://github.com/elanthia-online/dr-scripts/wiki/Implementing-a-Plugin-System
    #
    # A plugin is any object with one or more hook methods. uc-director.lic
    # loads scripts/custom/uc-director-plugin-*.rb in sorted order, and each
    # file calls UcDirector.register_plugin(instance), which lands here.
    #
    # CLASS-LEVEL DISPATCH, per the wiki's section 4 rule: the hooks are fired
    # by Session, which holds no reference to the UcDirector host. The host
    # reaches Session through the `host:` keyword instead, and every hook
    # receives it as its first argument.
    #
    # THE HOOK CATALOG. Nothing else fires. A decision hook's :break stops the
    # run with the reason :plugin_break, which is NOT a safety stop.
    #
    #   after_initialize(host)                        notify   UcDirector#initialize
    #   before_run(host, budget:, unit:)              notify   start of Session#run
    #   itinerary_built(host, itinerary:, cycle:)     notify   every build and rebuild
    #   before_stint(host, leg_index:, leg:)          decision after :leg_selected,
    #                                                          before the overlay write
    #   after_stint(host, stint:, leg_index:, leg:)   decision after the post-stint
    #                                                          snapshot and the record
    #   after_run(host, reason:, stints:)             notify   after the :stopped announce
    #   cleanup(host)                                 notify   uc-director.lic before_dying
    #
    # THE HOST DOES NOT TIME OUT A HOOK. A plugin that starts a script must
    # bound it itself with Script.run_child(name, timeout:).
    #
    # `||=`, NOT `=`. Every uc-* script `load`s its libs, so a plain assignment
    # would empty the registry of a director that is already running the moment
    # anything else loads this file. The loader in uc-director.lic clears the
    # registry itself before it loads the plugin files.
    @registered_plugins ||= []
    @plugin_error_handler ||= nil

    class << self
      # @return [Array<Object>] plugin instances, in registration order.
      attr_reader :registered_plugins

      # A callable taking (plugin, hook_name, error), or nil to swallow
      # silently. The pure core cannot echo, so the adapter installs one that
      # echoes under $debug_mode_ucdirector.
      attr_accessor :plugin_error_handler

      def register_plugin(plugin)
        @registered_plugins << plugin
      end

      # Decision dispatch. Returns the FIRST non-nil answer and stops polling.
      # false IS an answer, so callers must test .nil?, never truthiness.
      def fire_hook(hook_name, *args, **kwargs)
        registered_plugins.each do |plugin|
          next unless plugin.respond_to?(hook_name)

          begin
            result = plugin.send(hook_name, *args, **kwargs)
            return result unless result.nil?
          rescue StandardError => e
            report_plugin_error(plugin, hook_name, e)
          end
        end
        nil
      end

      # Notification dispatch. Every implementing plugin runs; returns are
      # ignored.
      def notify_hook(hook_name, *args, **kwargs)
        registered_plugins.each do |plugin|
          next unless plugin.respond_to?(hook_name)

          begin
            plugin.send(hook_name, *args, **kwargs)
          rescue StandardError => e
            report_plugin_error(plugin, hook_name, e)
          end
        end
        nil
      end

      private

      # The handler itself is guarded too: a broken reporter must not turn one
      # swallowed plugin error into a crashed run.
      def report_plugin_error(plugin, hook_name, error)
        plugin_error_handler&.call(plugin, hook_name, error)
      rescue StandardError
        nil
      end
    end

    # The return shape of world.run_stint, built by the ADAPTER so the pure
    # core never sees a Script object (spec section 3.2). It is declared here
    # rather than in uc-director.lic for the reason every other shared shape
    # in this project is declared in lib/: spec/uc_lic_loads_spec.rb checks
    # that a script loads a lib for every UberCombat constant it names, and a
    # Struct the adapter defines for itself could drift from what .classify
    # reads without anything noticing.
    #
    # outcome: :completed (run_child returned normally), :start_error
    #   (Script::StartError, script.rb:354), :timeout (Script::TimeoutError,
    #   :358) or :error (anything else raised).
    # stop_reason: hunting-buddy's @hunt_stop_reason, or nil. The adapter sets
    #   $HUNTING_BUDDY = nil before every launch and then tests the OBJECT,
    #   never the reason -- NilClass#method_missing is patched to return nil
    #   (nilclass.rb:9-11), so a stale global from a previous run in the same
    #   Lich process is otherwise indistinguishable from a real nil.
    # completed_successfully: child.completed_successfully? (script.rb:1878).
    #   Carried for the report only. It is NOT a classification input,
    #   because hunting-buddy's bad-zone path is a Kernel `exit`, which
    #   Script.__execute records as a SUCCESSFUL exit (script.rb:619-621) --
    #   byte-for-byte identical to a clean 30-minute stint by the Script
    #   handle alone (spec correction C7).
    # exit_error: child.exit_error (script.rb:342), or nil.
    Launch = Struct.new(:outcome, :stop_reason, :completed_successfully, :exit_error,
                        keyword_init: true)

    # One measured stint. `before` and `after` are world.snapshot's return
    # shape, Hash{String skill => {rank: Float, mindstate: Integer}}, taken
    # around run_stint and nothing else.
    Stint = Struct.new(:leg_index, :leg, :started_at, :ended_at, :elapsed,
                       :before, :after, :stop_reason, :outcome, :classification,
                       keyword_init: true)

    # run_child's timeout, in seconds. Strictly greater than the duration
    # alone -- a timeout equal to the duration would fire on every well-behaved
    # stint, because hunting-buddy's own stop is `counter / 60 >= duration`
    # counted in loop iterations rather than on a clock.
    def self.timeout_for(minutes)
      (minutes * 60) + STINT_SLACK_SECONDS
    end

    # The itinerary IS the rotation. ZonePicker#build_legs consumes its input
    # sorted `sort_by { |skill| -ranks[skill] }` greedily left to right
    # (uc_zone_picker.rb:122-140), so legs are already emitted in descending
    # leading-skill rank order and the end wraps back to the start with no
    # separate ordering step (spec section 5.4).
    def self.wrap(index, size)
      return 0 if size.zero?

      index % size
    end

    # The next index at or after `index` that has not been refused for this
    # run, wrapping once. nil means every leg is refused, which the caller
    # must turn into a STOP: a loop that kept selecting from an itinerary in
    # which every leg is refused would spin at full speed with no game contact
    # at all (spec section 6.5).
    def self.next_playable(index, size, refused)
      return nil if size.zero?

      size.times do |offset|
        candidate = wrap(index + offset, size)
        return candidate unless refused.key?(candidate)
      end

      nil
    end

    # Did this stint actually teach anything? A strict RANK increase in at
    # least one of the leg's own skills. Mindstate is deliberately not enough:
    # mindstate is the pending experience that has not become rank yet, and a
    # leg that fills mindstate for three stints without ever converting a rank
    # is exactly the case BARREN_LIMIT exists to notice.
    #
    # rank_of is (getrank + getmodrank) / 2.0 (uc_character.rb:90-92), so a
    # non-refreshable buff landing or expiring mid-stint moves the value with
    # no training behind it. A false "gain" only delays advancement by one
    # stint; a false "no gain" needs BARREN_LIMIT in a row to matter.
    def self.gained?(stint)
      stint.leg[:skills].any? { |skill| stint.after[skill][:rank] > stint.before[skill][:rank] }
    end

    # Did anything at all move on the leg, in either direction? Movement, not
    # gain: mindstate FALLS while experience absorbs into ranks during the
    # walk home (uc_leg_tracker.rb:47-50), and a fall is still evidence that
    # there was experience to absorb. Used only by classification rule 6.
    def self.moved?(skills, before, after)
      skills.any? do |skill|
        after[skill][:rank] != before[skill][:rank] ||
          after[skill][:mindstate] != before[skill][:mindstate]
      end
    end

    # The director measures. It does not trust reports (spec section 4.4).
    #
    # Order is load-bearing:
    #   1 :launch_refused -- Script::StartError. Never retried (section 6.4).
    #   2 :timed_out      -- our own deadline fired and the child was torn down.
    #   3 :crashed        -- run_child raised something else, or the child
    #                        recorded an exit_error.
    #   4 :productive     -- a NON-NIL stop reason. @hunt_stop_reason is only
    #                        ever assigned inside `hunt` (hunting-buddy.lic:576
    #                        and below), so a non-nil value is proof that the
    #                        hunt loop actually RAN. That is a claim about
    #                        control flow, not about why the hunt stopped, and
    #                        it is the only use made of the reason.
    #   5 :failed_to_hunt -- nil reason and a stint too short to have hunted.
    #   6 :failed_to_hunt -- nil reason and nothing on the leg moved at all.
    #   7 :productive     -- nil reason, but the character measurably changed.
    #
    # Rules 5 and 6 exist ONLY for rule 4's nil case -- the eleven exit paths
    # in hunting-buddy that never reach :576 and so leave the reason nil
    # (spec correction C7), including the bad-zone Kernel `exit` at :386 that
    # the Script handle reports as a clean run.
    #
    # Honest limitation (open question (e)): rules 5 and 6 misclassify in both
    # directions. A no-hunt stint that began with pending mindstate shows
    # movement during travel and reads :productive, costing one budget unit; a
    # genuinely productive stint that hit the deadline before any measurable
    # movement reads :failed_to_hunt, and it takes MAX_LEG_FAILURES of those in
    # a row before the leg is skipped, with the skip announced. D2's
    # after_hunt hook removes the ambiguity entirely -- it fires only from
    # inside `hunt` (hunting-buddy.lic:674) and carries the loop's own counter.
    def self.classify(launch:, elapsed:, before:, after:, skills:)
      return :launch_refused if launch.outcome == :start_error
      return :timed_out if launch.outcome == :timeout
      return :crashed if launch.outcome == :error || !launch.exit_error.nil?
      return :productive unless launch.stop_reason.nil?
      return :failed_to_hunt if elapsed < MIN_PRODUCTIVE_STINT
      return :failed_to_hunt unless moved?(skills, before, after)

      :productive
    end

    # Assembles one Stint from the two snapshots, the two timestamps and the
    # Launch. Pure: it never asks the clock itself, so every example in the
    # spec is deterministic (the same rule Probe.record states for its own
    # :at field).
    def self.record(leg_index:, leg:, started_at:, ended_at:, before:, after:, launch:)
      elapsed = ended_at - started_at
      Stint.new(leg_index: leg_index, leg: leg, started_at: started_at, ended_at: ended_at,
                elapsed: elapsed, before: before, after: after,
                stop_reason: launch.stop_reason, outcome: launch.outcome,
                classification: classify(launch: launch, elapsed: elapsed, before: before,
                                         after: after, skills: leg[:skills]))
    end

    # Verdict precedence (spec section 5.4). The order is deliberate.
    #
    # THE BARREN BACKSTOP MUST OUTRANK :reselect. LegTracker's :reselect is
    # sticky (uc_leg_tracker.rb:130-137) and a rebuild resets the director's
    # per-index counters, so if :reselect were checked first a character whose
    # defence ranks keep rising would rebuild, reset barren, hunt, rebuild
    # again -- and the barren backstop would never reach its limit. That is a
    # livelock in which a barren leg is never advanced.
    #
    # THE STINT CAP MUST ALSO OUTRANK :reselect, for the same shape of reason.
    # A reselect rebuilds and then resumes the leg with the same skills
    # (resume_index below), which would return to the very leg the cap just
    # ruled had taken its turn -- and a rebuild resets the per-index counters,
    # so the cap would restart from zero each time. A character whose defences
    # are rising would hold leg 1 forever.
    #
    # Returns a Decision, not a bare Symbol, so the report can say WHY a leg
    # ended. Four rules now reach :advance and they mean different things to a
    # person reading the log: outgrown is success, mindlock is success, barren
    # is a zone that stopped paying, and the cap is a deliberate hand-off.
    #
    # verdict may be nil so the function is total; the loop always has one.
    Decision = Struct.new(:action, :reason, keyword_init: true)

    def self.decide(verdict, barren_count, limit, leg_stints = 0, cap = MAX_STINTS_PER_LEG)
      return Decision.new(action: :advance, reason: verdict.reason) if verdict && verdict.status == :advance
      return Decision.new(action: :advance, reason: :no_gain_limit) if barren_count >= limit
      return Decision.new(action: :advance, reason: :stint_cap) if cap && leg_stints >= cap
      return Decision.new(action: :reselect, reason: verdict.reason) if verdict && verdict.status == :reselect

      Decision.new(action: :continue, reason: nil)
    end

    # Has the run's budget been spent? Pure, so every unit is testable without
    # a session. :next ignores the budget: it is one productive stint by
    # definition.
    #
    # An unknown unit spends IMMEDIATELY rather than running forever. A typo
    # in the argument parser must not turn a bounded request into an unbounded
    # hunt; stopping at zero stints is obvious and harmless, and the adapter
    # rejects an unknown mode before it ever reaches here.
    def self.budget_spent?(unit, budget, productive, cycles)
      case unit
      when :stints then productive >= budget
      when :cycles then cycles >= budget
      when :next then productive >= 1
      else true
      end
    end

    # Where to continue after a :reselect rebuild: the index of the first leg
    # whose skills match the leg we were just on, or 0 when that leg is gone.
    #
    # Matched on the SKILLS array, not the zone key: a rebuild triggered by a
    # defence rank rise is precisely the case where the same skills get routed
    # to a BETTER zone, and keying on the zone would resume at 0 every time.
    # Decision 12 does not say where to resume (open question (h)); resetting
    # to 0 on every reselect starves the tail of the itinerary on a character
    # whose defences are rising, which is why this exists.
    def self.resume_index(itinerary, previous_leg)
      found = itinerary.legs.index { |leg| leg[:skills] == previous_leg[:skills] }
      found || 0
    end

    # Only a SAFETY stop runs the recovery. See SAFETY_STOPS.
    def self.safety_stop?(reason)
      SAFETY_STOPS.include?(reason)
    end

    # ------------------------------------------------------- skill history
    #
    # The one thing the director remembers across runs, and the only input
    # `;uc-director next` orders its legs by. Two maps of Unix-second Integers:
    #
    #   productive: skill name -> when that skill last rode a PRODUCTIVE stint
    #   failed:     zone key   -> when a stint in that zone last failed to hunt
    #
    # "Productive" is the stint classification, not a rank gain per skill
    # (user, 2026-09-17): every skill on a productive leg is stamped, whether
    # or not that one skill moved.
    #
    # Written by every mode, so a skill trained in `run 8` is not picked again
    # by the next `next`. A HINT, never a fact, in the D4 sense: it decides only
    # which leg to try first. The itinerary itself is still re-derived from
    # live skills on every start.
    #
    # Accepts whatever the world handed back and returns both maps, so a world
    # that has never saved anything reads as an empty history.
    def self.normalize_history(history)
      history ||= {}
      { productive: (history[:productive] || {}).to_h, failed: (history[:failed] || {}).to_h }
    end

    # A NEW history with this stint folded in. Pure: the time comes from the
    # stint's own ended_at, never from a clock.
    #
    # A failure is stamped against the ZONE, not the skills. What fails a stint
    # is almost always the zone (unreachable, premium-gated, occupied, a travel
    # wedge), and it leaves the skills' own staleness untouched: a failed leg
    # goes behind the others without its skills being counted as trained.
    #
    # :launch_refused is not a leg failure. It means something else is driving
    # the character, and the loop stops on it before this is ever reached.
    def self.remember(history, stint)
      at = stint.ended_at.to_i
      case stint.classification
      when :productive
        stamps = stint.leg[:skills].to_h { |skill| [skill, at] }
        { productive: history[:productive].merge(stamps), failed: history[:failed] }
      when :launch_refused
        history
      else
        { productive: history[:productive], failed: history[:failed].merge(stint.leg[:zone_key] => at) }
      end
    end

    # The leg's most neglected skill, as { skill:, at: }. `at` is nil for a
    # skill with no productive stint on record, and nil sorts before every
    # stamp: never trained is the stalest there is. Ties keep the leg's own
    # skill order.
    def self.stalest_skill(leg, history)
      leg[:skills].map { |skill| { skill: skill, at: history[:productive][skill] } }
                  .min_by { |entry| entry[:at] || -Float::INFINITY }
    end

    # When this leg was last "touched": its stalest skill's stamp, or its
    # zone's last failure if that is more recent. nil means never touched.
    #
    # The failure takes part through max, so a leg that failed moves to the
    # back as if it had just been hunted, and comes round again once the
    # other legs have had their turn. Leaving failures out would hand the
    # first place to a leg that can never hunt, forever, because a leg that
    # never hunts never gets a productive stamp.
    def self.leg_touched_at(leg, history)
      [stalest_skill(leg, history)[:at], history[:failed][leg[:zone_key]]].compact.max
    end

    # Leg INDICES, stalest first (user, 2026-09-17). The leg holding the one
    # skill trained longest ago wins; a leg never touched beats every stamp.
    # Ties keep itinerary order, which is descending leader rank
    # (see .wrap), so on a first-ever run `next` takes the leg `run 1` would.
    def self.stalest_order(legs, history)
      legs.each_index.sort_by { |index| [leg_touched_at(legs[index], history) || -Float::INFINITY, index] }
    end

    # The first index in `order` not refused for this run, or nil.
    def self.first_unrefused(order, refused)
      order.find { |index| !refused.key?(index) }
    end

    # The driver. Everything above this class is pure; this class runs the
    # loop of 42-director-spec.md section 2, and its ONLY contact with the
    # game -- indeed with anything outside this file -- is the injected
    # `world`. uc-director.lic supplies a real one built on Script, DRC,
    # DRStats, ZonePicker, LegOverlay, LegWriter and LegTracker; every example
    # in spec/uc_director_spec.rb supplies a fake one.
    #
    # world contract (spec section 3.1). NOTHING may be added to this list
    # without the spec being changed first:
    #   world.now                       -> Time. Elapsed arithmetic only,
    #                                      never memoised.
    #   world.checkpoint                -> nil. Script.current. The ONLY
    #                                      pause-honouring call in the loop:
    #                                      neither `pause` nor DRC.message
    #                                      routes through Script.current, so
    #                                      without this `;p uc-director` would
    #                                      have no effect at all (correction
    #                                      C3).
    #   world.abort_reason              -> Symbol or nil. The safety ladder.
    #   world.abort_detail              -> the value that tripped the ladder,
    #                                      or nil. For the report only.
    #   world.build_itinerary           -> ZonePicker::Itinerary
    #                                      (legs, unplaced, unresolved_premium)
    #   world.overlay_for(leg, duration:) -> LegOverlay::Overlay(settings:,
    #                                      gaps:). May raise ArgumentError.
    #   world.write_overlay(overlay)    -> LegWriter::Result(written:, path:,
    #                                      reason:). May raise on real I/O
    #                                      failure.
    #   world.tracker_for(leg)          -> LegTracker for that leg's zone and
    #                                      skills.
    #   world.snapshot(skills)          -> Hash{String => {rank:, mindstate:}},
    #                                      one entry per skill asked for.
    #   world.run_stint(timeout)        -> Launch (see above).
    #   world.recover(reason)           -> nil. gosafe under its own timeout.
    #   world.load_history              -> { productive: {skill => Integer},
    #                                      failed: {zone_key => Integer} }.
    #                                      Read once per run. See .remember.
    #   world.save_history(history)     -> nil. After every stint that was
    #                                      not :launch_refused. Must not raise.
    #   world.announce(event, payload)  -> nil. Presentation only; the core
    #                                      never reads anything back from it.
    #
    # world.overlay_path and world.existing_first_line are part of the section
    # 3.1 contract but are used only by the adapter's plan mode, which prints
    # the PREDICTED write decision from the pure LegWriter.decide before a
    # single byte is written. The core never calls either.
    class Session
      # stopped: the Symbol the run ended on. :budget_spent, :no_legs,
      #   :all_legs_refused, :launch_refused, :foreign_file, :write_error,
      #   :overlay_error, :plugin_break, or one of SAFETY_STOPS.
      # detail: world.abort_detail at the moment the run ended, for the
      #   report. nil unless the safety ladder tripped.
      # stints: every Stint measured, in order. ALWAYS returned, even on an
      #   abort -- a partial run's measurements are the only data the
      #   UNMEASURED constants in section 8 can ever be tuned from, so they
      #   are never thrown away (the same rule Probe::Session::Outcome states
      #   for its own records).
      # productive: how many of those spent a budget unit.
      Outcome = Struct.new(:stopped, :detail, :stints, :productive, keyword_init: true)

      # The two rotation limits are injectable ONLY so each can be exercised
      # on its own. Production always takes the defaults.
      #
      # They are not independent at the shipped values: MAX_STINTS_PER_LEG is
      # 2 and BARREN_LIMIT is 3, and the cap counts every productive stint
      # while barren counts only the gainless ones, so the cap ALWAYS reaches
      # its limit first and the barren backstop can never fire. Barren is not
      # dead code -- it is the earlier exit whenever the cap is raised above
      # it -- but at these numbers the cap subsumes it, which is deliberate:
      # a leg that taught nothing for two stints and a leg that taught well
      # for two stints should both hand over, and for the same reason.
      # duration_minutes is injectable for a real reason, not only for tests:
      # a character can set hunt_duration_minutes to watch a whole cycle in
      # minutes instead of hours. The stint TIMEOUT deliberately does not
      # shrink with it -- it bounds the untimed travel and restock around the
      # hunt, and those cost the same at five minutes as at fifty.
      # host: the object every plugin hook receives first. uc-director.lic
      # passes its UcDirector, so a plugin can reach $UC_DIRECTOR's world.
      # Defaults to the session itself, which is what the specs use.
      def initialize(world, barren_limit: BARREN_LIMIT, stint_cap: MAX_STINTS_PER_LEG,
                     duration_minutes: DURATION_MINUTES, host: nil)
        @world = world
        @host = host || self
        @barren_limit = barren_limit
        @stint_cap = stint_cap
        @duration_minutes = duration_minutes || DURATION_MINUTES
      end

      # The duration actually in force, so a caller can report it rather than
      # print the constant and be wrong for a character that overrode it.
      attr_reader :duration_minutes

      # budget: how many PRODUCTIVE stints to run. `;uc-director run 8` means
      # eight stints that actually hunted, not eight attempts -- a
      # non-productive stint never spends a unit (decision 7).
      # unit: :stints counts stints that actually hunted. :cycles counts
      # completed passes through the itinerary.
      #
      # They are NOT interchangeable, even though MAX_STINTS_PER_LEG = 1 makes
      # one stint one leg today. A cycle is however many legs the itinerary
      # currently has, and that number moves on its own: the skills-per-leg cap
      # splits a cluster as a character's ranks spread, and a rebuild can
      # return a different count. So a stint budget chosen to mean "one cycle"
      # silently stops meaning it, which is the whole reason :cycles exists.
      #
      # :next runs ONE productive stint on the leg holding the stalest skill
      # (.stalest_order). The order is computed once, from the first build,
      # and a failed leg falls through to the next leg in it after
      # MAX_LEG_FAILURES. It never advances, reselects or rebuilds: the run
      # ends on the first productive stint, so none of that could matter.
      def run(budget, unit: :stints)
        productive = 0
        cycles = 0
        stopped = nil
        Director.notify_hook(:before_run, @host, budget: budget, unit: unit)
        itinerary = build_itinerary(cycles)
        return finish(:no_legs, [], 0) if itinerary.legs.empty?

        history = Director.normalize_history(@world.load_history)
        order = nil
        if unit == :next
          order = Director.stalest_order(itinerary.legs, history)
          @world.announce(:next_order, itinerary: itinerary, order: order, history: history)
        end

        index    = 0
        refused  = {}          # leg index -> Symbol reason; the leg is out for this run
        failures = Hash.new(0) # leg index -> consecutive failed stints
        barren   = Hash.new(0) # leg index -> consecutive productive stints with no rank gain
        # leg index -> productive stints on this leg since it last became
        # current. Reset on every advance and discarded on every rebuild,
        # because both make the index mean a different leg.
        leg_stints = Hash.new(0)
        tracker  = nil
        stints   = []

        until Director.budget_spent?(unit, budget, productive, cycles)
          # C3. The one call in the whole loop that a `;p uc-director`
          # actually blocks on.
          @world.checkpoint

          # Decision 14: BEFORE the stint, never in a death handler. A
          # before_dying cannot launch gosafe at all -- Script.__begin_start
          # returns :shutdown once shutdown has started (script.rb:743).
          if (reason = @world.abort_reason)
            stopped = reason
            break
          end

          index = order ? Director.first_unrefused(order, refused) : next_playable(index, itinerary, refused)
          if index.nil?
            stopped = :all_legs_refused
            break
          end

          leg = itinerary.legs[index]
          timeout = Director.timeout_for(@duration_minutes)
          @world.announce(:leg_selected, leg_index: index, count: itinerary.legs.size, leg: leg,
                                         duration: @duration_minutes, timeout: timeout)

          # Before the write, so a plugin that stops the run never leaves a
          # fresh overlay behind for a hunt that will not happen.
          if Director.fire_hook(:before_stint, @host, leg_index: index, leg: leg) == :break
            stopped = :plugin_break
            @world.announce(:plugin_break, hook: :before_stint, leg_index: index, leg: leg)
            break
          end

          write = write_overlay(leg)
          case write.first
          when :refused # :gaps -- this leg only, and retrying without a profile edit refuses identically
            refused[index] = write[1]
            # The tracker belongs to a leg we are no longer going to hunt.
            # Dropping it here is what keeps the next cycle, which will
            # select a DIFFERENT index, from measuring that leg with this
            # leg's tracker.
            tracker = nil
            @world.announce(:leg_refused, leg_index: index, leg: leg, reason: write[1], gaps: write[2])
            next
          when :fatal # :foreign_file, :write_error, :overlay_error -- every leg targets the same path
            stopped = write[1]
            break
          end

          # Built AFTER the write, not before it: a leg refused for :gaps
          # must never leave a tracker behind (see the :refused branch).
          tracker ||= @world.tracker_for(leg)

          # Decision 15: the pre-stint snapshot is taken AFTER the checkpoint,
          # so a director paused for an hour between cycles does not measure
          # the next stint against ranks read before the pause. Character
          # reads are live and free (uc_character.rb:6-8), so re-snapshotting
          # costs nothing.
          before  = @world.snapshot(leg[:skills])
          started = @world.now
          launch  = @world.run_stint(timeout)
          ended   = @world.now
          # Immediately, before any announce: mindstate drains into ranks
          # while the character stands there, so every line printed first is
          # measurement lost.
          after   = @world.snapshot(leg[:skills])

          stint = Director.record(leg_index: index, leg: leg, started_at: started, ended_at: ended,
                                  before: before, after: after, launch: launch)
          stints << stint
          @world.announce(:stint_ended, stint: stint)

          # Section 6.4: Script::StartError covers a missing file, a Lich
          # shutdown, a construction error and -- the important one --
          # hunting-buddy ALREADY RUNNING. None of those is fixed by
          # retrying, and the last means something other than the director is
          # driving this character. Retrying would fight it.
          if stint.classification == :launch_refused
            stopped = :launch_refused
            break
          end

          # Before after_stint, so a town trip that breaks the run cannot lose
          # the record of the stint that already happened.
          history = Director.remember(history, stint)
          @world.save_history(history)

          # AFTER the launch_refused stop, because that stop means something
          # else drives the character, and a town trip would fight it. AFTER
          # the snapshot, because mindstate drains while a plugin works. Fired
          # for every other classification: a timed-out or failed stint can
          # still come home carrying loot.
          if Director.fire_hook(:after_stint, @host, stint: stint, leg_index: index, leg: leg) == :break
            # The stint already happened. Count it, or the report under-states
            # the hunting that was done.
            productive += 1 if stint.classification == :productive
            stopped = :plugin_break
            @world.announce(:plugin_break, hook: :after_stint, leg_index: index, leg: leg)
            break
          end

          unless stint.classification == :productive
            failures[index] += 1
            if failures[index] >= MAX_LEG_FAILURES
              refused[index] = :failed_to_hunt
              @world.announce(:leg_skipped, leg_index: index, leg: leg, failures: failures[index])
              tracker = nil
              index   = Director.wrap(index + 1, itinerary.legs.size)
            end
            next # decision 7: a failed stint does NOT spend the budget
          end

          failures[index] = 0
          productive     += 1
          barren[index]   = Director.gained?(stint) ? 0 : barren[index] + 1

          # One leg, and it hunted. Nothing below can change what happens next.
          break if unit == :next

          # Decision 10: exactly one observe_tick per PRODUCTIVE stint, and
          # observe_fight_end is NEVER called -- D1 has no fight boundary, so
          # there is no seam that fires at the end of a fight until D2's
          # plugin sits on hunting-buddy.lic:582.
          leg_stints[index] += 1
          verdict  = tracker.observe_tick
          decision = Director.decide(verdict, barren[index], @barren_limit,
                                     leg_stints[index], @stint_cap)
          @world.announce(:verdict, leg_index: index, verdict: verdict, decision: decision)

          case decision.action
          when :advance
            barren[index]     = 0
            leg_stints[index] = 0
            tracker = nil
            index   = Director.wrap(index + 1, itinerary.legs.size)

            # A WRAP MEANS EVERY LEG HAS HAD ITS TURN, so rebuild before
            # starting the next cycle (user, 2026-09-05). The picker reads
            # live skills, so a cycle's worth of hunting can have moved a leg
            # past its zone, opened a better zone, or changed a stance policy
            # -- and without this the run would keep enacting an itinerary
            # computed from the ranks the character had hours ago. Rebuilding
            # per LEG was considered and is not what was asked for: it would
            # throw away the cycle position on every advance.
            if index.zero?
              cycles += 1
              itinerary = build_itinerary(cycles)
              if itinerary.legs.empty?
                stopped = :no_legs
                break
              end

              # Index 0 of the NEW itinerary, not resume_index: a completed
              # cycle is finished business, and build_legs emits legs in
              # descending leader rank, so 0 is the top of a fresh rotation.
              refused    = {}
              failures   = Hash.new(0)
              barren     = Hash.new(0)
              leg_stints = Hash.new(0)
            end
          when :reselect
            itinerary = build_itinerary(cycles)
            if itinerary.legs.empty?
              stopped = :no_legs
              break
            end

            # Every index-keyed map names a position in an array that no
            # longer exists, so all three are discarded rather than carried
            # across the rebuild.
            index      = Director.resume_index(itinerary, leg)
            refused    = {}
            failures   = Hash.new(0)
            barren     = Hash.new(0)
            leg_stints = Hash.new(0)
            tracker    = nil
          end
        end

        stopped ||= :budget_spent
        @world.recover(stopped) if Director.safety_stop?(stopped)
        finish(stopped, stints, productive)
      end

      private

      # Kept as a method rather than an inline Director.next_playable call so
      # the loop reads as one step per state-table row (spec section 2.3).
      def next_playable(index, itinerary, refused)
        Director.next_playable(index, itinerary.legs.size, refused)
      end

      # Every build goes through here, so itinerary_built can never miss one.
      # cycle is the count of COMPLETED passes: 0 for the first build, and the
      # same value for a :reselect rebuild inside a pass.
      def build_itinerary(cycles)
        itinerary = @world.build_itinerary
        Director.notify_hook(:itinerary_built, @host, itinerary: itinerary, cycle: cycles)
        itinerary
      end

      # The only place in the pure core that calls two world methods in
      # sequence, and the only place that turns a LegWriter::Result into a
      # loop decision (spec section 6.2).
      #
      # Returns [:ok], [:refused, :gaps, gaps] or [:fatal, reason].
      #
      # DEVIATION from the spec's section 6.2 listing, which returns a bare
      # [:refused, reason]. The :leg_refused announce is required by section
      # 3.3 to carry a `gaps` key, and the Overlay holding those gap records
      # exists only inside this method -- returning the reason alone would
      # make the required payload unreachable without a second overlay_for
      # call. The extra element is additive; write[0] and write[1] mean
      # exactly what the spec says they mean.
      #
      # ArgumentError is rescued BEFORE StandardError so the two fatal reasons
      # stay distinguishable in the report: :overlay_error is an invariant
      # guard inside LegOverlay (an unknown stance policy at
      # uc_leg_overlay.rb:283, or a priority defence outside
      # VALID_PRIORITY_DEFENSES at :300-302), while :write_error is a real I/O
      # failure inside LegWriter.write_atomically (uc_leg_writer.rb:165-172).
      # Both must be caught: an unrescued raise kills the director after the
      # leg was already selected and the overlay possibly already replaced.
      #
      # A :gaps refusal says NOTHING about the file. Gaps are checked before
      # the foreign-file check (uc_leg_writer.rb:96-104), so when both are
      # true the reported reason is :gaps and the director must not infer
      # that the path is clear.
      def write_overlay(leg)
        overlay = @world.overlay_for(leg, duration: @duration_minutes)
        result  = @world.write_overlay(overlay)
        return [:ok] if result.written
        return [:refused, :gaps, overlay.gaps] if result.reason == :gaps

        [:fatal, result.reason] # :foreign_file -- permanent for EVERY leg, since they share one path
      rescue ArgumentError
        [:fatal, :overlay_error]
      rescue StandardError
        [:fatal, :write_error]
      end

      def finish(reason, stints, productive)
        detail = @world.abort_detail
        @world.announce(:stopped, reason: reason, detail: detail, stints: stints)
        Director.notify_hook(:after_run, @host, reason: reason, stints: stints)
        Outcome.new(stopped: reason, detail: detail, stints: stints, productive: productive)
      end
    end
  end
end
