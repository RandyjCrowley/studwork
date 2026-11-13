# carry kit

Built-in StudWork modules for moving things and checking movement (v1.8.0), one folder per module
(module-api.md §1). Each folder is `<Module>/module.luau` (the definition), `server/` (server part),
and optionally `client/`, `shared/` and `net.blink`. Rojo maps every module folder the same way
(`tools/sync-projects` writes the entries of every project):
`ReplicatedStorage.Modules.<Module>.{module,client,shared}`, `ServerScriptService.Modules.<Module>`.

A game lists a module by its definition:
`require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("<Module>"):WaitForChild("module"))`.

| Module | Folder |
|---|---|
| Carry: pick up, carry, hand off, throw, drop and deliver an object, alone or together | `Carry/` |
| Movement: a server-side movement validator (speed, teleport, volume sweep, ground, wall, rise) | `Movement/` |

Neither module depends on the other: Carry reads Movement only through `optional = { Movement }`, and
each works alone.

Docs: [docs/framework/kits/carry.md](../../../docs/framework/kits/carry.md).

**The World seam.** Each module reads the world (characters, positions, casts, tags, seats, ping)
only through a `World` adapter (`<Module>/shared/World.luau`, `World.live()`, fetched lazily under
`pcall`; nil under the Lune harness, so the module idles). `Carry.useWorld(world)` /
`Movement.useWorld(world)` install another one: `tests/FakeWorld.luau` is the scriptable fake that
specs, sims and the bench use. `<Module>/shared/CF.luau` is the kit's tiny CFrame math (position plus
a row-major 3x3); the two copies are byte-identical (`tests/SharedCopies.spec.luau`).

Layout: `Carry/` has `client/`, `server/`, `shared/` and `net.blink` (generated `server/Net.luau`,
`client/Net.luau`); `Movement/` has `server/` and `shared/` only (no client part, no actions).

Kit-level specs (Lune, not synced by Rojo): `tests/`. Fixture game and Studio place:
[examples/carry](../../../examples/carry/README.md).
