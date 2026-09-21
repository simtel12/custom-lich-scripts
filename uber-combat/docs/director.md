# Running the director

Part of the [uber-combat](../README.md) documentation.

    ;uc-director            plan only, read-only, issues nothing
    ;uc-director run N      N stints that actually hunt
    ;uc-director cycles N   N full passes through the itinerary
    ;uc-director next       one leg: the one holding the stalest skill
    ;uc-director report     the last run's stint table

`run` counts stints that hunted. A stint that never reached the hunt loop does
not spend a unit, so `run 4` promises four real hunts rather than four
attempts.

`cycles` counts full passes. A pass is however many legs the itinerary holds
at the time.

Prefer `cycles` when you mean "go round once". One stint is one leg today,
because a leg hands over after a single productive stint, but the leg COUNT
moves on its own as `max_skills_per_leg` splits a cluster or a rebuild returns
a different itinerary. A stint budget chosen to mean one pass quietly stops
meaning it; a cycle budget does not.

Neither form has an unbounded mode, and the count is required. One leg is half
an hour of unattended combat.

`next` hunts one leg and stops after its first productive stint. It picks the
leg holding the one skill that has gone longest without a productive stint. A
skill never trained counts as the stalest, and ties go to itinerary order, so a
first `next` takes the leg `run 1` would.

Every mode records the history `next` reads, in `CharSettings` under
uc-director: when each skill last rode a productive stint, and when each zone
last failed to hunt. A skill counts as trained when its leg was productive,
whether or not that one skill gained a rank.

A leg that fails to hunt is retried once, then `next` moves to the next-stalest
leg. The failure also sends that leg to the back of the order for later runs,
as if it had just been hunted. Without that, a leg that can never hunt would
never get a timestamp and would be picked first every time.

Bare `;uc-director` prints the order `next` would use and why.
