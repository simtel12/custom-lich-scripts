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
  end
end
