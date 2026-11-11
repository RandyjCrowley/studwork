# templates/adopt

What `tools/adopt --init` (StudWork v1.6.0, docs/framework/adopting.md §2) writes into an existing
game as its game module `modules/<gameId>/`. Every `*.tmpl` is rendered with `{{gameId}}`,
`{{Module}}` (the PascalCase module name), `{{dependsOn}}` (one `require` line per chosen kit
module) and `{{tag}}`; the `.tmpl` suffix is dropped. This README is not copied.

- `module.luau.tmpl`: the game module definition (data key = the game id).
- `server/init.luau.tmpl`: its server part, with the legacy import and the purchase bridge calls
  stubbed and commented (`importLegacy`, `legacyReceipts`, `onLegacyProduct`).
- `module.spec.luau.tmpl`: a first spec (the server part loads, the definition is valid), so
  the project's `tools/test` has something to run from day one.
- `README.md.tmpl`: the module's README with the save-map table the migration fills in.
