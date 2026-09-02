# frozen_string_literal: true

# The zone picker core.
#
# Spec: notes/uber-combat/33-zone-picker-spec.md sections 1, 2 and 5.
#
# The picker is stateless. Every method is a pure function of live character
# state plus the static zone table. It caches nothing, so a rank that moves
# mid-session changes the next answer. Which leg is current, the no-gain
# counters and the trigger cooldowns all belong to session state, not here.
module UberCombat
  class ZonePicker
    # Weak parameter. The fixture's 12-weapon vector gives the same 3 legs at
    # 30 and at 40. Not load-bearing, and not a safety margin.
    LEG_WIDTH_RANKS = 40

    def initialize(character, zone_table)
      @character = character
      @zone_table = zone_table
    end

    # The cheapest stance policy that survives the zone, or nil when neither
    # pole clears the zone's lower bound. Spread is preferred because it trains
    # the lagging defence.
    def stance_for(zone)
      return nil unless zone.closed_band?

      Character::STANCES.find { |stance| @character.defensive_metric(stance) >= zone.rank_min }
    end

    def admissible?(zone, skill)
      return false unless zone.closed_band?
      return false if zone.low_confidence? && !zone.allow_low_confidence_auto_select?

      rank = @character.rank_of(skill)
      return false unless zone.rank_min <= rank && rank <= zone.rank_max

      !stance_for(zone).nil?
    end

    def admissible_zones_for(skill)
      @zone_table.zones.select { |zone| admissible?(zone, skill) }
    end

    # An itinerary is the legs plus the skills that got no leg. The skills that
    # got no leg are reported, never dropped silently. A silent cap reads as
    # full coverage.
    Itinerary = Struct.new(:legs, :unplaced, keyword_init: true)

    # Cluster the skills into legs by bounded leg width.
    #
    # NEVER cluster by gap detection. On a real 12-weapon vector no adjacent gap
    # exceeds 25 ranks, so a gap-splitting clusterer collapses every weapon into
    # one leg. spec/uc_zone_picker_itinerary_spec.rb holds a regression guard for
    # this.
    #
    # The pass is greedy and left to right. A skill that joins no cluster becomes
    # its own single-skill leg, which is correct but less travel-efficient.
    # Clustering is an optimisation. It must never starve a skill of its zone.
    def build_legs(ranks, zones_by_skill, width = LEG_WIDTH_RANKS)
      legs = []
      remaining = ranks.keys.sort_by { |skill| -ranks[skill] }
      until remaining.empty?
        leader = remaining.shift
        skills = [leader]
        candidates = zones_by_skill[leader]
        remaining.reject! do |skill|
          next false if (ranks[leader] - ranks[skill]).abs > width

          shared = candidates & zones_by_skill[skill]
          next false if shared.empty?

          # Candidates only ever shrink, so every skill already accepted keeps a
          # zone that admits it.
          candidates = shared
          skills << skill
          true
        end
        legs << { skills: skills, zone_candidates: candidates }
      end
      legs
    end

    # Debilitation teaches at weapon-like levels but cannot kill, so it can never
    # lead a leg. It rides a killing skill whose zone band admits it. When no leg
    # admits it, it goes untrained this itinerary. It is not given a leg of its
    # own, and it is not forced into a zone whose band it does not fit.
    def assign_debilitation(legs, deb_rank)
      carrier = legs.find do |leg|
        leg[:zone_candidates].any? { |zone| zone.rank_min <= deb_rank && deb_rank <= zone.rank_max }
      end
      carrier[:skills] << "Debilitation" if carrier
      carrier
    end

    def build_itinerary
      ranks = trained_ranks(Character::KILLING_SET)
      zones_by_skill = ranks.keys.to_h { |skill| [skill, admissible_zones_for(skill)] }

      placeable, unplaceable = ranks.keys.partition { |skill| !zones_by_skill[skill].empty? }
      unplaced = unplaceable.map { |skill| exclusion_record(skill) }

      legs = build_legs(ranks.slice(*placeable), zones_by_skill)
      unplaced << debilitation_record(legs)

      Itinerary.new(legs: legs.map { |leg| present(leg) }, unplaced: unplaced.compact)
    end

    # The key CT writes the stance ordering under. CT keys @stances on the
    # equipped weapon, so a magic-led leg borrows the highest weapon skill. A
    # caster is not unarmed, so this keys on a real weapon in every case.
    def stance_key(skills)
      weapon = skills.find { |skill| Character::WEAPON_SKILLS.include?(skill) }
      return weapon if weapon

      trained_ranks(Character::WEAPON_SKILLS).max_by { |_skill, rank| rank }&.first
    end

    private

    # Skills the character has actually trained. A rank of zero means the
    # character does not have the skill, so it gets no leg and is not reported
    # as a failure.
    def trained_ranks(skills)
      skills.to_h { |skill| [skill, @character.rank_of(skill)] }
            .reject { |_skill, rank| rank.zero? }
    end

    # Why a skill got no zone. The three causes are distinguishable, and they
    # must stay distinguishable in the log.
    def exclusion_record(skill)
      rank = @character.rank_of(skill)
      in_band = @zone_table.zones.select do |zone|
        zone.closed_band? && zone.rank_min <= rank && rank <= zone.rank_max
      end
      confident = in_band.reject { |zone| zone.low_confidence? && !zone.allow_low_confidence_auto_select? }

      reason = if in_band.empty?
                 :no_band_in_range
               elsif confident.empty?
                 :confidence_excluded
               else
                 :defense_ceiling
               end

      { skill: skill, reason: reason,
        detail: { rank: rank, zones_in_band: in_band.size, zones_after_confidence: confident.size } }
    end

    def debilitation_record(legs)
      rank = @character.rank_of("Debilitation")
      return nil if rank.zero?
      return nil if assign_debilitation(legs, rank)

      { skill: "Debilitation", reason: :no_carrier, detail: { rank: rank } }
    end

    # The leg carries the policy, never a computed defence order. The order is
    # a live function of the character's ranks, so the enactment layer calls
    # Character#stance_order(policy) when it writes @stances.
    #
    # Narrowest band wins a tie. It wastes the least of the leg's rank room,
    # which is consistent with the rule that there is no margin.
    def present(leg)
      zone = leg[:zone_candidates].min_by { |candidate| candidate.rank_max - candidate.rank_min }
      { skills: leg[:skills],
        zone_key: zone.key,
        stance: { policy: stance_for(zone), key: stance_key(leg[:skills]) },
        min_mana: nil }
    end
  end
end
