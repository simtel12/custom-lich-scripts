# CharBus

CharBus gives every DragonRealms character running under [Lich](https://github.com/elanthia-online/lich-5)
a bidirectional message bus over an external Redis instance. Each character's daemon
publishes a heartbeat of live state — vitals, encumbrance, combat position, room, running
scripts, skills — to a per-character channel, and listens on a request channel for
commands: start/stop/pause/resume a script, send a raw game command, wait on a pattern, or
query a live state snapshot.

## What it enables

- **An external controller.** Anything that can reach Redis — a script, this repo's CLI, a
  dashboard — can watch a character live and drive it: start a hunting script, pause it to
  intervene, send a command, or wait for a specific response, without touching Lich's own
  console.
- **Peer-to-peer coordination between characters.** The client API
  (`CharBus.emit`/`CharBus.request`, from [`lib_charbus.lic`](lib_charbus.lic)) is
  available to *any* Lich script, not just the daemon, so one character's scripts can react
  to another's events — e.g. warning the group when one character's health drops — without
  hardwiring anything between them. No coordination policy ships here; this is the
  transport those policies would sit on top of.
- **A debugging/ops CLI**, independent of Lich: [`bin/charbus`](bin/charbus) (`watch`,
  `send`, `query`, `ping`, `help`) for poking at a live character from a terminal.

## Pieces

| File | Role |
| --- | --- |
| [`lib/charbus_protocol.rb`](lib/charbus_protocol.rb) | Pure Ruby, zero Lich references. Envelope encode/decode/validate, channel naming, config parsing/normalization/validation, heartbeat tier scheduling, string sanitization. Shared by the daemon, the library, and the CLI so all three speak one protocol definition. |
| [`lib_charbus.lic`](lib_charbus.lic) | Lich library, loaded via `Script.loadlib('_charbus')`. Holds only data — two bounded ring buffers and a presence flag — and exposes `CharBus.emit(event, **fields)` / `CharBus.request(character, verb, **args)` / `CharBus.daemon_present?` to any script. Owns no Redis connection itself. |
| [`_charbus.lic`](_charbus.lic) | The daemon. Named with a leading underscore so Lich's `;p`/`;kill` prefix matching can't reach it by an ordinary-looking command. Runs three threads (publisher, subscriber, worker) plus a supervisor loop, owns both Redis connections, drains the library's event buffer, and executes inbound requests (`start`, `stop`, `pause`, `resume`, `send`, `expect`, `query`, `ping`). |
| [`data/base-charbus.yaml.example`](data/base-charbus.yaml.example) | Annotated example config: Redis connection, channel prefix, heartbeat intervals, self-ping/liveness tuning, queue sizes and expiry, per-character overrides. |
| [`data/base-charbus.yaml`](data/base-charbus.yaml) | The actual config, copied from the example above. Committed here as the source of truth; the daemon itself reads a separate uncommitted runtime copy under `lich-5/scripts/data/custom/` (see **Setup** below). |
| [`bin/charbus`](bin/charbus) | Standalone CLI, run outside Lich. `charbus watch <character...>`, `charbus send <character> <verb> [k=v ...]`, `charbus query <character> [field ...]`, `charbus ping <character>`, `charbus help [...]`. |
| [`spec/charbus_protocol_spec.rb`](spec/charbus_protocol_spec.rb) | Unit specs for the protocol module — envelope round-tripping, config validation/merging, sanitization. No Redis required. |
| [`spec/integration_spec.rb`](spec/integration_spec.rb) | Live-Redis integration spec covering reply-channel ordering. |

Dependency direction is one-way: daemon → library → protocol module; CLI → protocol
module. The library never calls into the daemon, so `CharBus.emit`/`.request` are safe to
call from any script even when no daemon is running — `.emit` silently buffers,
`.request` returns `:bus_down`.

## Design posture worth knowing before touching it

- **No auth, wide open.** Anyone who can reach the Redis instance has control equivalent
  to sitting at the character's keyboard — the isolation of the Redis instance *is* the
  entire security boundary. Don't point `channel_prefix` at a shared/public Redis.
- **Fire-and-forget.** Pub/sub, no durable queue — a request sent while a character is
  offline is simply lost, and delivery is never retried by the sender.
- **Fail loud at startup, retry with backoff mid-session.** An unreachable Redis at daemon
  start echoes an error and exits immediately, rather than retrying quietly and pretending
  to be healthy. A connection lost later logs and retries forever with the config's
  `reconnect_backoff`.
- **Self-ping liveness.** The daemon pings its own request channel on an interval and
  expects the reply back inline; missing enough in a row (`self_ping_misses`) triggers a
  subscriber reconnect. This is what catches a socket a firewall or NAT killed silently.
- **Tiered heartbeats.** Vitals/position/room are cheap and sent often (`fast_interval`);
  the full skill table is larger and sent less often (`slow_interval`) — the two are
  configured independently, per character if needed.
- **Single worker thread.** Requests execute serially and in order, so e.g. a `pause` and
  a `start` sent close together can't interleave into something nonsensical.
- **Channel naming.** `<prefix>:<Character>_state` (daemon → world), `<prefix>:<Character>_requests`
  (world → daemon), `<prefix>:reply:<uuid>` (daemon → one requester). Character names are
  byte-exact from the game and capitalized as the character is.

## Setup

```sh
cd custom-scripts/charbus
bundle install
cp data/base-charbus.yaml.example data/base-charbus.yaml
$EDITOR data/base-charbus.yaml                                    # set redis: host/port, channel_prefix
cp data/base-charbus.yaml ../../lich-5/scripts/data/custom/base-charbus.yaml
```

Two copies of the config are required, read by two different code paths:

- `custom-scripts/charbus/data/base-charbus.yaml` — source of truth, committed. Read
  directly by `bin/charbus`, which runs outside Lich and can't use Lich's data loader.
  Override the path with `CHARBUS_CONFIG=/some/other/file`.
- `lich-5/scripts/data/custom/base-charbus.yaml` — runtime copy, not committed (that tree
  is a working directory). Read by the daemon via `get_data('charbus')`.

The `base-` prefix on the filename is required, not decorative — Lich's data loader
resolves `get_data('charbus')` to a file literally named `base-charbus.yaml`.

In-game, once the runtime copy of the config is in place, `;_charbus` starts the daemon
for that character.

## Testing

```sh
cd custom-scripts/charbus
bundle install
bundle exec rspec                     # all specs
bundle exec rspec --tag ~integration  # skip the Redis-dependent spec
```

`spec/integration_spec.rb` needs a live Redis reachable at `127.0.0.1:6379`, e.g.:

```sh
docker run -d --rm -p 6379:6379 redis:7-alpine
```

## Using the CLI

```sh
bin/charbus help
bin/charbus watch Drazoken Zulljin       # stream state-channel events for one or more characters
bin/charbus ping Drazoken                # round-trip latency to a character's daemon
bin/charbus query Drazoken health mana   # fetch fields from a live state snapshot
bin/charbus send Drazoken start script=buff
```

`bin/charbus help send <verb>` details a specific request verb's arguments and possible
replies (`start`, `stop`, `pause`, `resume`, `send`, `expect`, `query`, `ping`).
