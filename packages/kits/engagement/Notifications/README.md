# Notifications (engagement kit, v1.7.0 module)

Experience notifications: Roblox's opt-in prompt at a good moment, templates in config, sends through Open Cloud (`ctx.openCloud`), a sharded due list for future sends.

Layout (one folder per module, module-api.md §1): `module.luau` (the definition: config schema and
defaults, save section, strings), `server/` (server part), `client/` (the prompt), `net.blink` (PromptOptIn, OptInShown, SetUtcOffset; generated `server/Net.luau` and `client/Net.luau`), Rojo:
`ReplicatedStorage.Modules.Notifications`, `ServerScriptService.Modules.Notifications`.

Design and API: [docs/framework/kits/notifications.md](../../../../docs/framework/kits/notifications.md).

Server files: `init.luau` (the part: API, actions, opt-in, join and leave), `Engine.luau` (sends, due list,
ledger, claims, retries, poll), and the pure rules `Templates`, `Ledger`, `Quiet`, `Sender`, `OptInRules`
(each with its spec in `../tests/NotificationsRules.spec.luau`). Client files: `init.luau` and `OptIn.luau`
(the seam over `ExperienceNotificationService`). Specs: `../tests/Notifications{Rules,Kit,Sim}.spec.luau`,
everything mocked (no Roblox call).
