# Settings

Part of the [uber-combat](../README.md) documentation.

Everything the suite reads from a character lives under one `uc_settings` block
in `<Character>-setup.yaml`. All of it is optional except the catalogues.

| Key | Meaning |
| --- | --- |
| `weapons` | Skill to weapon-name catalogue. It is also the list of what to train. See below |
| `spells` | Offensive-spell catalogue, matched to a leg by its own `skill` key. See below |
| `premium` | The account tier. Defaults to non-premium, which gates conservatively |
| `in_province_only` | Stay inside one province, for example `Zoluren`. Blank or absent means no limit |
| `max_skills_per_leg` | How many killing skills a leg may carry. Absent means the default |
| `hunt_duration_minutes` | Minutes to hunt in one stint. Absent means 30 |
| `require_creature_flags` | Gates every creature in a zone must pass: `living`, `construct_or_undead`, `corporeal`. See below |

[`worked-example.md`](worked-example.md) works this whole block through end to
end on one real character, from the `exp` output to the four overlays, and ends
with a table of what each setting would have changed.

## The weapons catalogue is the list of what to train

Leave a weapon out and the character does not train it. That is not an error
and not a gap: the skill never reaches a leg at all, so nothing refuses to run.

A skill named only in `spells` counts too, since a skill can be trained by
casting rather than by swinging.

A **misspelled** skill name is an error, and the scripts stop. The valid names
are a closed set, so `Small Edge` is detectably not a decision to skip
`Small Edged`. The message names the bad key, says which catalogue it came
from, and suggests the real name when one is close:

    uc: uc_settings names skills that do not exist. Fix these and run again:
        weapons: Small Edge   did you mean Small Edged

`Debilitation` is rejected as a `weapons` key even though the name is real. It
cannot be trained by swinging anything, so a weapon entry for it is a mistake.
It belongs in `spells`.

A skill the character has ranks in but never named at all is reported once per
run as `not_configured`. That is information, not a fault, and it refuses
nothing.

An **empty** `weapons` catalogue is an error, and the scripts stop. Omitting a
weapon is a choice; omitting all of them leaves nothing to hunt with.

A magic-led leg borrows its stance key from the highest weapon the character
actually trains, not simply the highest weapon it has ranks in. Combat-trainer
keys stances on the equipped weapon, so a stance written for a weapon that is
never held is one combat-trainer never reads.

## How a spell reaches a leg

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

## The one combination to avoid

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

## Keeping a guild to the creatures it can hunt

`require_creature_flags` lists gates, and a zone is used only if every creature
on its roster passes all of them. Combat-trainer attacks everything in the
room, so one creature that fails makes the whole zone unusable.

| Gate | Passes | Who lists it |
| --- | --- | --- |
| `construct_or_undead` | constructs and undead | Empaths, who may attack nothing else |
| `living` | creatures that are neither | Necromancers, who learn no Thanatology from the other kind |
| `corporeal` | creatures an ordinary weapon can touch | Everyone who is not a Cleric |

An empath lists `construct_or_undead` and `corporeal`. A necromancer lists
`living` and `corporeal`.

```yaml
uc_settings:
  require_creature_flags:
    - living
    - corporeal
```

A creature Elanthipedia has no data for fails every gate. A misspelled gate, a
value that is not a list, and `construct_or_undead` with `living` (which no zone
can pass) all stop the scripts with a message. A skill that loses every zone to
these gates is reported as `creature_flags_excluded`.

## Testing a cycle quickly

At the default of 30 minutes a three-leg pass takes about two hours, which is
a long wait to find out whether rotation works. Set the duration low, watch a
whole pass, then set it back:

```yaml
uc_settings:
  hunt_duration_minutes: 5
```

The stint TIMEOUT does not shrink with it, and must not. The timeout bounds
the untimed parts of a stint -- tannery trip, blocking restock, travel to the
zone, walk home -- and those cost the same whether the hunt is five minutes or
fifty. A five-minute stint still takes about thirteen minutes of wall clock,
and nearly all of the saving is in the hunting.

The banner prints the value in force on every run, so a low test value left in
a profile is visible rather than silently making the character train badly.
