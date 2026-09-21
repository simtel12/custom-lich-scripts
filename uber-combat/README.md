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

## Installation

### What it needs

- **Lich 5 with the DragonRealms scripts.** uber-combat does not fight. It
  writes a profile overlay and hands the hunt to `hunting-buddy.lic`, which
  drives `combat-trainer.lic`, and it travels with `go2.lic`. It also reads two
  dr-scripts data files, `base-hunting.yaml` and `base-spells.yaml`.
- **No runtime gems.** Every library is pure Ruby plus stdlib YAML. The
  `Gemfile` is for the test suite alone, and nothing under `lib/` or in a
  `.lic` needs bundler at run time.
- Whatever Ruby your Lich runs. This is developed against 4.0.5.

### Where the files go

Three destinations under your Lich `scripts/` directory:

| From this repo | To | How |
| --- | --- | --- |
| `uc-zones.lic`, `uc-leg.lic`, `uc-probe.lic`, `uc-director.lic` | `scripts/custom/` | symlink |
| `uc-director-plugin-town.rb` | `scripts/custom/` | symlink |
| `lib/uc_*.rb`, twelve files | `scripts/custom/lib/` | symlink |
| `data/base-uc-zones.yaml` | `scripts/data/custom/` | symlink |

None of those paths is a preference. The scripts build them: a `.lic` resolves
its libraries as `SCRIPT_DIR/custom/lib`, the director globs
`SCRIPT_DIR/custom/uc-director-plugin-*.rb` to find its plugins, and the zone
table arrives through `get_data('uc-zones')`, which globs `base*.yaml` across
`scripts/data` and `scripts/data/custom`. That last glob is also why the file
has to keep its `base-` prefix.

Everything is symlinked, so an edit or a `git pull` in the checkout is live on
the next run and there is no copy step to forget.

### Doing it

```sh
UC=~/code/dragonrealms/custom-scripts/uber-combat   # this repo
LICH=~/code/dragonrealms/lich-5                     # your Lich install

mkdir -p "$LICH/scripts/custom/lib" "$LICH/scripts/data/custom"

ln -sfn "$UC"/uc-*.lic                "$LICH/scripts/custom/"
ln -sfn "$UC"/uc-director-plugin-*.rb "$LICH/scripts/custom/"
ln -sfn "$UC"/lib/uc_*.rb             "$LICH/scripts/custom/lib/"

ln -sfn "$UC"/data/base-uc-zones.yaml "$LICH/scripts/data/custom/"
```

Re-running it is harmless. There is no separate update step: nothing is copied,
so a pull in the checkout is already live.

Lich only ever reads its data files, and it decides freshness by hashing their
content rather than by mtime, so linking the zone table in is safe in the
direction that would matter and an edit is picked up on the next read.
[`docs/data-file.md`](docs/data-file.md) covers the file itself.

### Per character

Add a `uc_settings` block to `<Character>-setup.yaml` in your profiles
directory. Only the `weapons` catalogue is required, because it is also the
list of what to train; everything else has a default.
[`docs/settings.md`](docs/settings.md) documents every key, and
[`docs/worked-example.md`](docs/worked-example.md) shows a complete real one
alongside the legs it produces.

### Checking it worked

```
;uc-zones
```

It reads the character, prints the itinerary and the candidate zones nearest
first, issues no game command and changes nothing. If the zone table did not
install, this is where it says so, naming the file it could not load. Bare
`;uc-leg`, `;uc-probe` and `;uc-director` are read-only in the same way.

### Files the suite writes for you

Neither of these is installed, and neither should be hand-edited.

| File | Written by |
| --- | --- |
| `scripts/profiles/<Character>-uc.yaml` | `;uc-leg write N`, `;uc-leg go N`, and every director stint |
| `scripts/data/custom/uc-probe-results.yaml` | `;uc-probe report` |

The overlay is rewritten on every leg change, so it carries a marker as its
first line:

    # GENERATED by uc-leg -- do not edit, it is overwritten on every leg change.

The writer overwrites a file only when that exact line is already at the top of
it, or when there is no file at all. Aim it at a profile you wrote by hand and
it refuses the write rather than destroying your work.

### A note on `load`

The scripts use `load`, not `require`, so an edit to a library file takes
effect on the next run without a Lich restart. Ruby prints an
"already initialized constant" warning on every run after the first. That is
the cost of `load` and it is expected.

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
