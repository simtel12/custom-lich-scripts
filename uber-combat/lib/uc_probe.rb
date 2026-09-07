# frozen_string_literal: true

require "time"

# The decision core for uc-probe.lic: walking a live character to every
# hunting zone and recording which ones it cannot reach, so that unresolved
# `premium:` flags in base-uc-zones.yaml can be settled empirically.
#
# Spec: notes/uber-combat/37-zone-probe-spec.md, sections 4, 5 and 7
# especially. Every rule below cites the section it comes from so a
# disagreement between this file and the spec can be checked against the
# source instead of against memory.
#
# PURE, with one exception. Every module method here (.partition,
# .deadline_for, .rank, .verdict, .record) takes plain data and returns plain
# data -- no Map, Room, DRCT, Flags, DRStats or XMLData call anywhere in this
# file. Session is the one class that touches the game at all, and it does so
# through exactly one seam: the `world` object its constructor is handed (see
# Session's own header comment). uc-probe.lic supplies a real world; every
# test in spec/uc_probe_spec.rb supplies a fake one. This mirrors
# lib/uc_leg_writer.rb's own split of a pure .decide from the one IO method.
module UberCombat
  module Probe
    # A guard blocks an ENTRANCE, not a zone (37-zone-probe-spec.md:457). The
    # median tagged zone has 6 rooms and the largest has 25; trying only one
    # manufactures a false :blocked the moment that one room happens to have
    # its own guard. Proposed and left unconfirmed by the spec itself
    # (open question 3), but a bound is required either way.
    MAX_ROOMS_PER_ZONE = 3

    # A fixed per-attempt deadline is wrong in both directions: too short and
    # a legitimate cross-continent trip reads as a timeout; too long and a
    # nearby, quietly-wedged attempt burns the whole run's wall clock for no
    # extra evidence. Scaling off the Dijkstra distance the probe already
    # computed (37-zone-probe-spec.md open question 4) answers both: the floor
    # keeps a same-room attempt from being cut off mid-retreat-and-retry, the
    # ceiling keeps one distant zone from eating the run.
    #
    # THE FLOOR WAS 180 AND THAT WAS TOO HIGH. The first live run queued a
    # zone 4.4 travel-seconds away, so the scaled value was 73 s and the floor
    # overrode it to 180 -- forty times the expected trip.
    #
    # Be precise about blame, because the record matters: 180 is NOT what the
    # user actually waited through. walk_to's OWN stall watchdog
    # (common-travel.rb:245-252) fired first, at 90 s per room, and the
    # recorded `elapsed: 92.0` is that timer, not ours. A deadline of 180
    # simply meant ours could never fire before walk_to's, so it contributed
    # nothing at all. 60 matches DEADLINE_SLACK, so the floor now only binds
    # at a distance of zero, and a near zone gets a deadline that can actually
    # land ahead of walk_to's 90.
    #
    # The real cure for the wait is the early kill on a captured blocking
    # line, in uc-probe.lic's watchdog. A deadline is the backstop.
    MIN_ATTEMPT_DEADLINE = 60
    MAX_ATTEMPT_DEADLINE = 600

    # deadline = distance * DEADLINE_FACTOR + DEADLINE_SLACK, clamped to the
    # floor/ceiling above. DEADLINE_SLACK covers the fixed overhead every
    # attempt pays regardless of distance (go2's own retry/restart dance,
    # muckled waits, door-opening) that a pure distance multiple would not.
    DEADLINE_SLACK = 60
    DEADLINE_FACTOR = 3

    # Distinct from every provenance token already in use in
    # base-uc-zones.yaml (rank/critters/province/towns/premium tokens
    # censused in 37-zone-probe-spec.md:575-584), so a probe-sourced
    # `reachability` value can never be mistaken for an elanthipedia-harvest
    # one. Labels the `reachability` field only -- `provenance.premium` is
    # never touched here (see .record below).
    PROVENANCE_TOKEN = "probe_walk"

    # zones the probe never has to walk anywhere to settle:
    #   escort  -- access == "escort". Tested before the tag lookup, so an
    #     escort zone whose key happens to also be a map tag lands here and
    #     never in probeable (uc-zones.lic:120-125 orders it the same way,
    #     for the same reason).
    #   no_tag  -- a plain zone whose key is not a map tag at all. There is
    #     nothing to Map.rooms_by_tag its way to.
    #   answered -- premium is already known, true or false. Nothing to find
    #     out, so nothing to walk to. Like out_of_band these are DEFERRED and
    #     never recorded: the probe observed nothing about them.
    #   out_of_band -- this character cannot survive standing there. NOT a
    #     fact about the zone, unlike escort and no_tag, so these are
    #     DEFERRED rather than settled: the caller must not record them, and
    #     a later run by a stronger character reconsiders them.
    # probeable is everything else: a real candidate for .rank and a walk.
    #   out_of_province -- outside the province the hunter chose to stay in.
    #     A preference, not a capability, so like answered and out_of_band
    #     these are skipped and never recorded.
    Partition = Struct.new(:probeable, :escort, :no_tag, :answered, :out_of_province, :out_of_band,
                           keyword_init: true)

    # One iteration's answer to "what does the character walk to next."
    # next_zone/rooms are nil together when nothing priced is reachable.
    # rooms is the next_zone's tagged rooms, reachable-only, nearest first,
    # already truncated to MAX_ROOMS_PER_ZONE -- the caller does not re-slice
    # it. unreachable is every OTHER probeable zone this call found to have
    # no reachable tagged room at all, settled as :no_path with no walk.
    Ranking = Struct.new(:next_zone, :rooms, :unreachable, keyword_init: true)

    # zones: Array<Zone>, the full table (or a run's chosen subset).
    # rooms_for_tag: a callable, zone key -> Array<Integer> of room ids
    #   (empty for a key with no map tag). Kept as an injected callable, not
    #   a hardcoded Map.rooms_by_tag call, so this stays testable with a
    #   plain Hash-backed double and no Lich runtime.
    # defence: the character's defensive metric, or nil for no band filter.
    # province: the province to stay inside, or nil for no limit. Checked
    #   BEFORE the band, because it is the hunter's explicit statement of
    #   where they are willing to go -- a zone they ruled out on those
    #   grounds should not also be weighed for danger, and reporting it as
    #   too dangerous would suggest a stronger character could have it.
    #
    # WHY A ZONE WITH A KNOWN premium IS NOT PROBED (user, after two live
    # runs). The probe exists to turn `premium: null` into an answer. A zone
    # that already has one, true or false, has no signal left to give, and
    # walking to it spends the travel budget on a result nobody will act on.
    # Of the 54 zones left in scope after the first run, 30 were exactly this
    # -- confirmations of a flag already set.
    #
    # This retires the automatic calibration control, and that is a real
    # trade rather than a free win: probing a known-premium zone was how a
    # wrong harvest would have announced itself. It is an acceptable trade
    # because the control ALREADY RAN AND PASSED -- undead_gerbils, marked
    # premium, came back blocked on a basic account with the guard's line
    # captured. To run it again, clear that zone's `premium` back to null
    # deliberately; nothing here will do it by accident.
    #
    # WHY THERE IS A BAND FILTER AT ALL. The probe orders by DISTANCE, and
    # distance has nothing to do with danger: the first real plan run put a
    # rank 200-250 zone second in the queue for a character whose defensive
    # metric is 68, and the full ordering eventually reaches zones ranked
    # 1500-1750. The probe does not fight, but it stands in the room, and
    # the creatures there do not wait to be asked.
    #
    # WHY IT COSTS NOTHING. ZonePicker#admissible? already refuses any zone
    # whose rank_min exceeds the character's defensive metric, and refuses
    # any zone without a closed band outright. So a zone this filter removes
    # is a zone the picker could never select, which means its premium flag
    # cannot change a single decision this character makes. Probing it buys
    # no answer anybody can use, and risks the character to get it.
    #
    # The check runs AFTER escort and no_tag on purpose. Those two are
    # permanent facts about the zone; this one is a fact about the character
    # and expires as they train. Ordering it last keeps a zone that can
    # never be walked to from being filed as merely deferred.
    def self.partition(zones, rooms_for_tag, defence: nil, province: nil)
      probeable = []
      escort = []
      no_tag = []
      answered = []
      out_of_province = []
      out_of_band = []

      zones.each do |zone|
        if zone.access == "escort"
          escort << zone
        elsif rooms_for_tag.call(zone.key).empty?
          no_tag << zone
        elsif !zone.premium_unknown?
          answered << zone
        elsif !zone.in_province?(province)
          out_of_province << zone
        elsif !survivable?(zone, defence)
          out_of_band << zone
        else
          probeable << zone
        end
      end

      Partition.new(probeable: probeable, escort: escort, no_tag: no_tag, answered: answered,
                    out_of_province: out_of_province, out_of_band: out_of_band)
    end

    # A nil defence disables the filter entirely, which is what a caller with
    # no live character has. An OPEN band counts as unsurvivable rather than
    # safe: an unknown floor is an unknown danger, and the picker will not
    # select such a zone either (Zone#closed_band? is a hard requirement in
    # ZonePicker#admissible?), so the same "cannot change a decision"
    # argument applies unchanged.
    def self.survivable?(zone, defence)
      return true if defence.nil?
      return false unless zone.closed_band?

      zone.rank_min <= defence
    end

    # distance: travel seconds from Room#dijkstra's second return value, or
    # nil when the caller has none (there is always a floor either way).
    def self.deadline_for(distance)
      return MIN_ATTEMPT_DEADLINE if distance.nil?

      ((distance * DEADLINE_FACTOR) + DEADLINE_SLACK).clamp(MIN_ATTEMPT_DEADLINE, MAX_ATTEMPT_DEADLINE)
    end

    # probeable: Array<Zone>, not yet settled this run.
    # distances: Hash{room_id => seconds}, Room#dijkstra's second return
    #   value from the character's CURRENT position. A room dijkstra could
    #   not reach at all is simply absent from this hash -- not present with
    #   a nil or infinite value -- so the filter_map below is what drops it.
    # rooms_for_tag: same contract as .partition's argument.
    #
    # Every candidate is re-priced against the CURRENT distances hash on
    # every call. This method does not remember anything between calls --
    # the caller (Session) is the one that re-derives distances and calls
    # this again after every move, which is the "expanding order... then
    # re-evaluate the next closest" the whole design turns on
    # (37-zone-probe-spec.md:434-438). A ranker that sorted once up front
    # would be answering yesterday's question with the character standing
    # somewhere else entirely.
    def self.rank(probeable, distances, rooms_for_tag)
      unreachable = []
      priced = []

      probeable.each do |zone|
        pairs = rooms_for_tag.call(zone.key)
                             .filter_map { |room_id| distances[room_id] && [room_id, distances[room_id]] }
                             .sort_by { |(_room_id, dist)| dist }

        if pairs.empty?
          unreachable << zone
        else
          priced << [zone, pairs]
        end
      end

      return Ranking.new(next_zone: nil, rooms: nil, unreachable: unreachable) if priced.empty?

      zone, pairs = priced.min_by { |(_zone, zone_pairs)| zone_pairs.first.last }
      Ranking.new(next_zone: zone, rooms: pairs.take(MAX_ROOMS_PER_ZONE), unreachable: unreachable)
    end

    # rubocop:disable Lint/UnusedMethodArgument
    #
    # arrived: walk_to's OWN verdict -- room-id equality with the single
    #   target it was given (common-travel.rb:272). Accepted here so the
    #   caller cannot quietly compute it and pass nothing else, but it NEVER
    #   drives this method's answer. go2 plans against the planned room, not
    #   the room it actually stops in (go2.lic:2309), so a character can
    #   legitimately end an attempt standing in a different tagged room of
    #   the SAME zone -- that is still :reached, even though walk_to itself
    #   would report false. Precedence below is load-bearing and in this
    #   exact order (37-zone-probe-spec.md:494-509):
    # current_room_id: Integer, or nil if position was lost mid-attempt.
    # zone_rooms: the zone's FULL tagged room set (not just the <=3 rooms
    #   this attempt tried) -- arrival is set membership over all of it.
    # blocking_line: the Flags-captured line (see Session's world contract),
    #   or nil/"" when nothing matched.
    # timed_out: true when the probe's own deadline expired, never go2's.
    def self.verdict(arrived:, current_room_id:, zone_rooms:, blocking_line:, timed_out:)
      # A deadline expiry is not evidence of anything -- it means the probe
      # gave up watching, not that the game refused. Checked first so a slow
      # but eventually-successful trip is never misfiled as a block.
      return :timeout if timed_out
      return :reached if zone_rooms.include?(current_room_id)
      return :blocked if blocking_line && !blocking_line.empty?

      # No line captured is not "nothing happened" -- 37-zone-probe-spec.md
      # section 0.4 traces a real transcript where the block was total (the
      # character never arrived) and totally silent (the refusal was inside
      # a StringProc step whose return value go2 discards). blocked_silent
      # keeps that swallowed case from masquerading as a witnessed one.
      :blocked_silent
    end
    # rubocop:enable Lint/UnusedMethodArgument

    # rubocop:disable Lint/UnusedMethodArgument
    #
    # Builds the Hash written for ONE zone. String keys throughout -- this is
    # destined for YAML and for a merge into base-uc-zones.yaml, which is
    # string-keyed end to end (uc_zone_table.rb:55-59's own comment on the
    # same hazard). verdict is stored as a String, never a Symbol: a Symbol
    # round-trips through YAML as `:blocked` and breaks a plain reader.
    #
    # reachability is keyed by ACCOUNT TIER, not a scalar -- a premium
    # `reached` sitting beside a basic `blocked` on the same zone is direct
    # proof of premium gating, and a scalar field would have to throw one of
    # the two away (37-zone-probe-spec.md:591-593, open question 5, resolved
    # here in the list-by-tier direction).
    #
    # zone_key: which zone this record is for. Not present anywhere in the
    #   returned Hash -- the caller (Session) uses it as ITS OWN external
    #   key when it assembles Outcome#records, exactly as the YAML example
    #   below nests this method's return value under the zone's existing
    #   key rather than repeating it inside. Required here anyway so a call
    #   site always names the zone it is recording, even though this method
    #   does not need the value to build its own return.
    # verdict: :reached / :blocked / :blocked_silent / :no_path / :no_tag /
    #   :timeout, or the equivalent String -- either is accepted and both
    #   are stored the same way.
    # tier: the account tier this observation was made under.
    # meta: a Hash with :character, :game, :map (constant for a whole run)
    #   and :at (the ISO 8601 timestamp for THIS record, stamped fresh per
    #   call by the caller). Read only, never computed -- this method must
    #   never call Time.now itself, or every spec here would need real wall
    #   clock time to stay deterministic.
    # room: the room id this attempt targeted (not necessarily the room the
    #   character ended up standing in -- see .verdict's set-membership
    #   comment for why those can differ on a :reached).
    # rooms_tried: every room id attempted, in order. Kept even when it is a
    #   single-element list equal to [room] -- a zone that refused three
    #   entrances is much stronger evidence than one that refused one, and
    #   collapsing the two would throw that away.
    # line: the captured blocking line, or nil. OMITTED entirely from the
    #   output when nil -- never written as `line: null` -- so a reader can
    #   tell "we checked and there was nothing" apart from "we did not check
    #   this field at all" by the key's mere presence.
    # engaged: whether combat engagement fired during the attempt (an
    #   engaged attempt is weaker evidence -- 37-zone-probe-spec.md:630 --
    #   but the probe still records it rather than discarding the result).
    # elapsed: wall-clock seconds the attempt took, or nil.
    # crossings: UberCombat::Ferry::Crossing objects for the ferries on the
    #   route this attempt planned, stored as their bescort invocations
    #   ("ferry leth"). OMITTED when empty, for the same reason `line` is: a
    #   route with no boat on it and a route nobody checked must stay
    #   distinguishable, and every record written before this field existed
    #   is honestly in the second category.
    #
    #   DETECTION ONLY. It never touches the verdict. Its job is to explain a
    #   slow or timed-out attempt after the fact -- the deadline scales off
    #   Dijkstra distance (see .deadline_for) and a Dijkstra second is not a
    #   wall-clock second when the route waits for a boat to dock.
    #
    # This method NEVER writes premium: or provenance.premium. Those belong
    # to the elanthipedia harvest and to human adjudication
    # (37-zone-probe-spec.md:540-544) -- ZonePicker#premium_locked? reads
    # `premium:` directly, so a probe guess written there would silently
    # gate zones on evidence that was never actually a verdict.
    def self.record(zone_key:, verdict:, tier:, meta:, room: nil, rooms_tried: [], line: nil,
                    engaged: false, elapsed: nil, crossings: [])
      entry = {
        "verdict"     => verdict.to_s,
        "room"        => room,
        "rooms_tried" => rooms_tried
      }
      entry["line"] = line unless line.nil?
      entry["crossings"] = crossings.map(&:to_s) unless crossings.nil? || crossings.empty?
      entry["character"] = meta[:character]
      entry["game"] = meta[:game]
      entry["map"] = meta[:map]
      entry["at"] = meta[:at]
      entry["engaged"] = engaged
      entry["elapsed"] = elapsed

      {
        "reachability" => { tier.to_s => entry },
        "provenance"   => { "reachability" => PROVENANCE_TOKEN }
      }
    end
    # rubocop:enable Lint/UnusedMethodArgument

    # The driver. Everything above this class is pure; this class is what
    # actually walks the loop described in 37-zone-probe-spec.md section 4,
    # and its ONLY contact with the game -- indeed with anything outside this
    # file -- is the injected `world`. uc-probe.lic supplies a real one built
    # on Map/Room/DRCT/Flags; every example in spec/uc_probe_spec.rb supplies
    # a fake one and drives this class exactly the way the real script will.
    #
    # world contract:
    #   world.current_room_id            -> Integer, or nil when position is lost
    #   world.distances_from(room_id)    -> Hash{room_id => seconds}, or nil on failure
    #   world.rooms_for_tag(key)         -> Array<Integer>
    #   world.ferries_to(room_id)        -> Array<Ferry::Crossing> for the
    #                                    route from where the character stands
    #                                    now. [] both when the route has no boat
    #                                    on it and when there is no route at all.
    #                                    DETECTION ONLY -- it is read into the
    #                                    record and never into a verdict.
    #   world.announce(zone, room_id, index, count) -> nil, called once before
    #                                    every walk_to. Presentation only; the
    #                                    core never reads anything back from it.
    #   world.walk_to(room_id, deadline) -> [arrived_boolean, timed_out_boolean, elapsed_seconds]
    #   world.reset_capture              -> nil, clears the blocking-line capture
    #   world.blocking_line              -> String or nil
    #   world.engaged?                   -> Boolean, whether combat engagement fired during the attempt
    #   world.abort_reason                -> Symbol or nil, checked between every attempt
    #   world.now                        -> Time
    class Session
      # records: Hash{zone_key => the Hash .record built for it}. Always
      #   returned, even on an abort -- a partial run's evidence is never
      #   thrown away (37-zone-probe-spec.md:411, "NEVER discard partial
      #   results").
      # aborted: the Symbol reason the run stopped early (:position_lost,
      #   :dijkstra_failed, or whatever world.abort_reason returned), or nil
      #   when every probeable zone was settled.
      # visited: how many zones the run actually WALKED toward -- that is,
      #   how many times #attempt called world.walk_to at least once. Zones
      #   settled without moving (escort, no_tag, no_path) do not count;
      #   they are exactly the zones this run never had to burn wall-clock
      #   time on, and visited is meant to answer "how much of the run's
      #   travel budget got spent," not "how many records exist."
      # deferred: how many zones the band filter held back. Deliberately a
      #   COUNT and not records -- a deferred zone has no answer, and writing
      #   one would make it look settled and keep a stronger character from
      #   ever reconsidering it (see Probe.partition).
      # answered: how many zones were skipped because premium is already
      #   known. Counted SEPARATELY from deferred because the two mean
      #   opposite things -- "nothing left to learn" against "could not go
      #   and learn it" -- and only the second is a gap in the data.
      # out_of_province: how many the province setting held back. A third
      #   distinct meaning: the answer is missing and gettable, but the
      #   hunter said not to go there.
      Outcome = Struct.new(:records, :aborted, :visited, :deferred, :answered, :out_of_province,
                           keyword_init: true)

      # zones: Array<Zone>, the full candidate set -- escort and untagged
      #   zones included. Partitioning them is this class's job (via
      #   Probe.partition), not the caller's.
      # world: see the contract above.
      # tier: the account tier String every record from this run is filed
      #   under. Constant for the whole run -- a second tier is a second,
      #   independently valuable, Session (see .record's own comment on why
      #   reachability is a list keyed by tier, not a scalar).
      # meta: the run-constant identity Hash, :character/:game/:map. :at is
      #   deliberately NOT part of this -- it is stamped fresh from
      #   world.now for every single record this run writes, never memoised
      #   at construction time.
      # defence: the character's defensive metric, or nil to probe every
      #   tagged zone regardless of danger. See Probe.partition for why a
      #   live run always passes one.
      def initialize(zones, world, tier:, meta:, defence: nil, province: nil)
        @zones = zones
        @world = world
        @tier = tier
        @meta = meta
        @defence = defence
        @province = province
        @visited = 0
      end

      def run
        records = {}
        partition = Probe.partition(@zones, @world.method(:rooms_for_tag),
                                    defence: @defence, province: @province)

        # Escort and untagged zones are the same fact stated two ways --
        # "there is nothing to walk to" -- so both are filed as :no_tag and
        # left for the zone's own `access` field to carry the escort
        # distinction (37-zone-probe-spec.md's own instruction: reuse the
        # verdict, do not invent a second one).
        (partition.escort + partition.no_tag).each do |zone|
          records[zone.key] = record_for(zone.key, "no_tag")
        end

        # answered, out_of_province and out_of_band are pointedly NOT
        # recorded here. None of the three was observed: nobody needs the
        # first, the hunter ruled out the second, and the character cannot
        # safely reach the third. A record would claim an observation that
        # never happened, and would also settle the zone permanently,
        # because the caller subtracts everything already recorded from the
        # next run's candidates. All three can change -- a merge, a settings
        # edit, or training -- and each must come back around when it does.

        probeable = partition.probeable
        aborted = nil

        until probeable.empty?
          aborted = @world.abort_reason
          break if aborted

          here = @world.current_room_id
          if here.nil?
            # Without a position both the ordering below and every verdict
            # this run could still produce are meaningless -- a hard abort,
            # not a fallback (37-zone-probe-spec.md abort A5).
            aborted = :position_lost
            break
          end

          distances = @world.distances_from(here)
          if distances.nil?
            aborted = :dijkstra_failed
            break
          end

          # Re-derived from scratch every iteration -- see Probe.rank's own
          # comment on why sorting once up front would be wrong.
          ranking = Probe.rank(probeable, distances, @world.method(:rooms_for_tag))

          # Settled without a single walk_to call -- this is where the two
          # Hara zones from 37-zone-probe-spec.md section 0.6 land, and it
          # is free.
          ranking.unreachable.each do |zone|
            records[zone.key] = record_for(zone.key, "no_path")
            probeable.delete(zone)
          end

          break if ranking.next_zone.nil?

          zone = ranking.next_zone
          records[zone.key] = attempt(zone, ranking.rooms)
          # Never probe the same zone twice in one run -- a second attempt
          # after the character has already moved is not an independent
          # observation (37-zone-probe-spec.md:484-486).
          probeable.delete(zone)
        end

        # A final check, not just the top-of-loop one above: an abort can
        # fire during the very last zone's attempt (inside #attempt's own
        # between-rooms check) with nothing left in probeable afterward, so
        # the loop exits normally without ever re-entering the top-of-loop
        # check that would otherwise have caught it. A trailing abort is
        # still real information -- typically a safety condition (health,
        # engagement count) that outlived the run -- so it is surfaced here
        # even when every zone was already settled.
        aborted ||= @world.abort_reason

        Outcome.new(records: records, aborted: aborted, visited: @visited,
                    deferred: partition.out_of_band.size, answered: partition.answered.size,
                    out_of_province: partition.out_of_province.size)
      end

      private

      def record_for(zone_key, verdict, **fields)
        Probe.record(zone_key: zone_key, verdict: verdict, tier: @tier, meta: meta_now, **fields)
      end

      # world.now, not Time.now -- the only place in this class a timestamp
      # is produced, and it goes through the same double every other game
      # read does, so a fake world makes the whole class deterministic.
      def meta_now
        @meta.merge(at: @world.now.utc.iso8601)
      end

      # One zone, up to MAX_ROOMS_PER_ZONE rooms (rooms arrives already
      # nearest-first and already truncated by Probe.rank -- this method
      # does not re-sort or re-slice it). Stops the instant one attempt
      # reaches the zone; tries the rest only while every attempt so far has
      # failed to.
      def attempt(zone, rooms)
        @visited += 1
        zone_rooms = @world.rooms_for_tag(zone.key)
        tried = []
        room = nil
        verdict = nil
        line = nil
        engaged = false
        elapsed = nil

        signature = nil
        crossings = []

        rooms.each_with_index do |(room_id, distance), index|
          # Announced BEFORE the walk, never after. An attempt can take the
          # best part of a minute and ends with go2 being killed, so without
          # a line first the operator watches a silent pause and cannot tell
          # a new zone from the same one wedged again.
          @world.announce(zone, room_id, index + 1, rooms.size)
          # BEFORE the walk, because this is a fact about the route from where
          # the character stands RIGHT NOW and walk_to is about to move them.
          # Asking afterwards would price the trip from the far end.
          crossings = @world.ferries_to(room_id)
          @world.reset_capture
          arrived, timed_out, elapsed = @world.walk_to(room_id, Probe.deadline_for(distance))
          tried << room_id
          room = room_id
          line = @world.blocking_line
          engaged = @world.engaged?
          here = @world.current_room_id
          verdict = Probe.verdict(arrived: arrived, current_room_id: here,
                                  zone_rooms: zone_rooms, blocking_line: line, timed_out: timed_out)

          break if verdict == :reached

          # Between rooms, not only between zones -- walk_to's own
          # engaged-relaunch branch can keep the 90 s stall watchdog from
          # ever firing (37-zone-probe-spec.md:341-345), so this is the
          # only place inside one zone's attempt that ever gets a chance to
          # notice an abort before all MAX_ROOMS_PER_ZONE rooms are burned.
          break if @world.abort_reason

          # SAME PLACE, SAME REFUSAL: it is one barrier, not several, and the
          # remaining rooms are behind it too. Trying three rooms exists to
          # find a SECOND ENTRANCE, so it is only worth paying for while the
          # attempts are actually landing somewhere different.
          #
          # This is not hypothetical. The zone `rats_lumber` has three tagged
          # rooms (13171, 13172, 13173) and every route to all three goes
          # through one step, `go stacks of lumber` out of room 6054. The
          # probe paid the full stall timeout three times over for a single
          # blocked doorway, and the character stood there long enough to be
          # found by a ship's rat.
          #
          # The signature carries the LINE as well as the room, so two
          # genuinely different barriers that happen to leave the character
          # in the same place still earn their own attempts. A nil line
          # compares equal to a nil line, which is deliberate: an unrecognised
          # refusal repeating in one spot is exactly the case this catches.
          signature_now = [here, line]
          break if signature_now == signature

          signature = signature_now
        end

        record_for(zone.key, verdict, room: room, rooms_tried: tried, line: line,
                                       engaged: engaged, elapsed: elapsed, crossings: crossings)
      end
    end
  end
end
