# custom-scripts

Personal [Lich](https://github.com/elanthia-online/lich-5) scripts for DragonRealms. The
`.lic` and `.rb` files sitting directly in this repo's root are mirrored into
`lich-5/scripts/custom/` so Lich can load them — see the wrapper's `CLAUDE.md` for the
mirroring rule (edit here, copy there, commit here).

The centerpiece is **CharBus**, an inter-character message bus described in its own
section below. Everything else is a grab bag of standalone utility scripts.

## CharBus — inter-character communication over Redis

CharBus gives every DragonRealms character running under Lich a bidirectional message bus
over an external Redis instance. Each character's daemon publishes a heartbeat of live
state (vitals, encumbrance, position, room, running scripts, skills) to a per-character
channel, and listens on a request channel for commands like starting/stopping/pausing a
script, sending a raw game command, or waiting on a pattern.

That combination is what it enables:

- **An external controller** — anything that can reach Redis (a script, a CLI, a
  dashboard) can watch a character live and drive it: start a hunting script, pause it to
  intervene, send a command, or wait for a specific response, all without touching Lich's
  own console.
- **Peer-to-peer coordination between characters** — the client API
  (`CharBus.emit`/`CharBus.request`) is available to *any* Lich script, not just the
  daemon, so one character's scripts can react to another's events (e.g. "warn the group
  when Zulljin's health drops") without hardwiring anything. This groundwork is laid
  deliberately; no coordination policy ships yet — see the design doc's scope notes.
- **A debugging/ops CLI** — [`bin/charbus`](bin/charbus) is a plain-Ruby command line tool
  (`watch`, `send`, `query`, `ping`, `help`) for poking at a live character from a
  terminal, independent of Lich.

### Pieces

| File | Role |
| --- | --- |
| [`lib/charbus_protocol.rb`](lib/charbus_protocol.rb) | Pure Ruby, zero Lich references. Envelope encode/decode/validate, channel naming, config parsing/normalization/validation, heartbeat tier scheduling, string sanitization. Shared by the daemon, the library, and the CLI so all three speak one protocol definition. |
| [`lib_charbus.lic`](lib_charbus.lic) | Lich library (`Script.loadlib('_charbus')`). Holds only data — two bounded ring buffers and a presence flag — and exposes `CharBus.emit(event, **fields)` / `CharBus.request(character, verb, **args)` / `CharBus.daemon_present?` to any script. Owns no Redis connection itself. |
| [`_charbus.lic`](_charbus.lic) | The daemon. Deliberately named with a leading underscore so Lich's `;p`/`;kill` prefix matcher can't reach it by accident (see §3.1 of the design doc). Runs three threads — publisher, subscriber, worker — plus a supervisor loop, owns both Redis connections, drains the library's event buffer, and executes inbound requests (`start`, `stop`, `pause`, `resume`, `send`, `expect`, `query`, `ping`). |
| [`data/base-charbus.yaml.example`](data/base-charbus.yaml.example) | Annotated example config: Redis connection, channel prefix, heartbeat intervals, liveness/self-ping tuning, queue sizes and expiry, per-character overrides. Copy to `data/base-charbus.yaml` (committed, read by the CLI) and mirror that to `lich-5/scripts/data/custom/base-charbus.yaml` (uncommitted runtime copy, read by the daemon via `get_data('charbus')`) — see the comment block at the top of the example for why both copies are required. |
| [`bin/charbus`](bin/charbus) | Standalone CLI, run outside Lich. `charbus watch <character...>`, `charbus send <character> <verb> [k=v ...]`, `charbus query <character> [field ...]`, `charbus ping <character>`, `charbus help [...]`. |
| [`spec/charbus_protocol_spec.rb`](spec/charbus_protocol_spec.rb), [`spec/integration_spec.rb`](spec/integration_spec.rb) | Unit specs for the protocol module, plus a live-Redis integration spec for reply-channel ordering (`docker run -d --rm -p 6379:6379 redis:7-alpine`). |

Dependency direction is one-way: daemon → library → protocol module; CLI → protocol
module. The library never calls into the daemon, so `CharBus.emit`/`.request` are safe to
call from any script even when no daemon is running (they just no-op / return
`:bus_down`).

### Design posture worth knowing before touching it

- **No auth, wide open.** Anyone who can reach the Redis instance has control equivalent
  to sitting at the character's keyboard — the isolation of the Redis instance *is* the
  entire security boundary. Don't point `channel_prefix` at a shared/public Redis.
- **Fire-and-forget.** Pub/sub, no durable queue — a request sent while a character is
  offline is simply lost.
- **Fail loud at startup, retry with backoff mid-session.** An unreachable Redis at daemon
  start exits immediately; a connection lost later logs and retries forever with backoff.

The full rationale — every design decision, the adversarial-review history, and the
gotchas discovered along the way (Lich's prefix matching, `waitforre` traps, `Script.kill`
regex interpolation, etc.) — lives in
[`notes/2026-08-14-charbus-design.md`](../notes/2026-08-14-charbus-design.md) at the
wrapper root, with the implementation plan in
[`notes/2026-08-14-charbus-plan.md`](../notes/2026-08-14-charbus-plan.md).

### Trying it

```sh
cd custom-scripts
bundle install
cp data/base-charbus.yaml.example data/base-charbus.yaml
$EDITOR data/base-charbus.yaml                                        # set redis: host/port
cp data/base-charbus.yaml ../lich-5/scripts/data/custom/base-charbus.yaml
rspec                                                                  # unit + integration specs
bin/charbus help
```

In-game, once the runtime copy of the config is in place: `;_charbus` to start the daemon
for that character.

## Other scripts

Everything below is a standalone Lich script, unrelated to CharBus except where noted.

| Script | What it does |
| --- | --- |
| [`butcher.lic`](butcher.lic) | Standalone necromancer corpse butchery (preserve → butcher to exhaustion → optional dissect), extracted from dr-scripts' `combat-trainer.lic` so it can run without a full combat session. |
| [`cyclic-charge.lic`](cyclic-charge.lic) | Watches for a cambrinth item discharging and recharges it automatically (`;cyclic-charge <amount>`). |
| [`do-thing.lic`](do-thing.lic) | Repeats an arbitrary command until killed, waiting out roundtime between sends (`;repeat dig`). |
| [`escort.lic`](escort.lic) | Local stand-in for obsolete mapdb `StringProcs` that used to call `start_script('escort')` — handles a handful of specific room transitions (monastery, galley/ferry) the map data no longer covers directly. |
| [`force-disconnect.lic`](force-disconnect.lic) | Forcibly closes the detachable frontend socket. |
| [`necroheal.lic`](necroheal.lic) | Lets a necromancer's self-healing (Consumed Flesh/Devour) run via `hunting-buddy`/`combat-trainer`, polling `HEALTH` and signaling a graceful stop once wounds clear. |
| [`powerwalk.rb`](powerwalk.rb) / [`pwgo2.lic`](pwgo2.lic) | `powerwalk.rb` is an extractable helper (sends a perceive + waits RT after a room move); `pwgo2.lic` is a thin go2-style traveler built on it, `load`ed live so edits apply without a Lich restart. |
| [`roomid.lic`](roomid.lic) | One-liner: echoes `Room.current.id`. |
| [`roomlookup.lic`](roomlookup.lic) | Looks up a map room's title/description/paths by Lich room id (defaults to the current room). |
| [`t2stop.lic`](t2stop.lic) | Signals a running `;t2` to wrap up gracefully, immediately or after a duration, without killing its in-progress sub-scripts. |
| [`tradestop.lic`](tradestop.lic) | Signals a running `;trade` to close out gracefully, immediately or after a duration in minutes. |
| [`train-chargecast.lic`](train-chargecast.lic) | Combined magic + summoning trainer for Warrior Mages: casts from YAML `training_spells`, summons/breaks, and perceives for Attunement. |

## Testing

```sh
bundle install
rspec                  # all specs
rubocop                # lint, if configured
```

The integration spec under `spec/integration_spec.rb` needs a live Redis
(`docker run -d --rm -p 6379:6379 redis:7-alpine`); the rest of the suite doesn't.
