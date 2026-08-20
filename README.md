# custom-scripts

Personal [Lich](https://github.com/elanthia-online/lich-5) scripts for DragonRealms. The
`.lic` and `.rb` files sitting directly in this repo's root are mirrored into
`lich-5/scripts/custom/` so Lich can load them — see the wrapper's `CLAUDE.md` for the
mirroring rule (edit here, copy there, commit here).

The centerpiece is **[CharBus](charbus/)**, an inter-character message bus over Redis —
see [`charbus/README.md`](charbus/README.md) for what it is and what it enables.
Everything else here is a grab bag of standalone utility scripts, described below.

## charbus/

CharBus gives every DragonRealms character running under Lich a bidirectional message bus
over an external Redis instance: each character's daemon publishes a live-state heartbeat
and listens for requests (start/stop/pause a script, send a game command, query state),
and the same client API is available to any script for peer-to-peer coordination between
characters. It also ships a standalone CLI for driving and debugging it from a terminal.

Full details, file-by-file breakdown, design tradeoffs, and setup/testing instructions are
in [`charbus/README.md`](charbus/README.md).

## Other scripts

Everything below is a standalone Lich script, unrelated to CharBus.

| Script | What it does |
| --- | --- |
| [`butcher.lic`](butcher.lic) | Standalone necromancer corpse butchery (preserve → butcher to exhaustion → optional dissect), extracted from dr-scripts' `combat-trainer.lic` so it can run without a full combat session. |
| [`cyclic-charge.lic`](cyclic-charge.lic) | Watches for a cambrinth item discharging and recharges it automatically (`;cyclic-charge <amount>`). |
| [`do-thing.lic`](do-thing.lic) | Repeats an arbitrary command until killed, waiting out roundtime between sends (`;repeat dig`). |
| [`escort.lic`](escort.lic) | Local stand-in for obsolete mapdb `StringProcs` that used to call `start_script('escort')` — handles a handful of specific room transitions (monastery, galley/ferry) the map data no longer covers directly. |
| [`force-disconnect.lic`](force-disconnect.lic) | Forcibly closes the detachable frontend socket. |
| [`necroheal.lic`](necroheal.lic) | Lets a necromancer's self-healing (Consumed Flesh/Devour) run via `hunting-buddy`/`combat-trainer`, polling `HEALTH` and signaling a graceful stop once wounds clear. |
| [`perceive-health.lic`](perceive-health.lic) | Empath Empathy trainer: repeats `PERCEIVE HEALTH`, waiting 120s after a perceive that taught something and retrying immediately after one that didn't. |
| [`powerwalk.rb`](powerwalk.rb) / [`pwgo2.lic`](pwgo2.lic) | `powerwalk.rb` is an extractable helper (sends a perceive + waits RT after a room move); `pwgo2.lic` is a thin go2-style traveler built on it, `load`ed live so edits apply without a Lich restart. |
| [`roomid.lic`](roomid.lic) | One-liner: echoes `Room.current.id`. |
| [`roomlookup.lic`](roomlookup.lic) | Looks up a map room's title/description/paths by Lich room id (defaults to the current room). |
| [`t2stop.lic`](t2stop.lic) | Signals a running `;t2` to wrap up gracefully, immediately or after a duration, without killing its in-progress sub-scripts. |
| [`tradestop.lic`](tradestop.lic) | Signals a running `;trade` to close out gracefully, immediately or after a duration in minutes. |
| [`train-chargecast.lic`](train-chargecast.lic) | Combined magic + summoning trainer for Warrior Mages: casts from YAML `training_spells`, summons/breaks, and perceives for Attunement. |

None of the scripts above have a test suite or dependencies of their own; they run
directly under Lich. CharBus's tests and dependencies (`bundle install`, `rspec`) live
under [`charbus/`](charbus/) — see that directory's README for details.
