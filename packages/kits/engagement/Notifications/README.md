# Notifications (engagement kit, v1.7.0 module)

Experience notifications: Roblox's opt-in prompt at a good moment, templates in config, sends through Open Cloud (`ctx.openCloud`), a sharded due list for future sends.

Layout (one folder per module, module-api.md §1): `module.luau` (the definition: config schema and
defaults, save section, strings), `server/` (server part), `client/` (the prompt), `net.blink` (PromptOptIn, OptInShown, SetUtcOffset; generated `server/Net.luau` and `client/Net.luau`), Rojo:
`ReplicatedStorage.Modules.Notifications`, `ServerScriptService.Modules.Notifications`.

Design and API: [docs/framework/kits/notifications.md](../../../../docs/framework/kits/notifications.md).

Status: the foundation skeleton. `module.luau` is final; the server part is a valid empty part whose
API answers with documented safe defaults. Implementation: the notifications builder of the v1.7.0 round.
