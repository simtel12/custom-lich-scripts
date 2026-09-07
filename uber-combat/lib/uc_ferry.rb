# frozen_string_literal: true

# Ferry detection: does the route to a zone put the character on a boat?
#
# DETECTION ONLY (user, 2026-09-07). Nothing here excludes a zone, reorders a
# candidate list or changes a verdict. It answers one question -- "will this
# trip be slowed by waiting for a vehicle" -- and hands the answer to a report.
#
# WHERE THE FACT LIVES. A ferry is not a property of a zone; it is an EDGE in
# the map graph. Lich stores a crossing as a `;e `-prefixed wayto step that
# starts bescort and blocks until it finishes (map_base.rb:377 turns the `;e `
# prefix into a StringProc at load). Room 957 -> 1904, the Crossing dock:
#
#   ;e if Script.exists?('bescort'); start_script('bescort', ['ferry', 'leth']);
#      wait_while{ running?('bescort') }; else; ... end
#
# There are 80 such edges in the current map file under about 50 distinct
# escort names, so the question is answerable by reading the path the character
# will actually walk.
#
# WHY THE PATH MUST COME FROM A LIVE Map.findpath, AND NOT FROM A REIMPLEMENTED
# SEARCH (user, 2026-09-07: "honor the StringProcs ... if the character [can]
# swim instead of take the ferry then we need to be aware"). An edge's `timeto`
# is frequently a StringProc that returns nil to CLOSE that edge for this
# character, and Map#dijkstra drops any edge whose weight comes back nil
# (map_base.rb:814-822). The Segoltha is the worked example, and it has three
# separate edges into room 19373:
#
#   922   -> 19373  ;e unless get_settings.flying_mount then nil else 7 end
#   15888 -> 19373  ;e unless DRSkill.getmodrank('Athletics') > 500 && ... then nil else 20.0 end
#   957   -> 1904   the Crossing ferry, open to everybody with the fare
#
# A character with a flying mount flies, a character with 500 Athletics swims,
# and only the character with neither is put on the boat. That is decided by
# evaluating the StringProcs against the LIVE character, which is exactly what
# Map.findpath already does and what an offline model reliably gets wrong.
#
# THE SECOND HALF OF THE SAME PROBLEM, and this one Map.findpath does NOT solve.
# Some escorts branch INSIDE bescort, after the edge has already been chosen.
# `faldesu` swims when the character has a flying mount or Athletics modrank
# >= 140 and calls take_rh_ferry otherwise (bescort.lic:1112-1133) -- one map
# edge, two completely different trips. Those are in CONDITIONAL below and are
# resolved here, from the same two character facts bescort itself reads.
#
# DEPENDS ON uc_character.rb, for UberCombat::LiveSkills -- and only on the
# lazy path, when LiveMap is built without a skills double. Both scripts that
# use this already load uc_character.rb first, and spec_helper requires it
# first; spec/uc_lic_loads_spec.rb is the guard that keeps a script from
# naming a constant it never loaded.
#
# AND `segoltha` IS NOT A FERRY, despite being the crossing most likely to be
# mistaken for one. bescort's segoltha (bescort.lic:1533) only ever swims or
# flies; the Crossing ferry is the separate `ferry` escort. Listing it in SWIMS
# rather than leaving it to the default is deliberate: the distinction is
# documented where someone checking will look for it.
module UberCombat
  module Ferry
    # The argument list of a start_script('bescort', [...]) call, as it appears
    # in a wayto StringProc's source. Anchored on the script name so an
    # unrelated `start_script` step cannot match.
    BESCORT_CALL = /bescort'\s*,\s*\[([^\]]*)\]/
    QUOTED_ARG = /'([^']*)'/

    # Escorts whose leg is ALWAYS a ride: the character boards a vehicle and
    # waits for it to arrive. Every one of these blocks on a `waitfor` or a
    # `pause until` for a departure or a docking, which is the slowness this
    # module exists to name.
    #
    # Cited from bescort.lic so the list can be rechecked rather than trusted:
    #   ferry (take_xing_ferry, 1948)      ferry1 (take_ain_ghazal_ferry, 1977)
    #   haven_throne (2039)                basalt (take_crawling_plague, 1288)
    #   lang_barge (take_rh_lang_barge, 2006)  sandbarge (791)
    #   gondola (ride_gondola, 1868)       mammoth (take_mammoth, 1265)
    #   jolas (620)                        airship (take_airship_muspari, 1338)
    #   balloon (1349)                     dirigible (1308)
    #   galley (take_m_m_galley, 523)      currach (587)
    #
    # galley and currach have no wayto edge in the current map file. They are
    # listed anyway: an escort that gains an edge in a later map release should
    # be classified when it arrives, not silently default to overland.
    VEHICLES = %w[
      ferry ferry1 haven_throne basalt lang_barge sandbarge gondola
      mammoth jolas airship balloon dirigible galley currach
    ].freeze

    # Escorts that cross water under the character's own power. No vehicle, no
    # departure to wait for. See this file's header for why segoltha is called
    # out by name instead of falling through to the default.
    SWIMS = %w[segoltha].freeze

    # Escorts that pick between the two at run time, keyed to the Athletics
    # MODRANK at or above which bescort swims. A flying mount also swims,
    # whatever the rank. Below the threshold and without a mount, it is a boat.
    #
    # faldesu: bescort.lic:1112-1133. `swim_faldesu` when @flying_mount is set
    # or getmodrank('Athletics') >= 140; take_rh_ferry otherwise.
    CONDITIONAL = { "faldesu" => 140 }.freeze

    # One bescort leg of a route.
    #   from/to  -- the wayto edge it sits on
    #   escort   -- the bescort escort name ('ferry', 'segoltha', ...)
    #   mode     -- the remaining bescort arguments ('leth', 'west', ...)
    #   kind     -- :vehicle, :own_power or :overland (see .kind)
    #   why      -- for a CONDITIONAL escort, what decided it. nil otherwise.
    # slow? is the whole point: a caller that only wants ferries filters on it
    # and never has to know the catalogue.
    Crossing = Struct.new(:from, :to, :escort, :mode, :kind, :why, keyword_init: true) do
      def slow?
        kind == :vehicle
      end

      # 'ferry leth', 'sandbarge hvaral muspari' -- how bescort would be
      # invoked, which is the form an operator can paste into a command line to
      # check the leg by hand.
      def to_s
        ([escort] + Array(mode)).join(" ")
      end
    end

    # The bescort arguments of a wayto step, or nil when the step does not
    # start bescort at all.
    #
    # source is the StringProc's SOURCE TEXT, not the object. Getting that text
    # is the caller's problem and it is not obvious: StringProc#class returns
    # Proc and StringProc#kind_of?(StringProc) is false, because both are
    # overridden to impersonate a Proc (stringproc.rb:16-22). `is_a?` and a
    # `case/when` both still work, and #_dump gives the source. LiveMap#steps
    # below is the one place that has to care.
    def self.call_args(source)
      return nil unless source.is_a?(String)

      match = BESCORT_CALL.match(source)
      return nil unless match

      match[1].scan(QUOTED_ARG).flatten
    end

    # How this character gets across, given the two facts bescort itself reads.
    #
    # athletics: getmodrank('Athletics'), or nil when unknown. An unknown rank
    #   resolves a CONDITIONAL escort to :vehicle, which is the conservative
    #   direction for a report about delay: naming a ferry that turns out to be
    #   a swim costs a line of output, missing one costs an unexplained wait.
    # flying_mount: get_settings.flying_mount, truthy when the character has one.
    def self.kind(escort, athletics: nil, flying_mount: false)
      return :vehicle if VEHICLES.include?(escort)
      return :own_power if SWIMS.include?(escort)

      threshold = CONDITIONAL[escort]
      return :overland unless threshold

      return :own_power if flying_mount
      return :own_power if athletics && athletics >= threshold

      :vehicle
    end

    # Why a CONDITIONAL escort resolved the way it did, so a report can say
    # "faldesu: Athletics 96 < 140" instead of only "ferry". nil for the
    # escorts that were never in doubt.
    def self.why(escort, athletics: nil, flying_mount: false)
      threshold = CONDITIONAL[escort]
      return nil unless threshold

      return "flying mount" if flying_mount
      return format("Athletics %d < %d", athletics, threshold) if athletics && athletics < threshold
      return format("Athletics %d >= %d", athletics, threshold) if athletics

      format("Athletics unknown, assuming < %d", threshold)
    end

    # Every bescort leg on a route, classified.
    #
    # steps: the route as [from_id, to_id, step_source_or_nil] triples, in
    #   travel order. A step whose source is not a bescort call is skipped, so
    #   a caller can hand over the whole route rather than pre-filtering it.
    #
    # Kept as plain triples rather than a Map-aware object for the same reason
    # Probe.partition takes an injected rooms_for_tag callable: the whole
    # classification stays testable with literals and no Lich runtime.
    def self.crossings(steps, athletics: nil, flying_mount: false)
      steps.filter_map do |from, to, source|
        args = call_args(source)
        next unless args

        escort = args.first
        Crossing.new(from: from, to: to, escort: escort, mode: args.drop(1),
                     kind: kind(escort, athletics: athletics, flying_mount: flying_mount),
                     why: why(escort, athletics: athletics, flying_mount: flying_mount))
      end
    end

    # Only the legs that will actually hold the character up. This is what
    # every caller in the scripts uses; #crossings is kept public because a
    # diagnostic that wants to show "swims the Segoltha" needs the rest.
    def self.ferries(steps, athletics: nil, flying_mount: false)
      crossings(steps, athletics: athletics, flying_mount: flying_mount).select(&:slow?)
    end

    # Routes questions to the live map. The one impure class in this file, and
    # the same seam LiveSkills is for Character (uc_character.rb:11-23): the
    # scripts build one of these, every test builds a double, and nothing above
    # this line ever names Map, DRSkill or get_settings.
    #
    # ACCURACY, stated plainly. Map.findpath runs Room#dijkstra over the same
    # graph, with the same StringProc evaluation, that go2 itself plans with
    # (go2.lic:2170 and :2256 both call Map.dijkstra and walk the `previous`
    # chain), so this predicts the route go2 will take. It is a prediction and
    # not a promise: go2 re-plans from wherever it actually stands after a
    # restart, and it will detour to a bank when a leg wants a fare it cannot
    # pay (go2.lic:2225). Both can move a trip onto an edge this did not name.
    #
    # It also only sees crossings the MAP models as edges. A script that calls
    # bescort itself, outside a wayto step, is invisible here.
    class LiveMap
      # Routes are memoised on the [from, to] pair. A findpath is a full
      # Dijkstra, and both callers ask per candidate zone -- the picker once
      # per leg, uc-zones once per printed row -- so without this a single
      # report is dozens of searches over an 18,900-room graph.
      #
      # It assumes the graph does not change under it, which is very nearly
      # true and not perfectly so: go2 nulls edges mid-run and restores them
      # in before_dying (go2.lic:948-953 is one such edit). The cost of being
      # wrong is one stale line in a report that changes no decision, which is
      # why the assumption is taken here and would not be taken by anything
      # that acted on the answer.
      # findpath: a callable (from_id, to_id) -> Array<Integer> of the rooms
      # AFTER the source, or nil when there is no path -- Map.findpath's own
      # contract (map_base.rb:845-865), which is the default.
      #
      # It is injectable because a caller that has ALREADY run a full
      # Room#dijkstra can reconstruct every path from the `previous` tree that
      # run returned, for free. uc-zones does exactly that: it prices its whole
      # candidate table off one search instead of one search per row. The
      # answers agree because both are the same algorithm over the same
      # weights, and Dijkstra settles a node's predecessor for good.
      def initialize(map: nil, skills: nil, settings: nil, findpath: nil)
        @map = map
        @skills = skills
        @settings = settings
        @findpath = findpath
        @routes = {}
      end

      # Reconstruct a findpath-shaped path from the `previous` Hash of a full
      # Room#dijkstra. Offered here rather than left to each caller because
      # getting it wrong is silent: an unreachable room and a room whose chain
      # loops both have to come back nil, not a partial path.
      def self.path_from(previous, from_id, to_id)
        from_id = from_id.to_i
        to_id = to_id.to_i
        return [] if from_id == to_id
        return nil unless previous[to_id]

        path = [to_id]
        seen = { to_id => true }
        until previous[path[-1]] == from_id
          step = previous[path[-1]]
          return nil if step.nil? || seen[step]

          seen[step] = true
          path.push(step)
        end
        path.reverse
      end

      # The route as .crossings wants it. nil -- not [] -- when there is no
      # path at all, so a caller can tell "cannot get there" apart from "gets
      # there without a boat".
      #
      # Map.findpath returns the rooms AFTER the source (map_base.rb:845-865),
      # so the source is prepended before pairing them up.
      def steps(from_id, to_id)
        key = [from_id.to_i, to_id.to_i]
        return @routes[key] if @routes.key?(key)

        @routes[key] = build_steps(from_id, to_id)
      end

      def ferries(from_id, to_id)
        route = steps(from_id, to_id)
        return nil if route.nil?

        Ferry.ferries(route, athletics: athletics, flying_mount: flying_mount?)
      end

      def crossings(from_id, to_id)
        route = steps(from_id, to_id)
        return nil if route.nil?

        Ferry.crossings(route, athletics: athletics, flying_mount: flying_mount?)
      end

      # Read once per instance. Both are constant for a session in every way
      # that matters here -- Athletics does not cross the faldesu threshold
      # mid-run -- and the picker asks for a route per candidate zone, so a
      # live read per call would be hundreds of DRSkill lookups for one answer.
      def athletics
        return @athletics if defined?(@athletics)

        @athletics = skills.modrank("Athletics")
      end

      def flying_mount?
        return @flying_mount if defined?(@flying_mount)

        @flying_mount = settings.flying_mount ? true : false
      rescue StandardError
        # A profile with no flying_mount key at all must read as "no mount",
        # not blow up a diagnostic that was only trying to print a table.
        @flying_mount = false
      end

      private

      def build_steps(from_id, to_id)
        path = @findpath ? @findpath.call(from_id, to_id) : map.findpath(from_id, to_id)
        return nil if path.nil? || path.empty?

        [from_id.to_i, *path].each_cons(2).map do |a, b|
          room = map[a]
          # wayto is keyed by room id as a STRING, throughout the map file and
          # throughout map_base.rb.
          [a, b, source_of(room && room.wayto[b.to_s])]
        end
      end

      # A wayto step is either a plain String direction ('west', 'go dock') or
      # a StringProc. Only the second can hold a bescort call, and getting its
      # source needs #_dump -- see .call_args for why the obvious type tests
      # lie about it.
      def source_of(step)
        return nil if step.nil?
        return step if step.is_a?(String)
        return step._dump if step.respond_to?(:_dump)

        nil
      end

      # Resolved late so that merely loading this file never touches the Lich
      # runtime. The scripts pass nothing and get the real globals; the specs
      # pass doubles.
      def map
        @map ||= Object.const_get(:Map)
      end

      def skills
        @skills ||= LiveSkills.new
      end

      def settings
        @settings ||= get_settings
      end
    end
  end
end
