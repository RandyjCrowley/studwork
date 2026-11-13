# quests kit

Built-in StudWork modules, one folder per module (module-api.md §1). Each folder is
`<Module>/module.luau` (the definition), `server/` (server part), and optionally `client/`, `shared/`
and `net.blink`. Rojo maps every module folder the same way (`tools/sync-projects` writes the entries
of every project): `ReplicatedStorage.Modules.<Module>.{module,client,shared}`,
`ServerScriptService.Modules.<Module>`.

A game lists a module by its definition:
`require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("<Module>"):WaitForChild("module"))`.

| Module | Folder | What |
|---|---|---|
| Quests | `Quests/` | daily, weekly, story-chain, one-time, repeatable and event quests; server-only progress, exactly-once claims, the quest board, HUD tracker and toasts |
| Goals | `Goals/` | the first-session goal chain and the next-goal pointer: a HUD pill, one world beam and an off-screen edge arrow, "what's next" after the chain, one funnel step per goal |

Each works alone: Goals needs no Quests, and Quests needs Economy, Inventory, Rarity, Rebirth, Streak
or Leaderboards only when its config references them. Both declare `framework = "^1.7.0"`.

Design, config and API: [docs/framework/kits/quests.md](../../../docs/framework/kits/quests.md).

Adding the kit to an existing game is a manual step until the `--modules` lists include it: the
[step-by-step section](../../../docs/framework/kits/quests.md#add-quests-and-goals-to-an-existing-game)
(`GameConfig.modules`, the game module's `dependsOn`, the `Boot.spec` `EXPECTED` list, config, strings,
the `Game.nextGoal` pill). Goal positions are `{ x, y, z }` or `{ x = , y = , z = }`; a goal whose
`funnel` step isn't in `analytics.funnel` logs a boot warning. Run `tools/format` after pasting config (lint
fails on unformatted tables), call the kit from your game module through `ctx.deps[Quests]` /
`ctx.deps[Goals]`, and give goals funnel step names the scaffold doesn't already log.

Layout:

- `Quests/module.luau`, `Goals/module.luau`: config schema and defaults (both boot with no config),
  save sections (`quests`, `goals`, version 1; `sanitize` repairs shapes only, removed ids are pruned
  in each server part's first tx on load), strings, theme (`colors.goalPointer`).
- `*/net.blink` and the generated `server/Net.luau`, `client/Net.luau` (`tools/net`): the actions
  `claimQuest`, `rerollQuest`, `pinQuest`, `ackQuest`, `skipGoals`, `ackGoal`.
- `*/shared/`: pure rules both sides use (types, periods, config validation, the deterministic deal).
- `*/server/`: the server parts. `*/client/`: the board, tracker, toasts, pill and pointer.

Kit-level specs and sims (Lune, not synced by Rojo): `tests/`. The fixture game that shows every
piece in Studio: `examples/quests-demo/`.
