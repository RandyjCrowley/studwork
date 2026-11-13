# Moderation (moderation kit, v1.0.0 module)

Bans through `Players:BanAsync` (retried with a lease while Roblox is unreachable), unbans, ban
history, kicks, this-server bans, mutes (text chat, optional voice), warnings, offence ladders, the
automatic `report` hook, and the chunked audit log. Optional Admin (permissions, ranks, panel
actions, the Audit tab) and TextFilter (staff free text).

Layout (one folder per module, module-api.md §1): `module.luau` (the definition: config schema and
defaults, save section `moderation`, strings, exported types), `server/` (server part), `client/`
(the `Notice` screen, `isMuted`, `onNotice`), `net.blink` (RemoteScope `STUDWORK_MODERATION`).
Rojo: `ReplicatedStorage.Modules.Moderation`, `ServerScriptService.Modules.Moderation`.

Design and API: [docs/framework/kits/moderation.md](../../../../docs/framework/kits/moderation.md#moderation).

Files: `server/init.luau` (the part: API, permission/rank/role caps, cross-server messages and
delivery, joins, ticks), `server/Actor.luau` (the required `by`), `server/Check.luau` (config),
`server/Util.luau` (pure: UTF-8 cuts, transient errors, JSON), `server/Audit.luau` (chunks, day
directory, per-target index, reads, retention sweep), `server/Pending.luau` (pending bans and
unbans: seq, lease, backoff), `server/Chat.luau` (TextSource and voice mute), `server/Panel.luau`
(Admin actions, Audit tab, audit sink), `server/Console.luau`, `client/init.luau`. Specs:
`packages/kits/moderation/tests/Moderation.spec.luau`, `ModerationHardening.spec.luau`.
