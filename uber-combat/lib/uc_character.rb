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
    #
    # OUTLIER_THRESHOLD decides how far below the middle counts as an outlier.
    # It is a judgement call and it can be tuned.
    #
    # LOW_WEIGHT is not a judgement call. Every character has at least 180
    # defensive stance points (user, game knowledge), and CT pours them
    # greedily, so the split is 100 / 80 / 0. The second defence therefore
    # receives 80 percent of what the first receives, and 0.8 is that ratio.
    # Do not tune it without a reason grounded in the game.
    #
    # Tuning one must never move the other.
    OUTLIER_THRESHOLD = 0.8
    LOW_WEIGHT = 0.8

    STANCES = [:spread, :concentrated].freeze

    # The order modes are the same two policies. There is no third, dynamic
    # mode: CT already picks between the first two defences by learning need,
    # every combat cycle, and doing it ourselves would have needed
    # strict_weapon_stance true, which switches CT's version off (user, Wave 7).
    ORDER_MODES = STANCES

    # DRSkill.getxp reports a 0-34 mindstate. 34 is the mindlocked sentinel CT
    # treats as "nothing more to gain" (CT:199, CT:5844).
    MINDLOCK = 34

    # Every weapon skill the game reports, in its own order
    # (drvariables.rb:116-135). That list also carries Parry Ability, which is
    # a defence, and Melee Mastery, Missile Mastery and Expertise, which modify
    # rather than kill. All four are excluded here.
    #
    # Do NOT rebuild this from a character's exp all. The first version was
    # taken from one 12-weapon character and silently had no place for Large
    # Edged, Twohanded Edged or Staves.
    WEAPON_SKILLS = [
      "Small Edged", "Large Edged", "Twohanded Edged",
      "Small Blunt", "Large Blunt", "Twohanded Blunt",
      "Slings", "Bow", "Crossbow", "Staves", "Polearms",
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
    # takes the remainder, slot 3 takes what is left (CT:350-354). Most
    # characters hold fewer than 200 points, so slot 2 is a real allocation.
    #
    # What this list actually controls is SLOT 3. With strict_weapon_stance
    # false, the shipped default (base.yaml:104), CT re-sorts the first two by
    # learning need every combat cycle and leaves the third alone (CT:329-335,
    # CT:6628-6636). So the mode chooses which defence is banished, and CT
    # splits the points between the two survivors.
    #
    # :spread banishes the middle defence, keeping the lagging one in play so
    # that it trains. :concentrated banishes the lagging one.
    #
    # Slot 1 is still the strongest defence. That matters only if someone sets
    # strict_weapon_stance true, and it is the right answer in that case.
    def stance_order(mode)
      raise ArgumentError, "unknown stance order mode: #{mode.inspect}" unless ORDER_MODES.include?(mode)

      strongest, middle, lagging = DEFENSE_SKILLS.sort_by { |skill| -rank_of(skill) }
      return [strongest, middle, lagging] if mode == :concentrated

      [strongest, lagging, middle]
    end
  end
end
