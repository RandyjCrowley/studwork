# templates/new-game

Status: template (a working copy of games/_sandbox). `tools/new-game <name>` copies this folder to
`games/<name>` and then rewrites this README, `deploy.json` (name, servePort, placeholder ids),
`default.project.json` (name, servePort, the game module's paths), `GameConfig.gameId`, the game
module's name (`modules/sandbox` -> `modules/<name>`), and with `--modules A,B,C` `GameConfig.modules`
plus the game module's `dependsOn`.

What the copied code does: minimal playable reference game that exercises every kit module (core
v1.3.0, booted with `StudWork.start`): touch the glowing block -> get an item -> it goes on your plot
-> it earns per second -> upgrade -> rebirth -> leave and come back to an offline payout.

- Config: `src/shared/Config` (GameConfig.modules = kit module refs; `config.<Module>` in Balance.luau)
- Game code: the game's own module, `modules/<gameId>` (`module.luau` definition + `server/`),
  renamed by `tools/new-game`; `src/server/Main.server.luau` only builds the world and starts StudWork
- Boot test: `src/server/Boot.spec.luau` (`tools/test games/<name>`)
- Dev: `tools/dev <name>`; publish: `tools/publish <name> --test|--live` (docs/publishing.md)
