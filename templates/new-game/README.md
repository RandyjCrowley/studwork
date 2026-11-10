# templates/new-game

Status: template (a working copy of games/_sandbox). `tools/new-game <name>` copies this folder to
`games/<name>` and then rewrites this README, `deploy.json` (name, servePort, placeholder ids),
`default.project.json` (name, servePort) and `GameConfig.gameId` (plus `GameConfig.modules` with
`--modules A,B,C`).

What the copied code does: minimal playable reference game that exercises all of core: touch the
glowing block -> get an item -> it goes on your plot -> it earns per second -> upgrade -> rebirth ->
leave and come back to an offline payout.

- Config: `src/shared/Config`
- Dev: `tools/dev <name>`; publish: `tools/publish <name> --test|--live` (docs/publishing.md)
