# uber-combat

A Lich port of the Uber Combat DragonRealms script suite. The port is a
black-box reimplementation from the published feature list. It reuses existing
dr-scripts wherever possible, and it never forks `combat-trainer.lic`.

## What is built

Wave 6 delivered the zone picker core. Wave 7 added leg advancement and the
stance ordering. Wave 8 added leg enactment through a profile overlay. Wave 9
added premium gating. Wave 10 added the reachability probe and its merge tools.
Wave 11 added the director hunt spine, D1.

Every library file is pure computation. It needs no game connection and it
issues no game commands. The four `.lic` scripts are thin: they own the Lich
calls and the printing, and they own no decision.

| File | Contents |
| --- | --- |
| `lib/uc_character.rb` | Rank metric, defensive metric, the two offense sets, the defence ordering, mindstate reads |
| `lib/uc_zone_table.rb` | Loader for `base-uc-zones.yaml`, zone and critter readers, critter lookup through `critter_refs`, the enrichment-flag rollups |
| `lib/uc_zone_picker.rb` | Admissibility, clustering, stance derivation, the itinerary builder, nearest-candidate zone choice |
| `lib/uc_zone_distance.rb` | Travel distance from the current room to a zone's hunting rooms. `ZoneDistance.live` is the one Lich-facing entry point; the lookup itself is pure |
| `lib/uc_leg_tracker.rb` | Leg advancement: the hard exit, mindlock, no-gain, reselect |
| `lib/uc_leg_overlay.rb` | Maps a leg plus live character state to a complete profile overlay hash, and reports its gaps |
| `lib/uc_leg_settings.rb` | The one place Lich's `uc_settings` shape is read: weapons, spells, premium, `in_province_only`, `max_skills_per_leg` |
| `lib/uc_leg_writer.rb` | Writes the overlay atomically, refuses any gap, refuses to overwrite a foreign file |
| `lib/uc_ferry.rb` | Ferry detection: reads the bescort crossings off the route this character would actually walk |
| `lib/uc_probe.rb` | The reachability probe's decision core: partition, deadline, verdict, record, and `Probe::Session` |
| `lib/uc_director.rb` | The D1 hunt spine: pick a leg, write its overlay, run one bounded stint, measure it, advance or repeat |
| `uc-zones.lic` | Read-only diagnostic. Prints the itinerary and the candidate zones, nearest first |
| `uc-leg.lic` | `;uc-leg` prints a leg, `write N` writes its overlay, `go N` writes then launches hunting-buddy |
| `uc-probe.lic` | `;uc-probe` plans, `run N` walks a bounded budget of zones, `report` writes the results file |
| `uc-director.lic` | `;uc-director` plans read-only, `run N` runs N productive stints, `next` hunts the stalest leg once, `report` prints the last run |

Not built yet: the healing selector, and director parts D2 through D6 (the
fight boundary, the trigger and town cycle, session state, the robustness
watchdog, and the guild strategy objects).

## Documentation

**New here? Start with [the worked example](docs/worked-example.md).** It takes
one character's `uc_settings` block through to the four legs and the overlays it
produces, and explains each step. The reference documents below state the rules
one at a time; that one shows what they do together.

| Document | Contents |
| --- | --- |
| [`docs/worked-example.md`](docs/worked-example.md) | One character end to end: ranks and config in, four legs and their overlays out |
| [`docs/settings.md`](docs/settings.md) | The `uc_settings` block: every key, the weapons and spells catalogues, the creature gates |
| [`docs/diagnostics.md`](docs/diagnostics.md) | The read-only modes, travel distance, and ferry detection |
| [`docs/director.md`](docs/director.md) | Running the director: `run`, `cycles`, `next` and `report` |
| [`docs/data-file.md`](docs/data-file.md) | `base-uc-zones.yaml`, the mirror rule, and the per-creature enrichment flags |

Design notes, specifications and the progress ledger live outside this
repository, in `dragonrealms/notes/uber-combat/`. Start at `99-progress.md`.

## Tests

```sh
cd custom-scripts/uber-combat
bundle install
rspec
```

723 examples, about 6 seconds, no game needed.

Run the linter from the repository root, not from this directory. The
`.rubocop.yml` loads a custom cop through a relative path, so it resolves only
from `custom-scripts/`:

```sh
cd custom-scripts
BUNDLE_GEMFILE=uber-combat/Gemfile bundle exec rubocop uber-combat
```

38 files, no offenses. The custom cop rejects non-ASCII source. Write no
arrows, no em dashes and no smart quotes in `.rb` files.

The suite runs in one process and needs no game runtime. `spec/support/` holds
the two shared doubles. `FakeSkills` mirrors the real `DRSkill.getmodrank`
contract: an unmodified skill reports `modrank == rank`, never zero. The two
injected world doubles are not shared and live in their own spec files, which
is why one of them is named `FakeDirectorWorld` rather than `FakeWorld`.

`spec/uc_lic_loads_spec.rb` reads every `.lic` as text and checks it both ways:
a lib is loaded for every `UberCombat::` constant the script names, and nothing
is loaded that the script does not use. A `.lic` names its own libs, so it can
use a constant it never loaded while the whole suite still passes.

## The runtime library path

The scripts use `load`, not `require`, so an edit to a library file takes
effect on the next run without a Lich restart. Ruby prints an
"already initialized constant" warning on every run after the first. That is
the cost of `load` and it is expected.

Lich loads library code from `lich-5/scripts/custom/lib/`, and scripts from
`lich-5/scripts/custom/`. Each file is symlinked there, so no mirror step
applies to code:

```sh
cd ../../lich-5/scripts/custom/lib
ln -sfn ../../../../custom-scripts/uber-combat/lib/uc_character.rb uc_character.rb
cd ..
ln -sfn ../../../custom-scripts/uber-combat/uc-director.lic uc-director.lic
```

## Rules that this code obeys

1. Every character-derived value is computed live. Nothing is pegged to a
   snapshot, and nothing reads a profile.
2. The picker is stateless. It caches nothing. Leg position, no-gain counters
   and cooldowns belong to session state.
3. A skill that gets no zone is reported with a reason. A silent cap reads as
   full coverage.
4. Cluster by bounded leg width. Never cluster by gap detection.
5. Resolve a critter through the zone's `critter_refs`. A bare noun lookup is
   ambiguous for 13 nouns across 32 zones.
6. `LegTracker` owns no cadence. The caller decides when a tick happens and
   when a fight ends. Give it no timer.
7. Debilitation can neither lead a leg nor end one. It is always a passenger.
8. The defence order chooses slot 3, not slot 1. Leave `strict_weapon_stance`
   false and let combat-trainer split the points between the first two.
9. The director measures the character, and never trusts a child script's own
   account of what it did. `hunting-buddy` leaves `hunt_stop_reason` nil on
   eleven exit paths, one of which is a Kernel `exit` that Lich records as a
   clean completion, so the handle and the reason together still cannot tell a
   half-hour of hunting from a stint that never left town. Rank movement
   between two live reads can.
