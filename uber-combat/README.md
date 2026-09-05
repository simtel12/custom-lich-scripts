# uber-combat

A Lich port of the Uber Combat DragonRealms script suite. The port is a
black-box reimplementation from the published feature list. It reuses existing
dr-scripts wherever possible, and it never forks `combat-trainer.lic`.

Design notes, specifications and the progress ledger live outside this
repository, in `dragonrealms/notes/uber-combat/`. Start at `99-progress.md`.

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
| `lib/uc_zone_table.rb` | Loader for `base-uc-zones.yaml`, zone readers, critter lookup through `critter_refs` |
| `lib/uc_zone_picker.rb` | Admissibility, clustering, stance derivation, the itinerary builder |
| `lib/uc_leg_tracker.rb` | Leg advancement: the hard exit, mindlock, no-gain, reselect |
| `lib/uc_leg_overlay.rb` | Maps a leg plus live character state to a complete profile overlay hash, and reports its gaps |
| `lib/uc_leg_settings.rb` | The one place Lich's `uc_settings` shape is read: weapons, spells, premium, `in_province_only`, `max_skills_per_leg` |
| `lib/uc_leg_writer.rb` | Writes the overlay atomically, refuses any gap, refuses to overwrite a foreign file |
| `lib/uc_probe.rb` | The reachability probe's decision core: partition, deadline, verdict, record, and `Probe::Session` |
| `lib/uc_director.rb` | The D1 hunt spine: pick a leg, write its overlay, run one bounded stint, measure it, advance or repeat |
| `uc-zones.lic` | Read-only diagnostic. Prints the itinerary and the candidate zones, nearest first |
| `uc-leg.lic` | `;uc-leg` prints a leg, `write N` writes its overlay, `go N` writes then launches hunting-buddy |
| `uc-probe.lic` | `;uc-probe` plans, `run N` walks a bounded budget of zones, `report` writes the results file |
| `uc-director.lic` | `;uc-director` plans read-only, `run N` runs N productive stints, `report` prints the last run |

Not built yet: the healing selector, and director parts D2 through D6 (the
fight boundary, the trigger and town cycle, session state, the robustness
watchdog, and the guild strategy objects).

## The diagnostics

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

`;uc-director` HAS NEVER BEEN RUN IN GAME, in any mode. The whole director is
argued from source and covered by unit tests, and nothing about it has been
observed under a real hunt.

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

341 examples, about 2 seconds, no game needed.

Run the linter from the repository root, not from this directory. The
`.rubocop.yml` loads a custom cop through a relative path, so it resolves only
from `custom-scripts/`:

```sh
cd custom-scripts
BUNDLE_GEMFILE=uber-combat/Gemfile bundle exec rubocop uber-combat
```

29 files, no offenses. The custom cop rejects non-ASCII source. Write no
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

## Settings

Everything the suite reads from a character lives under one `uc_settings` block
in `<Character>-setup.yaml`. All of it is optional except the catalogues.

| Key | Meaning |
| --- | --- |
| `weapons` | Skill to weapon-name catalogue. A leg skill with no entry is a gap, and a gap refuses the leg |
| `spells` | Offensive-spell catalogue, matched to a leg by its own `skill` key. See below |
| `premium` | The account tier. Defaults to non-premium, which gates conservatively |
| `in_province_only` | Stay inside one province, for example `Zoluren`. Blank or absent means no limit |
| `max_skills_per_leg` | How many killing skills a leg may carry. Absent means the default |

### How a spell reaches a leg

Two flags on the spell entry decide, and neither is required.

| Flags | Which legs | Does combat-trainer keep casting it |
| --- | --- | --- |
| neither, and the skill is Debilitation | every leg | yes |
| neither, any other skill | legs that train the skill | yes |
| `cast_only_to_train: true` | legs that train the skill | **no** |
| `use_for_survivability: true` | legs that train the skill | yes |

**`cast_only_to_train: true`** means the spell exists to train its skill. On a
no-gain streak combat-trainer removes the whole skill's spells
(`combat-trainer.lic:2458-2468`), which is correct for training and wrong for
anything else.

**`use_for_survivability: true`** places the spell exactly where
`cast_only_to_train` would, and differs only in that combat-trainer keeps
casting it. Use it for a spell whose value is its effect.

The real criterion for that placement is "creatures that can challenge our
defences", meaning Parry Ability, Shield Usage and Evasion sit below the
creature's upper rank. There is no such check. Training-leg placement is used
as a proxy, because a leg trains a skill only where the zone band admits that
skill's rank, and a rank-appropriate zone is broadly one whose creatures test
the character's defences. The proxy is imperfect and was chosen knowing that.

A **Debilitation** spell with no flags rides every leg, because Debilitation
is a multiplier: it makes the character likelier to hit, or likelier to be
missed, and does no damage by itself, so carrying it costs no attack time.
`use_for_survivability` NARROWS that back to the legs that train it.

No other skill ever rides every leg. A damage spell everywhere would displace
the leg's own training, because the overlay always sets
`prioritize_offensive_spells` and combat-trainer would cast instead of swing.

Debilitation never occupies a `max_skills_per_leg` slot, on any leg.

### The one combination to avoid

`use_for_survivability: true` with `cast_only_to_train: true` contradicts
itself. The placements agree, but the second asks combat-trainer to stop
casting once the spell stops teaching, which is the one thing the first exists
to prevent. Combat-trainer wins, because it owns the casting.

Worse, its blacklist works by SKILL, not by spell
(`combat-trainer.lic:2468`), so one sibling spell of the same skill carrying
`cast_only_to_train` is enough to silence a survivability spell that does not
carry it.

The overlay reports both shapes as a `survivability_blacklisted` gap rather
than dropping either flag, because dropping one would be a guess at which was
meant. A leg with any gap is refused, so nothing runs on a profile whose flags
disagree.

`max_skills_per_leg` is there because there is no single right value. A
character training two or three skills wants a cap that never bites. A
character training every allowed weapon and magic wants its legs divided
somewhere sensible. The default of 3 gives each skill about ten minutes of a
30-minute stint against about eight minutes of fixed overhead per stint
(tannery, restock, travel, walk home), and that ratio holds whatever the
character trains.

Lower it and each skill gets a bigger share, at the cost of more legs and one
more lot of overhead each. Raise it for cheaper cycles and a thinner share.

A value that is not a positive whole number is ignored, and the script says so
rather than falling back in silence.

## The data file

`data/base-uc-zones.yaml` is the source of truth. It annotates
`dr-scripts/data/base-hunting.yaml` with rank bands, critter rosters,
per-critter records, premium flags and the probe's reachability records.

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
