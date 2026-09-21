# A worked example: Iruss

Part of the [uber-combat](../README.md) documentation.

One character, one `uc_settings` block, and the four legs the picker builds out
of them.

Read this after [`settings.md`](settings.md). That document states the rules
one at a time. This one shows what they do together, which is the part that is
hard to predict from the rules alone: the leg boundaries here are set by the
zone table, not by the cap everyone assumes is doing the work.

Every number below is taken from a live `;uc-leg` run and from
`data/base-uc-zones.yaml`.

## The character

`exp` for Iruss:

```
          SKILL: Rank/Percent towards next rank/Amount learning/Mindstate Fraction
    Shield Usage:     75 76% thoughtful     (4/34)     Light Armor:      6 74% clear          (0/34)
     Chain Armor:     78 06% clear          (0/34)      Brigandine:     84 78% clear          (0/34)
     Plate Armor:      4 31% clear          (0/34)       Defending:     81 31% clear          (0/34)
   Parry Ability:     89 42% clear          (0/34)     Small Edged:     81 16% clear          (0/34)
     Large Edged:     66 94% clear          (0/34) Twohanded Edged:      3 00% clear          (0/34)
     Small Blunt:     72 89% clear          (0/34)     Large Blunt:      3 00% clear          (0/34)
 Twohanded Blunt:      3 00% clear          (0/34)          Slings:     59 53% learning       (3/34)
             Bow:      3 00% clear          (0/34)        Crossbow:     58 68% clear          (0/34)
          Staves:      3 00% clear          (0/34)        Polearms:     57 77% clear          (0/34)
    Light Thrown:     65 74% clear          (0/34)    Heavy Thrown:      3 00% clear          (0/34)
        Brawling:     70 06% clear          (0/34)  Offhand Weapon:     51 49% clear          (0/34)
   Melee Mastery:     72 12% clear          (0/34) Missile Mastery:     62 97% clear          (0/34)
  Targeted Magic:     93 26% clear          (0/34)    Debilitation:     91 69% clear          (0/34)
         Evasion:     75 25% clear          (0/34)         Tactics:     97 85% clear          (0/34)
```

The picker reads two things off this and nothing else: the rank of every skill
it has been told to train, and the ranks of the three defences.

Percent towards the next rank is not one of them. Shield Usage shows 75 76% and
Evasion shows 75 25%, and the picker reads both as **75**. `Character#rank_of`
averages `DRSkill.getrank` and `DRSkill.getmodrank`, which are both whole ranks,
so those two defences are exactly tied. Remember that when the stance orders
below swap them.

Armour skills, Defending, the two masteries and Tactics never appear. They are
not in `KILLING_SET`, so they get no leg and are not reported as anything.

## The configuration

The whole `uc_settings` block from `Iruss-setup.yaml`:

```yaml
uc_settings:
  # Let's stay near the hometown.
  in_province_only: Zoluren

  premium: false

  weapons:
    Targeted Magic: bronze rapier
    Brawling: ''
    Small Edged: bronze rapier
    Small Blunt: lacquered cudgel
    Large Edged: condottiere
    Polearms: glaive
    Crossbow: light crossbow
    Slings: leather sling
    Light Thrown: wooden bola

  spells:
  - skill: Debilitation
    name: Electrostatic Eddy
    use_auto_mana: true
    cyclic: true
    use_for_survivability: true
  - skill: Targeted Magic
    name: Fire Ball
    use_auto_mana: true
```

Everything optional is left out. `max_skills_per_leg` is absent, so the default
of **3** applies. `require_creature_flags` is absent, so no creature gate
applies. `hunt_duration_minutes` is absent, so a stint is 30 minutes.

## What that declares

The `weapons` catalogue is the list of what to train, so these nine killing
skills are in play and no others:

| Skill | Rank | Weapon |
| --- | --- | --- |
| Targeted Magic | 93 | bronze rapier |
| Small Edged | 81 | bronze rapier |
| Small Blunt | 72 | lacquered cudgel |
| Brawling | 70 | `''` (bare hands) |
| Large Edged | 66 | condottiere |
| Light Thrown | 65 | wooden bola |
| Slings | 59 | leather sling |
| Crossbow | 58 | light crossbow |
| Polearms | 57 | glaive |

