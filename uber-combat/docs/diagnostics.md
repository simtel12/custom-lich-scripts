# The diagnostics

Part of the [uber-combat](../README.md) documentation.

`uc-zones.lic` needs a game session. Run it as `;uc-zones`. It reads the
current character, asks the picker for its itinerary and its admissible zones,
and orders those zones by travel distance from the current room. It issues no
game command and changes no state.

Distance comes from one `Room#dijkstra` call, not from
`Map.find_all_nearest_by_tag`. That method sorts by a Dijkstra run and then
discards the distances (`map_base.rb:887-894`), so it cannot compare one zone
against another.

Bare `;uc-leg`, `;uc-probe` and `;uc-director` are all read-only in the same
way. That is a rule, not a coincidence: the mode a person reaches for by habit
must never change anything.

## Ferries

`uc-zones`, `uc-leg`, `uc-director` and `uc-probe` all name the crossings on
the route to a zone. A `FERRY` column on a candidate row, a `ferry=` line under
an itinerary leg, and a `crossings:` key in a probe record all mean the same
thing: getting there puts the character on a boat and the trip pays a wait for
it, out and back.

`uc-leg` prints the `ferry=` line under each itinerary leg and again for the leg
`write N` or `go N` acts on. `uc-director` prints it under each leg of the plan
itinerary, and again under the status line when a run selects a leg. That
second one is checked from where the character stands as the stint starts, not
from where the itinerary was built.

`uc-leg` and `uc-director` read the route off the same Dijkstra search the
distance preference ranks zones by (`Ferry::ZoneRoutes` over
`ZoneDistance::Live`), so the ferry named is on the route to the very room the
zone was measured to, and it costs no second search. A ferry check that fails
prints one line and reports no ferry; it never stops an itinerary or a run.

This is DETECTION ONLY. Nothing excludes a zone, reorders a candidate or
changes a verdict on it. It exists because `DIST` is Dijkstra seconds and a
Dijkstra second is not a wall-clock second on a leg that waits for a ferry to
dock, so the nearest zone on the list is not always the quickest trip.

It is answered PER CHARACTER, and that is the whole difficulty. The route is
taken from a live `Map.findpath`, because a map edge's `timeto` StringProc
closes that edge for a character who lacks the mount or the Athletics it asks
for -- a swimmer and a ferry passenger cross the Segoltha on genuinely
different edges, and a reimplemented search gets this wrong. `bescort` then
makes a second decision of its own that the map does not model at all:
`faldesu` swims at Athletics modrank 140 and takes the Riverhaven ferry below
it, over one single map edge. `lib/uc_ferry.rb` resolves that half.

`bescort segoltha` is NOT a ferry. It swims or flies, and the Crossing ferry is
the separate `ferry` escort.

`;uc-director` HAS NEVER BEEN RUN IN GAME, in any mode. The whole director is
argued from source and covered by unit tests, and nothing about it has been
observed under a real hunt.
