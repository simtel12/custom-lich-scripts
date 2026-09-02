# frozen_string_literal: true

# Character-derived inputs for the zone picker.
#
# Spec: notes/uber-combat/33-zone-picker-spec.md section 1.1 and 1.2.
# Every value here is computed live from the character's own skills. Nothing is
# pegged to a snapshot, and no value is ever read from a profile or a config
# file (99-progress.md, "The character advances").
module UberCombat
  # Reads DRSkill for a live Lich session. Injected into Character so the picker
  # core stays testable without the game runtime.
  class LiveSkills
    def rank(name)
      DRSkill.getrank(name)
    end

    def modrank(name)
      DRSkill.getmodrank(name)
    end

    def mindstate(name)
      DRSkill.getxp(name)
    end
  end

  class Character
    DEFENSE_SKILLS = ["Evasion", "Shield Usage", "Parry Ability"].freeze

    # These two constants share a value and are NOT the same knob.
    # OUTLIER_THRESHOLD decides how far below the middle counts as an outlier.
    # LOW_WEIGHT decides how much the low defence contributes to the spread pole.
    # Tuning one must never move the other (99-progress.md:41-44).
    OUTLIER_THRESHOLD = 0.8
    LOW_WEIGHT = 0.8

    STANCES = [:spread, :concentrated].freeze

    # How the three defences are ordered for CT. This is a separate axis from
    # STANCES, which decides admissibility. :spread and :concentrated order to
    # match their own policy. :dynamic refines :spread by choosing the second
    # slot on mindstate instead of rank, and it is only ever paired with the
    # :spread policy (user, Wave 7).
    ORDER_MODES = [:spread, :concentrated, :dynamic].freeze

    # DRSkill.getxp reports a 0-34 mindstate. 34 is the mindlocked sentinel CT
    # treats as "nothing more to gain" (CT:199, CT:5844).
    MINDLOCK = 34

    # The 12 weapon skills, in the order the game reports them.
    WEAPON_SKILLS = [
      "Small Edged", "Small Blunt", "Large Blunt", "Twohanded Blunt",
      "Slings", "Bow", "Crossbow", "Polearms",
      "Light Thrown", "Heavy Thrown", "Brawling", "Offhand Weapon"
    ].freeze

    # Skills that end a fight. Bounds the healing selector.
    KILLING_SET = (WEAPON_SKILLS + ["Targeted Magic"]).freeze

    # Skills that need a zone. Debilitation teaches at weapon-like levels but
    # cannot kill, so it rides a killing skill and never leads a leg.
    TRAINING_SET = (KILLING_SET + ["Debilitation"]).freeze

    def initialize(skills = LiveSkills.new)
      @skills = skills
    end

    # Always avg(getrank, getmodrank). Non-refreshable buffs are counted, not
    # excluded (user, 2026-08-14). The average already bounds exposure to half
    # the buff bonus, which is the margin the brief unbuffed window needs.
    def rank_of(skill)
      (@skills.rank(skill) + @skills.modrank(skill)) / 2.0
    end

    def defensive_metric(stance)
      raise ArgumentError, "unknown stance: #{stance.inspect}" unless STANCES.include?(stance)

      high, mid, low = DEFENSE_SKILLS.map { |skill| rank_of(skill) }.sort.reverse
      return high if stance == :concentrated

      effective_low = low < mid * OUTLIER_THRESHOLD ? mid : low
      (high + effective_low * LOW_WEIGHT) / 2.0
    end

    def mindstate_of(skill)
      @skills.mindstate(skill)
    end

    def mindlocked?(skill)
      mindstate_of(skill) == MINDLOCK
    end

    # The ordered defence list CT writes into @stances[key].
    #
    # CT pours the stance points in greedily: slot 1 takes up to 100, slot 2
    # takes the remainder, slot 3 takes what is left (CT:5850-5854). Most
    # characters hold fewer than 200 points, so slot 2 is a real allocation.
    #
    # The strong defence always leads. The second slot is what the mode picks:
    # the middle defence for :concentrated (the lagging one is deliberately
    # starved), the lagging defence for :spread, and the defence with the most
    # room to learn for :dynamic.
    #
    # This order only survives when settings.strict_weapon_stance is true. With
    # it false CT re-sorts the first two by sort_by_rate_then_rank (CT:329-335,
    # CT:6628-6636), which sorts ascending by mindstate and would displace the
    # strong defence from slot 1.
    def stance_order(mode)
      raise ArgumentError, "unknown stance order mode: #{mode.inspect}" unless ORDER_MODES.include?(mode)

      strongest, *rest = DEFENSE_SKILLS.sort_by { |skill| -rank_of(skill) }
      second = case mode
               when :concentrated then rest.first
               when :spread then rest.last
               when :dynamic then rest.min_by { |skill| [mindstate_of(skill), rank_of(skill)] }
               end
      [strongest, second] + (rest - [second])
    end
  end
end
