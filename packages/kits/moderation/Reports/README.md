# Reports (moderation kit, v1.0.0 module)

Players report players (in this server or recently left): rate-limited per reporter, pair and
target, duplicates merged per target, filtered unattributed notes, reporter ids only for
`reports.reporters` staff; the staff queue (a sorted map index) as an Admin tab. Optional Admin,
Moderation (audit entries, `autoAction`) and TextFilter (notes).

Layout (one folder per module, module-api.md §1): `module.luau` (the definition: config schema and
defaults, save section `reports`, strings, exported types), `server/` (server part), `client/` (the
`"Report"` screen), `net.blink` (RemoteScope `STUDWORK_REPORTS`). Rojo:
`ReplicatedStorage.Modules.Reports`, `ServerScriptService.Modules.Reports`.

Design and API: [docs/framework/kits/moderation.md](../../../../docs/framework/kits/moderation.md#reports).

Files: `server/init.luau` (the part: submit, limits, merge, eviction, queue/detail/claim/resolve,
the Admin tab, recently-left list, console), `server/Record.luau` (pure: limits, merge, sort key,
summaries, viewer view, context), `server/Actor.luau` (the required `by`), `client/init.luau`,
`client/State.luau` (pure view state), `client/Views.luau` (React screen). Specs:
`packages/kits/moderation/tests/Reports*.spec.luau`.