**Debilitation at 91 is in play too**, declared by the `spells` catalogue rather
than by `weapons`. A skill can be trained by casting instead of by swinging, and
the catalogue that names it is the one that counts.

Seven skills Iruss has ranks in are in neither catalogue: Offhand Weapon at 51,
and Twohanded Edged, Large Blunt, Twohanded Blunt, Bow, Staves and Heavy Thrown
at 3 apiece. Leaving a weapon out is how you say "do not train this", so none of
them reaches a leg and none of them is a fault. They are reported once per run
as `not_configured` by `;uc-zones`, which prints the unplaced list. `;uc-leg`
does not print it.

## The itinerary

```
=== uc-leg: Iruss, 363 zones loaded ===
-- Itinerary (build_itinerary) --
  Leg 1: Targeted Magic, Small Edged, Debilitation
    zone=young_ogres              distance=10.4     stance=concentrated defences=Parry Ability > Evasion > Shield Usage
  Leg 2: Small Blunt, Brawling, Large Edged
    zone=crossing_blood_wolves    distance=7.4      stance=spread       defences=Parry Ability > Shield Usage > Evasion
  Leg 3: Light Thrown, Slings, Crossbow
    zone=cave_bears               distance=13.4     stance=spread       defences=Parry Ability > Shield Usage > Evasion
  Leg 4: Polearms
    zone=revenant_conscripts      distance=5.8      stance=spread       defences=Parry Ability > Shield Usage > Evasion
```

Nine killing skills, a cap of three, and four legs rather than three. The rest
of this document is why.

## Why those four legs

`build_legs` sorts the killing skills by rank, highest first, and walks the list
greedily. Each pass takes the highest skill left as the leg's leader, then
absorbs every later skill that clears three tests:

1. within `LEG_WIDTH_RANKS` (40) of the leader,
2. the leg is not already full at `max_skills_per_leg` (3),
3. some single zone admits the leader and the candidate **together**.

Iruss's rank order, and the bands of the four zones the legs land on:

```
Targeted Magic  93        young_ogres            80 - 120
Small Edged     81        crossing_blood_wolves  60 -  75
Small Blunt     72        cave_bears             45 -  65
Brawling        70        revenant_conscripts    40 -  60
Large Edged     66
Light Thrown    65
Slings          59
Crossbow        58
Polearms        57
```

**Leg 1** leads with Targeted Magic at 93 and absorbs Small Edged at 81. Then it
stops, and *not* because it is full: it is using two of its three slots. The
width does not stop it either, since the whole vector spans 36 ranks
(93 down to 57) and the width allows 40. What stops it is test 3. A zone that
taught Targeted Magic at 93 and Small Blunt at 72 in one trip would need a band
reaching from 72 up to 93, and no Zoluren zone has one. **The third slot goes
unused because there is nowhere to spend it.**

**Leg 2** leads with Small Blunt at 72 and fills up: Brawling at 70 and Large
Edged at 66, all three inside crossing_blood_wolves at 60-75. Here the cap
genuinely bites. Light Thrown at 65 is inside the width *and* inside that band,
and it is turned away only because the leg already holds three.

**Leg 3** leads with Light Thrown at 65 and takes Slings at 59 and Crossbow at
58. Full again, so Polearms waits.

**Leg 4** is Polearms at 57 on its own, because nothing is left to cluster it
with. A skill that joins no cluster becomes its own single-skill leg. That is
less travel-efficient and it is correct: clustering is an optimisation, and it
must never starve a skill of its zone.

So the cap shaped legs 2 and 3, and the zone table shaped legs 1 and 4. Nine
skills with a cap of 3 does not mean three legs of three. The cap can only split
a cluster the band rule already allowed. It can never merge one.

## Why each leg got the zone it did

Every candidate zone already admits every skill on its leg, so the only thing
left to choose on is travel. The picker takes the **nearest** candidate, and
breaks a tie on the narrowest band.

**Leg 4 shows the preference working.** Polearms at 57 is admitted by cave_bears
(45-65) and by revenant_conscripts (40-60) alike. The itinerary takes
revenant_conscripts at distance 5.8 over cave_bears at 13.4.

