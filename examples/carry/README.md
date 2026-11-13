# carry (example game)

The `carry` kit's own fixture game and Studio place: it lists the **Carry** and **Movement** kit modules and nothing else (no items, no economy), so the demo and the Studio gate don't depend on `examples/sandbox`.

- Rojo: `tools/dev carry` (`rojo serve examples/carry/default.project.json`, port 34910)
- Config: `src/shared/Config` (`Balance.luau` merges `BalanceCarry.luau` and `BalanceMovement.luau` into `config.Carry` / `config.Movement`; the demo's own numbers are in `Tuning.luau`, `TuningCarry.luau`, `TuningMovement.luau`). Server-only settings: `src/server/ServerConfig.luau`.
- World: `src/server/World.luau` builds a ground and a spawn, then `CarryWorld.luau` (a carriable, a 2-carrier heavy object, a delivery zone, a kill-plane test drop) and `MovementWorld.luau` (a hazard volume, a `noEntry` volume, a tagged moving platform, a seat, a truss). The Studio-only `/cheat` chat command (`src/client/Main.client.luau`) moves the local character 40 studs with a client-side CFrame write, like an exploited client, so Movement strikes it.
- Config: `src/shared/Config/BalanceCarry.luau` opts in to hard-landing drops (`dropRules.hardLandingSpeed = 55`; off in the kit's defaults) so the demo's ledge shows one.
- Game module: `modules/carry-demo` (`CarryDemo`), no save section.
- Boot test: `src/server/Boot.spec.luau` boots the real project in the multi-server sim.
- Design: [docs/framework/kits/carry.md](../../docs/framework/kits/carry.md); kit: [packages/kits/carry](../../packages/kits/carry/README.md).
- deploy.json ids are placeholders (0): an example, never published.
