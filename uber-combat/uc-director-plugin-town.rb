# frozen_string_literal: true

# uc-director-plugin-town: D3 slice 1, the town cycle at the stint boundary.
#
# After every stint the director hands this plugin control (after_stint). The
# character is home, hunting-buddy has exited, and nothing else runs. The
# plugin reads four values, decides with the pure UberCombat::Town, and runs
# the due scripts one at a time:
#
#   burden_high     DRC.check_encumbrance >= town_encumbrance   -> sell-loot
#   boxes_at_limit  DRCI.count_all_boxes >= town_box_limit      -> pick, sell-loot
#   coin_on_hand    DRCM.wealth(hometown) >= town_coin_limit    -> sell-loot
#   repair_timer    seconds since crossing-repair last ran
#                   >= repair_timer                             -> crossing-repair
#
# Three of the four probes send ONE game command each (encumbrance, look in
# the box containers, wealth). That is fine HERE, with the character idle in
# the safe room. It would NOT be fine inside a combat tick.
#
# Lives in custom-scripts/uber-combat/ and reaches the runtime by symlink at
# lich-5/scripts/custom/uc-director-plugin-town.rb. uc-director.lic loads it
# for `run` and `cycles` only. The run banner lists it as UcTownPlugin; a run
# that prints "plugins: none" sells nothing.
#
# Every task runs under Script.run_child(name, timeout:). The director does
# not time out a hook, so this timeout is the only bound on a wedged task.

lib_dir = File.join(SCRIPT_DIR, 'custom', 'lib')
load File.join(lib_dir, 'uc_leg_settings.rb')
load File.join(lib_dir, 'uc_town.rb')