**Leg 3 shows what overrides it.** Light Thrown at 65 would be perfectly happy in
crossing_blood_wolves at distance 7.4, half the trip. But Slings at 59 and
Crossbow at 58 both fall under that zone's floor of 60, so the leg goes to
cave_bears at 13.4 instead. The cluster pays the travel, not the leader.

`distance` is Dijkstra seconds from where the character stood when the itinerary
was built. It is not wall-clock, which is why ferries are reported separately.
No leg here crosses water, so no `ferry=` line appears.

## Why Debilitation rides Leg 1 and nothing else

Debilitation is always a passenger. It can neither lead a leg nor end one. It
joins every leg whose **chosen zone** admits its rank, and at 91 that is
young_ogres (80-120) and nothing else: crossing_blood_wolves tops out at 75,
cave_bears at 65, revenant_conscripts at 60.

So `Debilitation` appears in Leg 1's `stop_on` and in no other leg's:

```yaml
  stop_on:
  - Targeted Magic
  - Small Edged
  - Debilitation
```

Membership in that list means the leg **trains** the skill, which is exactly why
it cannot be handed to a leg whose band cannot teach it. `stop_on` is an `.all?`
condition, so a skill that could never lock there would hold the leg open
forever.

Note also that Leg 1 lists three skills while using two of its three slots.
Debilitation never occupies a slot on any leg, because legs are clustered out of
the killing skills and Debilitation is not one of them.

## Why Leg 1 stances differently

Iruss defends at Parry Ability 89, Shield Usage 75, Evasion 75. That gives two
numbers:

```
concentrated = 89                       the strongest defence, alone
spread       = (89 + 75 * 0.8) / 2      = 74.5
```

The picker prefers `spread`, because it keeps the lagging defence in play where
it can train, and falls back to `concentrated` only when spread cannot survive
the zone. It compares each against the zone's **floor**:

| Leg | Zone | Floor | spread = 74.5 | Stance |
| --- | --- | --- | --- | --- |
| 1 | young_ogres | 80 | too low | concentrated |
| 2 | crossing_blood_wolves | 60 | clears | spread |
| 3 | cave_bears | 45 | clears | spread |
| 4 | revenant_conscripts | 40 | clears | spread |

Leg 1 is the only leg whose zone outranks Iruss's spread defence, so it is the
only leg that concentrates. Nothing in the configuration asked for this.

## Why the two stance shapes look nothing alike

They are two different ways of talking to combat-trainer, and the overlay picks
by policy.

A **spread** leg writes `stances`, one entry per weapon in `weapon_training`,
each holding the full order:

```yaml
stances:
  Small Blunt:
  - Parry Ability
  - Shield Usage
  - Evasion
  Brawling:
  - Parry Ability
  - Shield Usage
  - Evasion
  Large Edged:
  - Parry Ability
  - Shield Usage
  - Evasion
```

A **concentrated** leg writes an empty `stances` and a single `priority_defense`
instead:

```yaml
stances: {}
priority_defense: Parry Ability
```

Both orders come from the same live ranks. `concentrated` is
`[strongest, middle, lagging]` and `spread` is `[strongest, lagging, middle]`,
which is why Leg 1 reads Parry > Evasion > Shield and Legs 2-4 read
Parry > Shield > Evasion. **Since Shield Usage and Evasion are tied at 75, that
swap is the tie breaking arbitrarily, not a judgement about them.** Parry
Ability leads either way, because 89 is unambiguous.

What the order really controls is the **third** slot. With `strict_weapon_stance`
left false, combat-trainer re-sorts the first two by learning need on every
combat cycle and leaves the third alone. So the policy chooses which defence is
banished: `spread` banishes the middle one and keeps the lagging one training,
`concentrated` banishes the lagging one.

## Why Leg 4 carries `args: [undead]`

```yaml
  args:
  - undead
```

That is not configuration and Iruss never asked for it. It is read off the
zone's roster: every creature in revenant_conscripts is `undead: true`, so the
overlay passes combat-trainer the `undead` arg. A zone with a mixed roster, an
unknown creature or no roster at all gets no arg. hunting-buddy appends its own
`uc` flex suffix afterwards, so combat-trainer receives `["undead", "uc"]`.

