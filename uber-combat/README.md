# uber-combat

A Lich port of the Uber Combat DragonRealms script suite. The port is a
black-box reimplementation from the published feature list. It reuses existing
dr-scripts wherever possible, and it never forks `combat-trainer.lic`.

Design notes, specifications and the progress ledger live outside this
repository, in `dragonrealms/notes/uber-combat/`. Start at `99-progress.md`.

## What is built

Wave 6 delivered the zone picker core. The core is pure computation. It needs
no game connection, and it issues no game commands.

| File | Contents |
| --- | --- |
| `lib/uc_character.rb` | Rank metric, defensive metric, the two offense sets |
| `lib/uc_zone_table.rb` | Loader for `base-uc-zones.yaml`, critter lookup |
| `lib/uc_zone_picker.rb` | Admissibility, clustering, the itinerary builder |

Not built yet: the healing selector, leg advancement, session state, and the
director loop.

## Tests

```sh
cd custom-scripts/uber-combat
bundle install
rspec
```

Run the linter from the repository root, not from this directory. The
`.rubocop.yml` loads a custom cop through a relative path, so it resolves only
from `custom-scripts/`:

```sh
cd custom-scripts
rubocop uber-combat
```

The custom cop rejects non-ASCII source. Write no arrows, no em dashes and no
smart quotes in `.rb` files.

The suite runs in one process and needs no game runtime. `spec/support/` holds
the two doubles. `FakeSkills` mirrors the real `DRSkill.getmodrank` contract:
an unmodified skill reports `modrank == rank`, never zero.

## The data file

`data/base-uc-zones.yaml` is the source of truth. It annotates
`dr-scripts/data/base-hunting.yaml` with rank bands, critter rosters and
per-critter records.

The runtime needs its own copy at
`lich-5/scripts/data/custom/base-uc-zones.yaml`. The two copies must stay
byte-identical. Edit the source, then mirror it:

```sh
cp data/base-uc-zones.yaml ../../lich-5/scripts/data/custom/base-uc-zones.yaml
cmp data/base-uc-zones.yaml ../../lich-5/scripts/data/custom/base-uc-zones.yaml
```

Do not edit the runtime copy. Commit only the source copy.

Keep the `base-` prefix. Lich globs `base*.yaml` and builds the name with
`to_base_filename` (`setup_files.rb:201-203`), so `get_data('uc-zones')` finds
the file only with that prefix.

## The runtime library path

Lich loads library code from `lich-5/scripts/custom/lib/`. Each file in `lib/`
is symlinked there, so no mirror step applies to code:

```sh
cd ../../lich-5/scripts/custom/lib
ln -sfn ../../../../custom-scripts/uber-combat/lib/uc_character.rb uc_character.rb
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
