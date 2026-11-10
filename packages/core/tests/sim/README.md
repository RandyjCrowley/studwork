# Multi-server simulation (packages/core/tests/sim)

Lune-only test code (not in the Rojo tree, not type-checked by `tools/typecheck`, like
`../harness.luau`). It boots the **real** core services and the **real** vendored ProfileStore
1.0.3 inside several simulated servers that share one mock "Roblox cloud", so lifecycle and
multi-player behaviour can be tested offline.

| File | What |
|---|---|
| `Scheduler.luau` | virtual clock + cooperative `task` (wait/spawn/defer/delay/cancel), frame hooks (Heartbeat), per-server thread ownership (`kill` = crash) |
| `Signal.luau` | RBXScriptSignal stand-in: every handler in its own thread, fire history |
| `World.luau` | shared cloud: mock DataStoreService (latency, ack latency, `failNext`/`failFor`, JSON-like deep copies, write log), MessagingService bus, friend graph, Policy answers, game passes |
| `Server.luau` | one server: fake engine services + `game` (JobId, BindToClose), loads real core modules with its own module cache, boots them (init all, start all), players join/leave/kick, `purchase`, `remote`, `shutdown`, `crash` |
| `Loader.luau` | loads source files with a per-server env (`luau.load`); reads every source once at load |
| `Fixtures.luau` | test GameConfig, `stored()`, `lockHolder()`, `writerViolations()` ("never two writers"), `grants()` |
| `*.spec.luau` | scenarios, run by `tools/test` (whole sim suite ~0.6 s) |
| `*.slow.luau` | soak test, run by `tools/test-sim` |
| `*.pending.luau` | written against unmerged contract work; `tools/test-sim --pending` |
| `run.luau` | runner used by `tools/test-sim` (same `Harness.runSpec` as `tools/test`) |

## Real vs modelled

Real code: `server/Data` (init, Load, Schema, Migrate, Sanitize, Transaction, ReadOnlyView,
Internal), `server/Items`, `server/Economy`, `server/Inventory`, `server/Offline`,
`server/Friends`, `server/Shop` (+ `Receipt`), `server/Mail` (+ `Delivery`, `MailValidate`),
`server/Tx.luau`, `shared/Types|Validate|HandlerList`, and ProfileStore 1.0.3 in LIVE mode
(`RunService:IsStudio()` is false, so it uses DataStoreService, session locks, MessagingService
and its own BindToClose, never its Mock).

Modelled: Players, RunService, DataStoreService, MessagingService, HttpService (GUIDs, JSON via
`@lune/serde`), MarketplaceService, `Instance.new("DataStoreOptions")`, `Enum`; the Context
wiring (ctx.signals, ctx.net, ctx.setReplicated, console); and the services that are not loaded
for real: Policy (from `world.restricted`), Plot, Upgrades, Rebirth, Analytics/Events/Net
(recorders). The boot is not `server/init.luau` itself (that needs Blink remotes/Instances).

Mock DataStore model: a write commits atomically after `world.latency`, the caller gets the
result after a further `world.ackLatency`. An injected failure errors after the latency without
writing. A crashed server's in-flight call never commits. Values are deep-copied and rejected if
not serializable (functions, cycles, NaN, non string/number keys). Not modelled: request
budgets/throttling, the 4 MB limit, versioning (`GetVersionAsync`), real MessagingService
delivery delays beyond `messagingLatency`.

## Writing a scenario

```lua
local F = require(script.Parent.Fixtures)
local world = F.world({ config = { balance = { offline = { autoPay = false } } } })
local a = F.server(world)               -- boots real core
local p = a:join(1)
world:advanceUntil(function() return a:isLoaded(p) end, 30)
a.services.Economy.grant(p, 10, "test") -- call services directly (non-yielding)
local h = a:spawn(a.services.Data.saveAsync, p) -- yielding calls run in a server thread
world:advanceUntil(function() return h.done end, 40)
a:leave(p)
expect(#world:errors()).toBe(0)
```

Pitfalls:
- Never pass simulated players/servers to `expect(...)`: the harness formats values recursively
  and they are cyclic (stack overflow). Compare `.UserId`.
- `advance(seconds, dt)`: use a big `dt` (0.25-5) for long waits (ProfileStore steal 40 s,
  autosave 300 s); the default frame is 1/32 s.
- A profile's stored `Data` is ProfileStore's empty template until the first real save.
- Data passes `Cancel` to `StartSessionAsync`, so ProfileStore's 120 s load timeout never
  applies: during an outage a player waits (unloaded) until it ends or they leave.