The arg is written for every guild, because it is a fact about the zone rather
than about the character.

## Why there are no gaps

Two entries look like they should be gaps and are not.

**Brawling's weapon is the empty string**, and that is a real entry meaning bare
hands. Membership is tested with `key?`, never with truthiness, so `''` is a
weapon rather than a missing one. Leg 2's overlay writes it through unchanged:

```yaml
weapon_training:
  Small Blunt: lacquered cudgel
  Brawling: ''
  Large Edged: condottiere
```

**Debilitation has no `weapons` entry at all**, and that is not a gap either,
because the `spells` catalogue covers it. A skill trained by casting needs
nothing to swing, so it is exempt from the weapon check. That is why Leg 1's
`weapon_training` has two entries for three skills.

Had Debilitation landed on a leg with neither a weapon entry nor a spell
covering it, the overlay would report `no_weapon_entry`, and the writer would
refuse the leg. A leg with any gap is refused, so the run stops rather than
launching a hunt that would fail later.

## Leg 1 in full, annotated

```yaml
hunting_info:
- :zone:
  - young_ogres            # nearest candidate admitting 93 and 81
  stop_on:
  - Targeted Magic
  - Small Edged
  - Debilitation           # passenger: this band is the only one that teaches 91
weapon_training:
  Targeted Magic: bronze rapier   # a caster still holds a weapon
  Small Edged: bronze rapier
                           # no Debilitation entry: the spell catalogue covers it
stances: {}                # concentrated, so the order goes in priority_defense
priority_defense: Parry Ability
offensive_spells:
- skill: Debilitation
  name: Electrostatic Eddy
  use_auto_mana: true
  cyclic: true
  use_for_survivability: true
- skill: Targeted Magic
  name: Fire Ball
  use_auto_mana: true
prioritize_offensive_spells: true   # always written alongside offensive_spells
```

Both spells reach this leg because this leg trains both their skills. Neither
reaches legs 2, 3 or 4, so those legs omit `offensive_spells` entirely and Iruss's
own setup spells stand there instead. Omitting the key is deliberate: writing an
empty list would replace the character's spells with nothing.

`;uc-leg` does not write this file. `write N` and `go N` do, to
`lich-5/scripts/profiles/Iruss-uc.yaml`.

## What would change this itinerary

| Change | Effect |
| --- | --- |
| Drop `use_for_survivability` from Electrostatic Eddy | It would ride **every** leg instead of just Leg 1. An unflagged Debilitation spell is carried for its effect everywhere, since it displaces no attack time. The flag narrows it back to the legs that train the skill. |
| `max_skills_per_leg: 2` | **Five legs**: Leg 1 unchanged, then Small Blunt + Brawling, Large Edged + Light Thrown, Slings + Crossbow, Polearms. Each skill gets a bigger share of a stint, at the cost of one more lot of fixed overhead. |
| `max_skills_per_leg: 4` | **Three legs**: Leg 1 unchanged, then Small Blunt + Brawling + Large Edged + Light Thrown, then Slings + Crossbow + Polearms. Note Leg 1 does not grow at any cap. The band rule bounds it, not the cap. |
| `require_creature_flags: [corporeal]` | revenant_conscripts is excluded: its only creature is `corporeal: false`. The clusters are unchanged and Polearms still finds a zone, so Leg 4 simply hunts somewhere else. Legs 1-3 are untouched, since young ogres, blood wolves and cave bears are all known corporeal. |
| `require_creature_flags: [living]` | Same outcome, and revenant_conscripts is excluded for the same zone by a different fact: its creature is `undead: true`. This is also the fact that put `args: [undead]` on Leg 4. |
| Remove `in_province_only` | Zones outside Zoluren become candidates. Some may band better, but the distance preference is measured from where the character stands, so a better band can still lose to a nearer zone. |
| `premium: true` | Premium-only zones become candidates. |
| Remove `Polearms` from `weapons` | Leg 4 disappears and Polearms is never trained. That is a choice, not an error, and nothing warns about it beyond the `not_configured` line. |
| Rename it `Polearm` | The scripts **stop**. A misspelled skill name is a typo, not a decision, and the message names the bad key and suggests the real one. |
