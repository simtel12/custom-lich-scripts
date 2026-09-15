# frozen_string_literal: true

# The decision core for uc-director-plugin-town.rb: D3 slice 1, the town cycle
# at the stint boundary.
#
# Spec: notes/uber-combat/31-trigger-layer-spec.md, table rows 6, 7, 8 and 11.
# Slice 1 only. No severity 1 or 2 trigger, no plugin poll site inside a hunt,
# no guild override, no repair-heuristic hoist, no watchdog boundary.
#
# PURE. Plain data in, plain data out. No Lich, no DRC, no CharSettings, no
# clock. The plugin reads the game and the store and hands the values in.
#
# DEVIATIONS FROM SPEC 31, each one deliberate:
#
#   1. NO HYSTERESIS. Spec 31 re-arms each trigger only after the value falls
#      back past a lower mark. That exists for a trigger polled every tick,
#      where a value sitting on the threshold would fire again and again. Here
#      the value is sampled ONCE per stint, a stint is tens of minutes, and the
#      cooldown already bounds a trigger that stays true.
#   2. DISPATCH IS Script.run_child(name, timeout:), NOT
#      DRC.wait_for_script_to_complete (section 3.4). That call returns nil at
#      once when the target already runs and has no timeout, so a wedged
#      sell-loot would hang the director.
#   3. THE COOLDOWN RECORD IS ONE INTEGER, not the spec's section 4 Hash. With
#      no hysteresis and no pending batch there is nothing else to store, and
#      an Integer never comes back from CharSettings as a SettingsProxy.
#   4. coin_on_hand RUNS sell-loot, NOT a separate deposit task. sell-loot
#      already banks everything above sell_loot_money_on_hand.
#   5. repair_timer READS crossing-repair's OWN TIMER (repair_timer setting,
#      UserVars.repair_timer_snap). A second timer of our own would drift from
#      the one crossing-repair checks and resets.
module UberCombat
  module Town
    # Seconds one town task may run before run_child tears it down. 1800 (user,
    # 2026-09-15): some town activities, study-art.lic for one, take far longer
    # than a sell trip.
    TASK_TIMEOUT = 1800

    # Consecutive failures of ONE task before the run stops (user,
    # 2026-09-15). One timeout can be a busy shop. Two in a row is a pattern.
    MAX_TASK_FAILURES = 2

    # UNMEASURED defaults, used when the profile does not set the key.
    #
    # Encumbrance is $ENC_MAP's scale (drvariables.rb:276-289). 3 is
    # "Burdened", the first level that costs roundtime.
    DEFAULT_ENCUMBRANCE = 3
    # base.yaml ships box_loot_limit blank, so combat-trainer has no box limit
    # to borrow by default.
    DEFAULT_BOX_LIMIT = 8
    # Copper in the hometown currency. 10000 copper is 1 platinum.
    DEFAULT_COIN_LIMIT = 10_000

    # The order tasks run in when several are due. pick first, because picking
    # makes loot to sell. sell-loot next, because it makes the coin a repair
    # spends. crossing-repair last.
    TASK_ORDER = ["pick", "sell-loot", "crossing-repair"].freeze

    Trigger = Struct.new(:name, :tasks, :cooldown, keyword_init: true)

    # Cooldowns from spec 31's table, in seconds.
    #
    # repair_timer's cooldown is nil, which means "the threshold itself", as
    # spec 31 says ("matches repair_timer setting"). It is NOT zero. If
    # crossing-repair exits cleanly WITHOUT resetting its timestamp -- no coin,
    # a closed shop -- the value stays past the threshold, every trip reads as
    # a success, and the failure rule never sees it. With a zero cooldown that
    # is one wasted trip after every stint, for the whole run.
    TRIGGERS = [
      Trigger.new(name: :burden_high, tasks: ["sell-loot"], cooldown: 15 * 60),
      Trigger.new(name: :boxes_at_limit, tasks: ["pick", "sell-loot"], cooldown: 20 * 60),
      Trigger.new(name: :coin_on_hand, tasks: ["sell-loot"], cooldown: 30 * 60),
      Trigger.new(name: :repair_timer, tasks: ["crossing-repair"], cooldown: nil)
    ].freeze

    TRIGGER_NAMES = TRIGGERS.map(&:name).freeze

    # fired: trigger names whose value reached the threshold and whose cooldown
    #   has passed, in TRIGGERS order.
    # cooling: trigger names whose value reached the threshold but whose
    #   cooldown has not passed. Reported, so a person can see why no trip ran.
    # tasks: the scripts to run, each once, in TASK_ORDER.
    Evaluation = Struct.new(:fired, :cooling, :tasks, keyword_init: true)

    # The threshold for each trigger, with defaults applied.
    #
    # raw: {encumbrance:, box_limit:, coin_limit:, repair_timer:}, each a
    # positive Integer or nil. nil takes the default for the first three.
    # repair_timer has NO default here: nil means the character has no repair
    # timer, and the trigger is off, exactly as crossing-repair treats it.
    def self.thresholds(raw)
      {
        burden_high: raw[:encumbrance] || DEFAULT_ENCUMBRANCE,
        boxes_at_limit: raw[:box_limit] || DEFAULT_BOX_LIMIT,
        coin_on_hand: raw[:coin_limit] || DEFAULT_COIN_LIMIT,
        repair_timer: raw[:repair_timer]
      }
    end

    # observations: trigger name -> the measured value, or nil when the probe
    #   could not read it. A nil never fires: a probe that failed is not
    #   evidence that a trip is due.
    # thresholds: .thresholds' return value.
    # last_fired: trigger name -> epoch seconds of the last fire, or nil.
    # now: epoch seconds.
    def self.evaluate(observations:, thresholds:, last_fired:, now:)
      due = TRIGGERS.select { |trigger| reached?(observations[trigger.name], thresholds[trigger.name]) }
      fired, cooling = due.partition do |trigger|
        cooldown = trigger.cooldown || thresholds[trigger.name]
        cooled?(last_fired[trigger.name], cooldown, now)
      end

      Evaluation.new(fired: fired.map(&:name), cooling: cooling.map(&:name),
                     tasks: order_tasks(fired.flat_map(&:tasks)))
    end

    def self.reached?(value, threshold)
      return false if value.nil? || threshold.nil?

      value >= threshold
    end

    def self.cooled?(last, cooldown, now)
      return true if last.nil?

      now - last >= cooldown
    end

    # Each task once, in TASK_ORDER. A task outside TASK_ORDER goes last rather
    # than vanishing, so a trigger added later cannot lose its task silently.
    def self.order_tasks(tasks)
      tasks.uniq.sort_by { |task| TASK_ORDER.index(task) || TASK_ORDER.size }
    end

    # The failure counts after one task. Returns a NEW Hash.
    #
    # A success resets that task's count to zero, so only CONSECUTIVE failures
    # count. A different task succeeding does not reset it.
    def self.record_task(failures, task, succeeded)
      failures.merge(task => succeeded ? 0 : failures.fetch(task, 0) + 1)
    end

    # The first task that failed MAX_TASK_FAILURES times in a row, or nil.
    def self.failure_stop(failures, limit = MAX_TASK_FAILURES)
      failures.find { |_task, count| count >= limit }&.first
    end
  end
end
