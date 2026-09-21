# The data file

Part of the [uber-combat](../README.md) documentation.

Every path and command in this document is relative to the repository root,
`custom-scripts/uber-combat`, not to this `docs/` directory.

`data/base-uc-zones.yaml` is the source of truth. It annotates
`dr-scripts/data/base-hunting.yaml` with rank bands, critter rosters,
per-critter records, premium flags and the probe's reachability records.

The runtime reaches it through `lich-5/scripts/data/custom/base-uc-zones.yaml`,
which is a **symlink back to this file**, not a copy. There is nothing to
mirror and nothing that can drift; see [Installation](../README.md#installation).

That matters more than it looks, because the file is loaded two different ways.
`ZoneTable.from_game_data` reads `get_data('uc-zones')`, which resolves to the
runtime path, and `ZoneTable.load` reads this one directly -- the specs use the
second, the game uses the first. While the runtime path was a copy, the data
integrity specs were validating a file the game did not load. The link makes
those two reads the same bytes by construction.

Linking is safe because Lich never writes a data file back: `setup_files.rb`
loads them with `YAML.unsafe_load_file` and has no write path for one, and it
decides whether a cached file is stale by hashing its content rather than by
mtime, so an edit here is picked up on the next read.

Keep the `base-` prefix. Lich globs `base*.yaml` and builds the name with
`to_base_filename` (`setup_files.rb:201-203`), so `get_data('uc-zones')` finds
the file only with that prefix.

## The per-creature enrichment flags

Every one of the 306 critter records carries `skinnable`, `drops_boxes`,
`construct`, `undead`, `cursed` and `corporeal`, harvested from elanthipedia's
`{{Critter}}` infobox, plus `skin_yields`: which of a skin, a part and a bone
the creature actually drops. See `notes/uber-combat/43-critter-enrichment.md`.

**Every flag is three-state, and null is not false.** `Template:Critter`
renders an absent field as "Unknown", so null means nobody has checked. 20
records have all seven null, because their page is missing or is a
disambiguation stub. Treat null as an exclusion wherever a false would have
admitted something.

**`skinnable` is not "yields a skin".** `|Skinnable=` only says the SKIN verb
does something here. The adult desert armadillo is skinnable and yields a
plated claw and no hide. A leg gathering skins reads `skin_yields`.

**`undead` and `cursed` are one field.** Elanthipedia's `|Evil=` is a four-way
alignment (`cursed` / `undead` / `holy` / `no`), so the two are never both true
and an absent `|Evil=` leaves both null rather than false. That is why
`Critter#construct_or_undead` -- the empath gate, since an empath may attack
only a construct or an undead -- answers nil rather than false when the
alignment is unknown. Attacking a living creature is a guild-law violation, not
lost yield, so `ZoneTable#all_construct_or_undead?` fails an unknown and fails
an empty roster.

**Skinning and dissecting are one permission.** If the SKIN verb works on a
creature then DISSECT does too, so `Critter#dissectable` is an alias of
`skinnable` rather than a second stored flag. A skinning leg and a First Aid
leg therefore select the same zones and differ only in what the overlay writes
into the `skinning` block.

**`corporeal` is an avoidance filter, and a separate axis from undeath.**
Incorporeal creatures resist ordinary weapons, so `ZoneTable#all_corporeal?`
admits a zone only when every rostered creature is known corporeal. 284 zones
pass; of the 79 refused, 16 hold a known incorporeal, 29 have no roster, and 34
are refused purely on an unknown flag.

A character can need this gate AND the empath one, because they answer
different questions: `all_construct_or_undead?` is guild law, what an empath
may attack, while `all_corporeal?` is capability, what a non-cleric can hurt.
An empath may and should fight a corporeal undead -- 35 of the 44 undead are
corporeal -- and cannot touch the other 9. So a real empath is admitted by the
intersection, which is **59** zones rather than 75. Neither flag substitutes
for the other: undeath does not imply incorporeality, and an emaciated
umbramagus is incorporeal without being undead.

**Necromancers need living creatures only.** Thanatology cannot be learned
from an undead or a construct. `Critter#living` is the inverse of
`construct_or_undead`, and it stays nil when either flag is unknown. Do not
write `!construct_or_undead`, because that turns every unknown into a living
creature. `ZoneTable#all_living?` admits 224 zones, or 220 with the corporeal
gate, since a necromancer is no cleric. No zone passes both the empath gate and
the necromancer gate.

The zone rollups (`qualifying_ratio`, `flag_census`, `all_construct_or_undead?`,
`all_living?`, `all_corporeal?`, `any_loot?`) are computed at load time and
never stored, per the data file's own rule. They put 293 zones in `normal`, 190
in `skin`, 140 in `lockpick`, 31 in `cleric`, 75 in `empath` and 224 in `necro`.

The picker consumes the three gates through `require_creature_flags` (see
[`settings.md`](settings.md)). Nothing else consumes the flags yet; `43-critter-enrichment.md`
proposes loot legs.
