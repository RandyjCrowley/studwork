# collection kit

Built-in StudWork modules, one folder per module (core-v1.3.1, R19; module-api.md §1). Each
folder is `<Module>/module.luau` (the definition), `server/` (server part), and optionally
`client/`, `shared/` and `net.blink`. Rojo maps every module folder the same way
(`tools/sync-projects` writes the entries of every project):
`ReplicatedStorage.Modules.<Module>.{module,client,shared}`, `ServerScriptService.Modules.<Module>`.

A game lists a module by its definition:
`require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("<Module>"):WaitForChild("module"))`.

| Module | Folder |
|---|---|
| [Items](Items/README.md) | `Items/` |
| [Rarity](Rarity/README.md) | `Rarity/` |
| [Inventory](Inventory/README.md) | `Inventory/` |

Docs: [docs/framework/kits/collection.md](../../../docs/framework/kits/collection.md).

Kit-level specs (Lune, not synced by Rojo): `tests/`.
