# TextFilter (social kit, v1.7.0 module)

One way to filter any player-entered text by who will see it (public, friends, private). The original text stays in this module's own save section.

Layout (one folder per module, module-api.md §1): `module.luau` (the definition: config schema and
defaults, save section, strings), `server/` (server part), Rojo:
`ReplicatedStorage.Modules.TextFilter`, `ServerScriptService.Modules.TextFilter`.

Design and API: [docs/framework/kits/textfilter.md](../../../../docs/framework/kits/textfilter.md).

Status: built in v1.7.0. Specs: `packages/kits/social/tests/TextFilter*.spec.luau`; the `textfilter`
lint check is `tools/lune/GuardTextFilter.luau`.
