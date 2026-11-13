# moderation kit

Built-in StudWork modules for keeping a game safe, one folder per module (module-api.md §1). Each
folder is `<Module>/module.luau` (the definition), `server/` (server part), `client/` and
`net.blink`. Rojo maps every module folder the same way (`tools/sync-projects` writes the entries
of every project): `ReplicatedStorage.Modules.<Module>.{module,client}`,
`ServerScriptService.Modules.<Module>`.

A game lists a module by its definition:
`require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("<Module>"):WaitForChild("module"))`.

| Module | Folder | What |
|---|---|---|
| Admin | [`Admin/`](Admin/) ([README](Admin/README.md), [module.luau](Admin/module.luau), [server](Admin/server/init.luau), [panel](Admin/server/Panel/init.luau), [client](Admin/client/init.luau), [net.blink](Admin/net.blink)) | staff roles and permissions (users, groups), per-staff limits, the staff panel; the base the other two register into |
| Moderation | [`Moderation/`](Moderation/) ([README](Moderation/README.md), [module.luau](Moderation/module.luau), [server](Moderation/server/init.luau), [client](Moderation/client/init.luau), [net.blink](Moderation/net.blink)) | bans (`BanAsync`, retried while Roblox is down), kicks, mutes, warnings, offence ladders, the audit log |
| Reports | [`Reports/`](Reports/) ([README](Reports/README.md), [module.luau](Reports/module.luau), [server](Reports/server/init.luau), [client](Reports/client/init.luau), [net.blink](Reports/net.blink)) | players report players (rate-limited, reporters kept private); the staff queue |

Admin depends on nothing (optional Economy and TextFilter); Moderation (optional Admin,
TextFilter) and Reports (optional Admin, Moderation, TextFilter) each work alone. TextFilter's
`maxLength` defaults to 40: raise it for report notes and announcements.

Docs: [docs/framework/kits/moderation.md](../../../docs/framework/kits/moderation.md).

Kit-level specs and the engine fakes they use (`Fakes.luau`: Players bans, GroupService,
TextChatService, a fake PlayerGui) (Lune, not synced by Rojo): [`tests/`](tests/)
([Fakes.luau](tests/Fakes.luau), [Foundation.spec.luau](tests/Foundation.spec.luau),
[Moderation.spec.luau](tests/Moderation.spec.luau), [Reports.spec.luau](tests/Reports.spec.luau),
`Admin*.spec.luau`, `Reports*.spec.luau`, `Moderation*.spec.luau`, `Integration*.spec.luau`; the
`*Hardening.spec.luau` files cover the final review's fixes). A game's own specs can use the fakes
too: see "Tests (mocked)" on the kit page.
