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

    # DEFAULT number of killing skills one leg may carry. Overridable per
    # character with the uc_settings key `max_skills_per_leg`
    # (LegSettings.max_skills_per_leg).
    #
    # WHY A LIMIT (user, 2026-09-05). More skills on a leg means less
    # experience per skill in a run of that leg, because combat-trainer
    # divides one stint's fighting between everything in weapons_to_train.
    # That is arithmetic rather than a fault, and the answer is to carry fewer
    # skills per leg, not to spend more stints on the leg.
    #
    # WHY THIS NUMBER, and it is deliberately NOT derived from any one
    # character's skill list. The trade is general:
    #
    #   Lower cap  -> each skill gets a larger share of a stint, but more legs,
    #                 and every leg is its own stint paying the same fixed
    #                 overhead (tannery trip, blocking restock, travel, walk
    #                 home) -- measured at roughly eight minutes.
    #   Higher cap -> cheaper cycles, thinner share per skill.
    #
    # At DURATION_MINUTES = 30, a cap of 3 gives each skill about ten minutes
    # of a stint against about eight minutes of overhead, so the hunting still
    # outweighs the travelling. That ratio holds whether the character trains
    # three skills or thirteen, which is the property worth having in a
    # default.
    #
    # It binds on nothing for a character training few skills: a leg can only
    # be as large as the cluster the width rule built, so a two-skill
    # character never reaches this cap and never notices it.
    #
    # UNMEASURED against play.
    MAX_SKILLS_PER_LEG = 3

    # premium: the character's account tier, as LegSettings.premium reports it
    # (uc_leg_settings.rb). It arrives as a constructor input, alongside the
    # character and the table, because it is a static fact about the account
    # for the whole session -- exactly like the zone table, and unlike
    # anything the picker recomputes per call.
    #
    # It is NOT on Character. Character is live-skill-derived and reads
    # nothing from a profile or a config file by design
    # (uc_character.rb:6-8); premium comes off get_settings and has no skill
    # to compute it from, so putting it there would break that rule for one
    # value.
    #
    # Defaults to false so a caller that has not yet been taught the argument
    # gates conservatively. The wrong default in the other direction unlocks
    # the premium zones for every non-premium character silently, which is the
    # failure this whole gate exists to prevent.
    # province: the name of the province to stay inside, or nil for no
    # limit. Keyword rather than a third positional, because `premium`
    # already occupies that slot and a bare second boolean-looking argument
    # at a call site would be unreadable.
    # max_skills_per_leg: nil takes MAX_SKILLS_PER_LEG. Keyword, like
    # province, because a bare third or fourth positional at a call site would
    # be unreadable next to `premium`.
    # trainable_skills: the skills this character wants to train, or nil for
    # no restriction. LegSettings.trainable_skills builds it from the weapons
    # and spells catalogues, because the catalogue IS the declaration of what
    # to train: a weapon left out is a weapon not trained, not an omission to
    # be reported (user, 2026-09-05).
    def initialize(character, zone_table, premium = false, province: nil, max_skills_per_leg: nil,
                   trainable_skills: nil)
      @character = character
      @zone_table = zone_table
      @premium = premium
      @province = province
      @max_skills_per_leg = max_skills_per_leg || MAX_SKILLS_PER_LEG
      @trainable_skills = trainable_skills
    end

    # nil means no restriction, so every existing caller and every test that
    # does not care keeps its old behaviour.
    def trainable?(skill)
      @trainable_skills.nil? || @trainable_skills.include?(skill)
    end

    # The cap actually in force, so a diagnostic can print it rather than
    # print the constant and be wrong for a character that overrode it.
    attr_reader :max_skills_per_leg

    # The cheapest stance policy that survives the zone, or nil when neither
    # pole clears the zone's lower bound. Spread is preferred because it trains
    # the lagging defence.
    def stance_for(zone)
      return nil unless zone.closed_band?

      Character::STANCES.find { |stance| @character.defensive_metric(stance) >= zone.rank_min }
    end

    def admissible?(zone, skill)
      return false unless zone.closed_band?
      return false if zone.escort_access?
      return false unless @zone_table.critter_bands_known?(zone)
      return false if zone.low_confidence? && !zone.allow_low_confidence_auto_select?
      return false if premium_locked?(zone)
      return false if out_of_province?(zone)

      rank = @character.rank_of(skill)
      return false unless zone.rank_min <= rank && rank <= zone.rank_max

      !stance_for(zone).nil?
    end

    # A zone this character's account cannot reach. Premium-only zones cannot
    # be travelled to at all by a non-premium character, so a leg routed to
    # one never starts and the hunt fails with nothing to read.
    #
    # Both halves are deliberately == true.
    #
    # The zone half excludes ONLY a zone the data knows is premium-only.
    # premium: nil -- unknown, and most of a 363-zone table until the harvest
    # passes land -- falls OPEN and is reported by #unresolved_premium_records
    # instead. Excluding unknowns would be the cautious-looking choice and it
    # would empty the table today, which is why the fail-open direction was
    # chosen and why the report is not optional.
    #
    # The account half means a premium character is gated on nothing: they see
    # every zone, so this predicate is false for them whatever the zone says.
    #
    # Public because the drop must be explicable per zone, not just per skill:
    # uc-zones.lic lists candidates zone by zone and needs the same answer the
    # itinerary's :premium_excluded reason gives.
    def premium_locked?(zone)
      zone.premium == true && @premium != true
    end

    # Out of the province the character chose to hunt in. A preference, not
    # a capability: the zone is perfectly usable, it is just somewhere the
    # hunter does not want to be sent. Nil province admits everything.
    def out_of_province?(zone)
      !zone.in_province?(@province)
    end

    def admissible_zones_for(skill)
      @zone_table.zones.select { |zone| admissible?(zone, skill) }
    end

    # An itinerary is the legs plus the skills that got no leg. The skills that
    # got no leg are reported, never dropped silently. A silent cap reads as
    # full coverage.
    #
    # unresolved_premium is the same principle applied to the OTHER direction
    # of the premium gate: a leg the picker allowed through without the data
    # knowing whether its zone is premium-only. Those are admitted on purpose,
    # so the only thing standing between a fail-open admission and a silent
    # travel failure is this list being carried out to the caller.
    Itinerary = Struct.new(:legs, :unplaced, :unresolved_premium, keyword_init: true)

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
    def build_legs(ranks, zones_by_skill, width = LEG_WIDTH_RANKS, max_skills = :default)
      max_skills = @max_skills_per_leg if max_skills == :default
      legs = []
      remaining = ranks.keys.sort_by { |skill| -ranks[skill] }
      until remaining.empty?
        leader = remaining.shift
        skills = [leader]
        candidates = zones_by_skill[leader]
        remaining.reject! do |skill|
          # A full leg stops absorbing and the rest stay in `remaining`, so the
          # next leg's leader is simply the next-highest skill. That splits an
          # oversized cluster along rank order instead of dropping anything --
          # clustering is an optimisation and must never starve a skill of its
          # zone (see this method's header).
          next false if max_skills && skills.size >= max_skills
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
    # EVERY leg whose band admits it, not the first (user, 2026-09-05).
    # Debilitation is a multiplier: it makes the character likelier to hit or
    # likelier to be missed, so its value is spread across the whole itinerary
    # rather than banked on one leg. It was `legs.find` because one carrier is
    # all that TRAINING it needs, which confused two different jobs.
    #
    # Membership of leg[:skills] still means exactly one thing: this leg TRAINS
    # the skill. That is what stop_on, LegTracker and the gap report all read
    # it as, so a leg whose band cannot teach Debilitation must not list it --
    # doing so would put a skill that can never cap into an .all? stop
    # condition and into the tracker's mindlock test.
    #
    # Carrying Debilitation for SURVIVABILITY on a leg that cannot train it is
    # a question about spells, not about skills, and LegOverlay#spell_candidates
    # answers it.
    def assign_debilitation(legs, deb_rank)
      carriers = legs.select do |leg|
        zone = chosen_zone(leg)
        zone && zone.rank_min <= deb_rank && deb_rank <= zone.rank_max
      end
      carriers.each { |leg| leg[:skills] << "Debilitation" }
      carriers.first
    end

    def build_itinerary
      wanted = Character::KILLING_SET.select { |skill| trainable?(skill) }
      ranks = trained_ranks(wanted)
      zones_by_skill = ranks.keys.to_h { |skill| [skill, admissible_zones_for(skill)] }

      placeable, unplaceable = ranks.keys.partition { |skill| !zones_by_skill[skill].empty? }
      unplaced = unplaceable.map { |skill| exclusion_record(skill) }

      legs = build_legs(ranks.slice(*placeable), zones_by_skill)
      unplaced << debilitation_record(legs)
      unplaced.concat(not_configured_records)

      presented = legs.map { |leg| present(leg) }
      Itinerary.new(legs: presented, unplaced: unplaced.compact,
                    unresolved_premium: unresolved_premium_records(presented))
    end

    # The fail-open half of the premium rule, made visible.
    #
    # A zone with premium: nil is admitted (see #premium_locked?), so a
    # non-premium character can be routed to a zone nobody has checked. That
    # is the deliberate choice -- excluding unknowns would gut the table on
    # the first harvest pass -- but it is only defensible while every unknown
    # the itinerary actually leans on is named. Silence here turns a data gap
    # into a hunt that fails with no explanation, which is precisely the
    # symptom the gate was added to remove.
    #
    # Reported for a premium character too. Their account hides the
    # consequence, not the missing datum, and the harvest still wants it.
    #
    # legs: #present's output, so this reports the zone each leg WILL travel
    # to, not every unknown in the table. The whole-table count is a data
    # statistic; this is the list with a hunt riding on it.
    def unresolved_premium_records(legs)
      legs.filter_map do |leg|
        zone = @zone_table.zone(leg[:zone_key])
        next unless zone&.premium_unknown?

        { zone_key: leg[:zone_key], reason: :premium_unknown, detail: { skills: leg[:skills] } }
      end
    end

    # The key CT writes the stance ordering under. CT keys @stances on the
    # equipped weapon, so a magic-led leg borrows the highest weapon skill. A
    # caster is not unarmed, so this keys on a real weapon in every case.
    # A magic-led leg borrows the character's highest weapon, because CT keys
    # @stances on the EQUIPPED weapon and a casting leg has none of its own.
    #
    # The fallback prefers a weapon the character actually trains. Writing the
    # stance for a weapon that is not in the catalogue means writing it for one
    # they never hold, so CT would never read that entry.
    def stance_key(skills)
      weapon = skills.find { |skill| Character::WEAPON_SKILLS.include?(skill) }
      return weapon if weapon

      wanted = Character::WEAPON_SKILLS.select { |skill| trainable?(skill) }
      wanted = Character::WEAPON_SKILLS if wanted.empty?
      trained_ranks(wanted).max_by { |_skill, rank| rank }&.first
    end

    private

    # Skills the character has actually trained. A rank of zero means the
    # character does not have the skill, so it gets no leg and is not reported
    # as a failure.
    def trained_ranks(skills)
      skills.to_h { |skill| [skill, @character.rank_of(skill)] }
            .reject { |_skill, rank| rank.zero? }
    end

    # Why a skill got no zone. The four causes are distinguishable, and they
    # must stay distinguishable in the log.
    #
    # The stages narrow in a fixed order -- band, then confidence, then
    # premium, then defence -- and the reason names the FIRST stage that
    # emptied the set. That keeps every record a single actionable cause:
    # :premium_excluded means "buy premium or annotate the data", never "and
    # also the ranks were wrong".
    #
    # This order is NOT the literal line order of admissible?, which tests
    # premium before the rank range. It does not need to be. admissible? is a
    # pure conjunction, so its guards commute and the admitted SET is the same
    # either way. Only the reason label depends on the order, and band-first
    # is the useful attribution: a rank out of every band is the operator's
    # problem to act on, and it is true regardless of what premium says.
    def exclusion_record(skill)
      rank = @character.rank_of(skill)
      in_band = @zone_table.zones.select do |zone|
        zone.closed_band? && zone.rank_min <= rank && rank <= zone.rank_max
      end
      # Stage order mirrors admissible? exactly. A stage that runs in one and
      # not the other reports a reason the picker never applied.
      walkable = in_band.reject(&:escort_access?)
      judged = walkable.select { |zone| @zone_table.critter_bands_known?(zone) }
      confident = judged.reject { |zone| zone.low_confidence? && !zone.allow_low_confidence_auto_select? }
      reachable = confident.reject { |zone| premium_locked?(zone) }
      in_province = reachable.reject { |zone| out_of_province?(zone) }

      reason = if in_band.empty?
                 :no_band_in_range
               elsif walkable.empty?
                 :escort_access
               elsif judged.empty?
                 :unknown_critter_band
               elsif confident.empty?
                 :confidence_excluded
               elsif reachable.empty?
                 :premium_excluded
               elsif in_province.empty?
                 :province_excluded
               else
                 :defense_ceiling
               end

      { skill: skill, reason: reason,
        detail: { rank: rank, zones_in_band: in_band.size, zones_after_escort: walkable.size,
                  zones_after_critter_bands: judged.size, zones_after_confidence: confident.size,
                  zones_after_premium: reachable.size, zones_after_province: in_province.size } }
    end

    # A skill the character HAS but does not train. Reported, and deliberately
    # not silent: a typo in a catalogue key ("Small Edge") is indistinguishable
    # from a deliberate omission, and one line naming it is the difference
    # between noticing that in a minute and noticing it in a week.
    #
    # It is not a gap. Gaps refuse a leg; this refuses nothing.
    def not_configured_records
      Character::KILLING_SET.reject { |skill| trainable?(skill) }
                            .reject { |skill| @character.rank_of(skill).zero? }
                            .map do |skill|
        { skill: skill, reason: :not_configured,
          detail: { rank: @character.rank_of(skill) } }
      end
    end

    def debilitation_record(legs)
      return nil unless trainable?("Debilitation")

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
    # The zone the leg will ACTUALLY hunt. Narrowest band wins a tie, because
    # it wastes the least of the leg's rank room, which is consistent with
    # there being no margin.
    #
    # Extracted so assign_debilitation and present cannot disagree. They used
    # to: assign_debilitation asked whether ANY candidate admitted
    # Debilitation's rank, while present then picked the narrowest candidate,
    # which is often a different zone. On the Drazoken fixture that put
    # Debilitation at rank 138 on a leg whose chosen zone was young_ogres,
    # banded 80-120 -- a zone that cannot teach it. The bug was invisible while
    # only one leg ever carried Debilitation and the first admitting leg
    # happened to be right; making it ride every admitting leg exposed it.
    def chosen_zone(leg)
      leg[:zone_candidates].min_by { |candidate| candidate.rank_max - candidate.rank_min }
    end

    def present(leg)
      zone = chosen_zone(leg)
      { skills: leg[:skills],
        zone_key: zone.key,
        stance: { policy: stance_for(zone), key: stance_key(leg[:skills]) },
        min_mana: nil }
    end
  end
end
