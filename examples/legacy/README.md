# Legacy fixture games (v1.6.0)

Three small Roblox games that do **not** use StudWork, written the way many existing games are.
They are fixtures for adopting StudWork (`docs/framework/adopting.md`,
`docs/agents/adopt-existing-game.md`): the audit, init and import tools are tested against them,
and fresh agents migrate copies of them end to end.

| Fixture | Shape | Saves | Purchases |
|---|---|---|---|
| `legacy-example-a` | Studio-only place file (`legacy-example-a.rbxlx`), no Rojo | raw DataStore (`PlayerSave_v3`) | a coin pack with a `PurchaseHistory` store |
| `legacy-example-b` | Rojo repo, custom UI | ProfileService (`PlayerData`) | two gamepasses, a gem pack (ids in the profile) |
| `legacy-example-c` | messy Rojo repo: `_G`/`shared` globals, mixed remotes, duplicated save logic | DataStore2, combined keys, plus a raw coins backup | two products, no history |

Each has `FEATURES.md` (what the game does: every feature must survive a migration) and `saves/`
(synthetic sample old saves, exactly as the old game stored them).

Their code is deliberately legacy: `tools/lint` skips `examples/legacy/` (selene, StyLua) and the
guardrails don't scan it. `_build/` holds the sources of fixture a's place file and the Lune
script that writes it (`lune run examples/legacy/_build/legacy-example-a/build`).