class UcTownPlugin
  # One flat CharSettings key per trigger, whole-value replacement (spec 31
  # section 4). CharSettings is scoped to the running script, which is
  # uc-director, so these keys never collide with another script's.
  COOLDOWN_KEY_PREFIX = 'uc_trigger_cooldown_'

  def initialize
    @failures = {}
  end

  def before_run(_director, **)
    @failures = {}
    settings = get_settings
    thresholds = UberCombat::Town.thresholds(UberCombat::LegSettings.town_thresholds(settings))
    DRC.message(format('  town: encumbrance %d, boxes %d, coins %d copper, repair every %s',
                       thresholds[:burden_high], thresholds[:boxes_at_limit],
                       thresholds[:coin_on_hand], repair_text(thresholds[:repair_timer])), false)
    UberCombat::LegSettings.bad_town_keys(settings).each do |key|
      DRC.message(format('  town: uc_settings %s is not a usable whole number. Using the default.', key), false)
    end
  rescue StandardError => e
    DRC.message(format('uc-town: could not read the town settings (%s: %s).', e.class, e.message))
  end

  # Returns :break only when one task failed MAX_TASK_FAILURES times in a row.
  # Returns nil in every other case, including its own errors: a town plugin
  # that crashed must print why and let the hunting go on.
  def after_stint(director, **)
    settings = get_settings
    thresholds = UberCombat::Town.thresholds(UberCombat::LegSettings.town_thresholds(settings))
    observations = observe(settings, thresholds)
    now = Time.now.to_i
    evaluation = UberCombat::Town.evaluate(observations: observations, thresholds: thresholds,
                                           last_fired: last_fired, now: now)
    report(observations, thresholds, evaluation)
    return nil if evaluation.tasks.empty?

    # Stamped BEFORE the tasks run. A task that fails still spends the
    # cooldown, which is what spaces out the retry that the failure rule counts.
    evaluation.fired.each { |name| CharSettings["#{COOLDOWN_KEY_PREFIX}#{name}"] = now }

    evaluation.tasks.each do |task|
      @failures = UberCombat::Town.record_task(@failures, task, run_task(director, task))
    end

    stop = UberCombat::Town.failure_stop(@failures)
    return nil if stop.nil?

    DRC.message(format('uc-town: %s failed %d times in a row. Stopping the run.',
                       stop, UberCombat::Town::MAX_TASK_FAILURES))
    :break
  rescue StandardError => e
    DRC.message(format('uc-town: the town check raised %s: %s. Hunting continues.', e.class, e.message))
    nil
  end

  private

  # Each probe is rescued on its own, so one broken read (an unknown
  # hometown, a missing container) cannot hide the other three.
  def observe(settings, thresholds)
    {
      burden_high: probe(:burden_high) { DRC.check_encumbrance },
      boxes_at_limit: probe(:boxes_at_limit) { DRCI.count_all_boxes(settings) },
      coin_on_hand: probe(:coin_on_hand) { DRCM.wealth(settings.hometown) },
      repair_timer: thresholds[:repair_timer] ? probe(:repair_timer) { seconds_since_repair(thresholds[:repair_timer]) } : nil
    }
  end

  def probe(name)
    value = yield
    value.is_a?(Integer) ? value : nil
  rescue StandardError => e
    DRC.message(format('uc-town: could not read %s (%s: %s).', name, e.class, e.message))
    nil
  end

  # The same arithmetic crossing-repair.lic's should_repair_by_time? uses.
  #
  # AN UNSET TIMESTAMP COUNTS AS DUE. crossing-repair seeds it only when it
  # runs (crossing-repair.lic:46). Reading unset as "not due" would mean this
  # trigger never fires, so crossing-repair never runs, so the timestamp is
  # never seeded -- and the character never repairs. The first trip seeds it.
  def seconds_since_repair(interval)
    snap = UserVars.repair_timer_snap
    return interval if snap.nil?

    (Time.now - snap).to_i
  end

  def last_fired
    UberCombat::Town::TRIGGER_NAMES.to_h do |name|
      value = CharSettings["#{COOLDOWN_KEY_PREFIX}#{name}"]
      [name, value.is_a?(Integer) ? value : nil]
    end
  end

  # true when the task finished without an error.
  def run_task(director, task)
    DRC.message(format('uc-town: running %s (timeout %d s)', task, UberCombat::Town::TASK_TIMEOUT))
    child = Script.run_child(task, timeout: UberCombat::Town::TASK_TIMEOUT)
    return true if child.exit_error.nil?

    DRC.message(format('uc-town: %s ended with an error: %s', task, child.exit_error))
    false
  rescue Script::StartError
    DRC.message(format('uc-town: could not start %s. It is missing or already running.', task))
    false
  rescue Script::TimeoutError
    DRC.message(format('uc-town: %s ran past %d s and was stopped.', task, UberCombat::Town::TASK_TIMEOUT))
    # A town script walks with go2, which is a sibling and survives the kill.
    # Left running, it would drag the next stint's travel off course.
    director.world&.stop_walkers if director.respond_to?(:world)
    false
  rescue StandardError => e
    DRC.message(format('uc-town: %s raised %s: %s', task, e.class, e.message))
    false
  end

  # One line every stint, fired or not. The defaults are unmeasured, and this
  # line is what they get tuned from.
  def report(observations, thresholds, evaluation)
    DRC.message(format('uc-town: encumbrance %s/%d, boxes %s/%d, coins %s/%d, repair %s/%s',
                       observations[:burden_high] || '?', thresholds[:burden_high],
                       observations[:boxes_at_limit] || '?', thresholds[:boxes_at_limit],
                       observations[:coin_on_hand] || '?', thresholds[:coin_on_hand],
                       observations[:repair_timer] || '-', thresholds[:repair_timer] || 'off'), false)
    DRC.message(format('uc-town: fired %s', evaluation.fired.join(', ')), false) unless evaluation.fired.empty?
    return if evaluation.cooling.empty?

    DRC.message(format('uc-town: due but cooling down: %s', evaluation.cooling.join(', ')), false)
  end

  def repair_text(seconds)
    seconds ? format('%d s', seconds) : 'never (repair_timer is not set)'
  end
end

UcDirector.register_plugin(UcTownPlugin.new)
