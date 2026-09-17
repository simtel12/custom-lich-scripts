# frozen_string_literal: true

# Travel distance from where the character stands to each zone.
#
# ZonePicker uses it to choose among the zones a leg could hunt: of the
# candidates that fit, the nearest one wins. Before this existed the picker
# chose by band width alone, so a character standing in Shard was sent to
# Ratha whenever a Ratha zone's band happened to be the narrowest.
#
# The picker never touches the map. It is handed an object that answers
# #call(zone_key) with a distance, or nil when the zone cannot be reached, so
# every spec can pass a plain Hash-backed lookup instead.
module UberCombat
  class ZoneDistance
    # distances: Hash of room id => travel cost, as Room#dijkstra returns its
    # second element (map_base.rb:774). rooms_for: callable, zone key =>
    # Array of room ids for that zone.
    # previous: the FIRST element of the same Room#dijkstra, and origin: the
    # room it was run from. Both optional, and kept only so another lookup can
    # reconstruct the route to the room this one measured without searching
    # again (Ferry::ZoneRoutes does).
    def initialize(distances, rooms_for, previous: nil, origin: nil)
      @distances = distances
      @rooms_for = rooms_for
      @previous = previous
      @origin = origin
    end

    attr_reader :previous, :origin

    # The cost to the zone's nearest reachable room, or nil when no room of
    # the zone is reachable from here.
    def call(zone_key)
      nearest_room(zone_key)&.last
    end

    # [room_id, cost] for the zone's nearest reachable room, or nil. The room
    # is the one the distance was measured to, so a report about the ROUTE to
    # a zone can ask about the same room the picker ranked it by.
    def nearest_room(zone_key)
      @rooms_for.call(zone_key).filter_map { |id| (cost = @distances[id]) && [id, cost] }.min_by(&:last)
    end

    # How a report prints a distance. 'unknown' covers both a zone with no
    # reachable room and a picker that was given no distance at all.
    def self.label(distance)
      distance ? format('%.1f', distance) : 'unknown'
    end

    # The Lich entry point. Answers for the room the character is in AT THE
    # TIME OF THE CALL, not the room they were in when this was built: the
    # director rebuilds its itinerary after walking to town and back, and a
    # distance measured from the start room would be stale by then.
    def self.live
      Live.new(rooms_lookup)
    end

    # One Dijkstra run per room, reused for every zone asked about from it, and
    # shared with anything else that asks for #survey (the ferry check).
    # Answers nil for every zone when the room is unknown, which leaves the
    # picker on its band-width tie-break rather than stopping it.
    #
    # current_room is injectable so the per-room caching is testable without
    # Lich. The default is resolved late, so loading this file never touches
    # Room.
    class Live
      def initialize(rooms_for, current_room: nil)
        @rooms_for = rooms_for
        @current_room = current_room || -> { Object.const_get(:Room).current }
        @room_id = nil
        @survey = nil
      end

      def call(zone_key)
        survey&.call(zone_key)
      end

      # The ZoneDistance for the room the character stands in now, or nil when
      # the room is unknown or the search failed.
      def survey
        room = @current_room.call
        return nil unless room

        unless @room_id == room.id
          @room_id = room.id
          previous, distances = room.dijkstra
          @survey = distances && ZoneDistance.new(distances, @rooms_for, previous: previous, origin: room.id)
        end
        @survey
      end
    end

    # The rooms hunting-buddy will actually walk to for a zone key
    # (hunting-buddy.lic:367-378 reads hunting_zones from base-hunting.yaml),
    # plus any map room tagged with the key. The tags cover a zone that is in
    # the map but missing from the hunting data; the hunting data is what the
    # hunt itself uses, so it is never skipped when it has the zone.
    def self.rooms_lookup
      hunting_zones = get_data('hunting').hunting_zones || {}
      lambda do |zone_key|
        (Array(hunting_zones[zone_key]) + Map.rooms_by_tag(zone_key)).uniq
      end
    end
  end
end
