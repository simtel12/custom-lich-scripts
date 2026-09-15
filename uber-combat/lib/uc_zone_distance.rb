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
    def initialize(distances, rooms_for)
      @distances = distances
      @rooms_for = rooms_for
    end

    # The cost to the zone's nearest reachable room, or nil when no room of
    # the zone is reachable from here.
    def call(zone_key)
      @rooms_for.call(zone_key).filter_map { |id| @distances[id] }.min
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
    #
    # One Dijkstra run per room, reused for every zone asked about from it.
    # Returns nil for every zone when the room is unknown, which leaves the
    # picker on its band-width tie-break rather than stopping it.
    def self.live
      rooms_for = rooms_lookup
      cached_room = nil
      cached = nil
      lambda do |zone_key|
        room = Room.current
        next nil unless room

        unless cached_room == room.id
          cached_room = room.id
          _previous, distances = room.dijkstra
          cached = distances && new(distances, rooms_for)
        end
        cached&.call(zone_key)
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
