# Games repo skeleton (StudWork v1.5.0)

Copy into a new games repo (`docs/framework/games-repo.md` in roblox-core has the full steps):

```sh
git init my-games && cd my-games
git -c protocol.file.allow=always submodule add <path-or-url-of-roblox-core> roblox-core
git -C roblox-core checkout v1.5.0
cp -R roblox-core/templates/games-repo/. .
mv gitignore .gitignore && mv env.example .env.example && rm README.md
tools/install && tools/doctor
tools/new-game my-game
```

| File | What |
|---|---|
| `tools/_studwork` | runs `roblox-core/tools/<tool>` with `STUDWORK_PROJECT_ROOT` = this repo |
| `tools/*` | one-line wrappers: install, doctor, lint, typecheck, test, build, new-game, make-module, make-screen, make-migration, publish, dev, net, sync-projects, framework-status |
| `.githooks/pre-commit` | `tools/lint` + `tools/test` (enabled by `tools/install`); works for `git commit` and partial `git commit <paths>` since v1.4.1 |
| `gitignore` -> `.gitignore` | build output, caches, `.env` |
| `env.example` -> `.env.example` | the Open Cloud key name for `tools/publish` |
| `GAMES.md` | the game list (`tools/new-game` adds rows, `tools/publish` fills the Core column) |
| `FRAMEWORK_REQUESTS.md` | what games need from the framework |
| `games/` | one folder per game (`tools/new-game`) |

Upgrading: read `roblox-core/CHANGELOG.md` (the framework's changelog), then
`git -C roblox-core fetch --tags && git -C roblox-core checkout vX.Y.Z`, run `tools/install`, and
commit the submodule bump on its own (the hook refuses it mixed with `games/` changes).
