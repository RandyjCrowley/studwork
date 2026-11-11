# base kit

Built-in StudWork modules, one folder per module (core-v1.3.1, R19; module-api.md §1). Each
folder is `<Module>/module.luau` (the definition), `server/` (server part), and optionally
`client/`, `shared/` and `net.blink`. Rojo maps every module folder the same way
(`tools/sync-projects` writes the entries of every project):
`ReplicatedStorage.Modules.<Module>.{module,client,shared}`, `ServerScriptService.Modules.<Module>`.

A game lists a module by its definition:
`require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("<Module>"):WaitForChild("module"))`.

| Module | Folder |
|---|---|
| [Plot](Plot/README.md) | `Plot/` |

Docs: [docs/framework/kits/base.md](../../../docs/framework/kits/base.md).
