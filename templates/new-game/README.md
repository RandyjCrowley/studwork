# templates/new-game

Status: template (a working copy of examples/sandbox). `tools/new-game <name>` copies this folder to
`games/<name>` and then rewrites this README, `deploy.json` (name, servePort, placeholder ids),
`default.project.json` (name, servePort, the game module's paths), `GameConfig.gameId`, the game
module's name (`modules/sandbox` -> `modules/<name>`), and with `--modules A,B,C` `GameConfig.modules`
plus the game module's `dependsOn`.

## Module markers

The template's Luau carries comment markers saying which kit modules a piece of code or config
needs. `tools/new-game` resolves them for the chosen modules (all of them without `--modules`) and
strips every marker, so a generated game passes `tools/lint` with no hand trimming
(`NewGame.applyMarkers`, specs in `tools/lune/NewGame.spec.luau`):

| Marker | Meaning |
|---|---|
| `-- @if Economy` (own line) ... `-- @end` | block kept only when Economy is chosen; blocks nest |
| `-- @if Rarity,Inventory` | all of them |
| `-- @if Inventory\|Mail` | any of them; `A,B\|C` = (A and B) or C |
| `-- @else` | the other branch of the enclosing `@if` |
| `<code> -- @if Plot` (end of a line) | keep just this line |
| `-- @unless Plot: <code>` | emit `<code>` (uncommented) when Plot is left out: the replacement for a dropped line |

When you add code to the template that uses a kit module, mark it. The spec checks that every
marker names a real module and that the template resolves and compiles for every single module,
for all and for none.

What the copied code does: minimal playable reference game that exercises every kit module (core
v1.3.0, booted with `StudWork.start`): touch the glowing block -> get an item -> it goes on your plot
-> it earns per second -> upgrade -> rebirth -> leave and come back to an offline payout.

- Config: `src/shared/Config` (GameConfig.modules = kit module refs; `config.<Module>` in Balance.luau)
- Game code: the game's own module, `modules/<gameId>` (`module.luau` definition + `server/`),
  renamed by `tools/new-game`; `src/server/Main.server.luau` only builds the world and starts StudWork
- Boot test: `src/server/Boot.spec.luau` (`tools/test games/<name>`)
- Dev: `tools/dev <name>`; publish: `tools/publish <name> --test|--live` (docs/publishing.md)
