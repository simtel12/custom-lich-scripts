# frozen_string_literal: true

# Leg advancement.
#
# Spec: notes/uber-combat/33-zone-picker-spec.md section 3.
#
# The tracker answers one question: is this leg finished? It owns no cadence.
# The caller decides when a tick happens and when a fight ends, so the tracker
# needs no game runtime and no Lich. One tracker belongs to one leg. Replace it
# when the leg changes.
#
# Two exits, and they are not equal. The hard exit is primary and computed: a
# skill learns nothing above the zone's upper bound, so the leg ends the moment
# the leading skill crosses it. Mindlock and no-gain are backstops for zones
# whose authored band is absent or optimistic.
#
# CT's own no-gain counter is not usable here. It only advances when more than
# one weapon is configured (CT:5821), which is never true for a per-skill leg,
# and it lives inside a CT instance that a leg change restarts. This layer
# computes the signal itself.
module UberCombat
  class LegTracker
    # uc_gain_check. Deliberately our own knob, not CT's
    # combat_trainer_gain_check: CT's value of 0 disables its mechanism, and
    # this backstop must not switch off with it (user, Wave 7).
    DEFAULT_GAIN_CHECK = 3

    # status is :continue, :advance or :reselect.
    # :advance means the leg is finished. :reselect means the defensive ceiling
    # moved, so the itinerary is worth rebuilding.
    Verdict = Struct.new(:status, :reason, :detail, keyword_init: true)

    attr_reader :skills, :zone, :stalls

    def initialize(character, zone:, skills:, gain_check: DEFAULT_GAIN_CHECK)
      @character = character
      @zone = zone
      @skills = skills
      @gain_check = gain_check
      @stalls = skills.to_h { |skill| [skill, 0] }
      @last_mindstate = skills.to_h { |skill| [skill, character.mindstate_of(skill)] }
      @last_defence = defence_ranks
      @reselect = nil
    end

    # Cheap. Every read is cached XML with no command cost, so this rides the
    # combat_tick and hunt_tick cadence the trigger layer already established.
    # It runs between fights as well as during them, because mindstate drains
    # into ranks while the character is idle and a rank can cross the bound
    # with no fight in between (user, Wave 7).
    def observe_tick
      watch_defences
      verdict
    end

    # One completed fight. The stall counter advances here and nowhere else. A
    # counter fed by a 1 second idle tick would trip on a pause rather than on a
    # zone that has stopped teaching.
    def observe_fight_end
      advance_stalls
      watch_defences
      verdict
    end

    # The highest-ranked skill on the leg that can end a fight. Debilitation
    # rides a leg and can never lead one, so it never ends a leg either.
    def leading_skill
      @skills.select { |skill| Character::KILLING_SET.include?(skill) }
             .max_by { |skill| @character.rank_of(skill) }
    end

    private

    def verdict
      outgrown || mindlocked || stalled || @reselect || Verdict.new(status: :continue)
    end

    # The hard exit. rank_max is a wall, not a guideline: above it the skill
    # learns nothing at all. A zone with no parseable upper bound has no hard
    # exit and depends on the backstops.
    def outgrown
      skill = leading_skill
      return nil if @zone.rank_max.nil? || skill.nil?

      rank = @character.rank_of(skill)
      return nil unless rank > @zone.rank_max

      Verdict.new(status: :advance, reason: :rank_max_exceeded,
                  detail: { skill: skill, rank: rank, rank_max: @zone.rank_max })
    end

    def mindlocked
      return nil unless @skills.all? { |skill| @character.mindlocked?(skill) }

      Verdict.new(status: :advance, reason: :mindlocked, detail: { skills: @skills })
    end

    # A leg with one skill still learning is still doing useful work, so every
    # skill must have stopped before the leg advances.
    def stalled
      return nil unless @skills.all? { |skill| stalled?(skill) }

      Verdict.new(status: :advance, reason: :no_gain,
                  detail: { stalls: @stalls.dup, gain_check: @gain_check })
    end

    def stalled?(skill)
      @character.mindlocked?(skill) || @stalls[skill] > @gain_check
    end

    # Mirrors CT:5821-5825, minus the weapons_to_train.size > 1 gate that makes
    # CT's counter dead for a per-skill leg. A mindstate that fell counts as a
    # stall: it drained without anything replacing it. A capped skill is done
    # rather than stalling, so it does not feed the counter.
    def advance_stalls
      @skills.each do |skill|
        current = @character.mindstate_of(skill)
        unless @character.mindlocked?(skill)
          @stalls[skill] = current > @last_mindstate[skill] ? 0 : @stalls[skill] + 1
        end
        @last_mindstate[skill] = current
      end
    end

    # A defensive rank that rises can open a better zone or let a concentrated
    # leg fall back to spread. A rank rise anywhere else is not our business:
    # a rise in Slings while training Small Edged changes nothing here.
    #
    # The verdict is sticky. The director decides whether to rebuild, and a
    # rebuild replaces this tracker.
    def watch_defences
      defence_ranks.each do |skill, current|
        if current > @last_defence[skill]
          @reselect = Verdict.new(status: :reselect, reason: :defense_rank_increase,
                                  detail: { skill: skill, from: @last_defence[skill], to: current })
        end
        @last_defence[skill] = current
      end
    end

    def defence_ranks
      Character::DEFENSE_SKILLS.to_h { |skill| [skill, @character.rank_of(skill)] }
    end
  end
end
