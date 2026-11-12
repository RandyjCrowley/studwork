# templates/adopt

What `tools/adopt --init` (StudWork v1.6.0, docs/framework/adopting.md §2) writes into an existing
game as its game module `modules/<gameId>/`. Every `*.tmpl` is rendered with `{{gameId}}`,
`{{Module}}` (the PascalCase module name), `{{dependsOn}}` (one `require` line per chosen kit
module), `{{tag}}` and `{{projectFile}}` (the game's Rojo project file); the `.tmpl` suffix is
dropped. This README is not copied.

- `module.luau.tmpl`: the game module definition (data key = the game id, `client` = its client
  part).
- `server/init.luau.tmpl`: its server part, with the legacy import and the purchase bridge calls
  stubbed and commented (`importLegacy`, `legacyReceipts`, `onLegacyProduct`).
- `client/init.luau.tmpl`: its client part (`init` / `start`), mapped as
  `ReplicatedStorage.GameModule.client`: the kept old UI's code goes here.
- `module.spec.luau.tmpl`: a first spec (the definition is valid, and the game boots in the
  StudWork sim with its Config, this module and its kits). It never requires the server part at
  load, so it keeps passing once the server part calls `game:GetService("Players")` at its top.
- `README.md.tmpl`: the module's README with the save-map table the migration fills in.
- `config/init.luau.tmpl`: `src/shared/Config/init.luau`, only when the game has no
  `src/shared/Config`: a MINIMAL GameConfig (the chosen modules at their defaults, no items,
  rarity tables, starter items or events, `compliance.paidCurrencies = {}`, and the audit
  report's product and pass ids under `Product<id>` / `Pass<id>` placeholder names). Rendered with
  `{{gameId}}`, `{{modulesHeader}}`, `{{modules}}`, `{{kitConfig}}`, `{{devProducts}}`,
  `{{passes}}`.
- `boot/`: the server and client scripts that call `StudWork.start` (copied as is). (v1.6.1) The
  server one passes `ServerConfig.legacyList` = the `LegacyList` ModuleScript next to it, when
  there is one: init maps `studwork-legacy.json` there (`ServerScriptService.StudWorkBoot.LegacyList`).
