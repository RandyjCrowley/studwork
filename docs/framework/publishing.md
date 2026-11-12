# Publishing a game

How a game in your games repo ([games-repo.md](games-repo.md)) goes from `games/<name>` to a live
Roblox experience. In a single-game project ([single-game-project.md](single-game-project.md),
v1.5.0) the same steps apply without the game name (`tools/publish --test`); `deploy.json` is at the
project root, there is no `GAMES.md`, and the clean-tree gate covers the whole project and the
`studwork/` submodule. Everything goes through the games repo's `tools/publish` (a wrapper around
`roblox-core/tools/publish`, run with the games repo as the project); never publish from Studio
(Studio publishes skip the checks and the StudWork stamp, and can publish uncommitted code). If AI
coding agents work in your repo, let them run only `--dry-run` and do real publishes yourself.

Roblox details below (endpoint, scope, key settings) were checked against create.roblox.com on
**2026-11-10**: the Places API reference, the "Usage guide for place publishing", the API keys page
and the Scopes reference. Dashboard menus move; if a step doesn't match, the docs pages named here
are the source of truth.

## 0. One-time setup

1. From a fresh clone: `git -c protocol.file.allow=always submodule update --init` (the framework,
   `roblox-core/` at its pinned tag), then `tools/install` (the core's pinned toolchain, Wally
   packages into `roblox-core/deps/`, and the games repo's pre-commit hook), then `tools/doctor` until it
   says `all good` (the `.env` line may stay WARN until step 4).

Everything below that happens on roblox.com (steps 1 to 4 and the launch checklist) is a one-time
manual setup that you do in the browser.

## 1. Create a Roblox Group

All games live under one Group so that revenue, permissions and API keys are not tied to a personal
account.

1. roblox.com > Communities (Groups) > Create. Pick a name; it costs Robux.
2. Add collaborators with roles that only have the permissions they need.

## 2. Create a test and a live experience per game

Each game has **two** experiences: a test one (private, for playtesting) and a live one (public).
They are separate universes, so test data never touches live data stores.

1. Creator Dashboard (create.roblox.com) > Creations > switch the owner to your Group.
2. Create Experience twice, e.g. `My Game [TEST]` and `My Game`. Leave both private for now.
   A new experience starts with one place (its start place); that is the place we publish to.
3. On the test experience: Configure > Access/Permissions: private, or friends/group only.

## 3. Find the universe and place ids

- **Universe id** (experience id): open the experience in the Creator Dashboard; the URL is
  `https://create.roblox.com/dashboard/creations/experiences/<UNIVERSE_ID>/overview`.
- **Place id**: in the experience, left menu **Places** > click the start place; the URL is
  `.../experiences/<UNIVERSE_ID>/places/<PLACE_ID>/configure`.

Paste them into `games/<name>/deploy.json`:

```json
{
  "name": "my-game",
  "servePort": 34874,
  "test": { "universeId": 1111111111, "placeId": 2222222222 },
  "live": { "universeId": 3333333333, "placeId": 4444444444 }
}
```

New games start with `0` ids (and an `idsNote` saying so). `0`, negative, fractional or string ids
are placeholders: `tools/publish` refuses a real publish with them (a `--dry-run` only warns).
Commit `deploy.json` after editing it. Then run `tools/sync-projects` and commit the regenerated
`src/shared/Config/Environments.luau` (v1.7.0: `GameConfig.environments`; `tools/lint` fails until you do).

## 4. Create the Open Cloud API key (minimum scope)

The key is a password. One key for publishing only; nothing else on it.

1. Ideally use a **dedicated automation account** that is a Group member with a role that can only
   edit these experiences (Roblox's own recommendation: a key can reach everything its owner can).
2. Creator Dashboard > **Open Cloud > API Keys** > Create API Key. Name it e.g.
   `PLACE_PUBLISHING_KEY`.
3. **Access Permissions** > Select API System: **universe-places** (Place Publishing). Add the test
   and live experiences of the games you publish (keep "Restrict by Experience" ON), operation
   **Write**. That is the scope `universe-places:write`, the only one
   `POST /universes/v1/{universeId}/places/{placeId}/versions` needs. Add no other API system.
4. **Security**: if you publish from a machine with a fixed IP, turn on "Restrict IP addresses" and
   add it in CIDR form (e.g. `203.0.113.7/32`). Without a fixed IP, leave it off and rely on the
   experience restriction. Optionally set an expiration date (then rotate before it).
5. Save & Generate, copy the key once.
6. `cp .env.example .env` and set `ROBLOX_OPEN_CLOUD_API_KEY=<key>` in `.env` (git-ignored by
   `.gitignore`: `.env`, `.env.*`). Or export it in your shell instead. Never commit it, never paste
   it into chat/issues/logs. `tools/doctor` only says present/missing.

Keys unused for 60 days auto-expire (re-enable the key toggle or edit the key). A 401 from publish
means wrong key/scope or an experience not added to the key; 409 means the place id is not in that
universe.

## 5. The publishing flow

```sh
tools/publish my-game --test --dry-run   # optional rehearsal: never contacts Roblox
tools/publish my-game --test             # upload to the TEST place
# playtest the test experience on Roblox (desktop + phone), several players if multiplayer
tools/publish my-game --live             # same commit only; asks you to type the game name
git add games/my-game/deploy.json GAMES.md && git commit -m "my-game: published <version>"
```

What `tools/publish <name> --test|--live [--dry-run]` does, in order:

1. **Gate** (`tools/lune/PublishGate.luau`, tested in `PublishGate.spec.luau`). A real publish is
   refused when:
   - the target's ids in `deploy.json` are placeholders;
   - there are uncommitted changes in `games/<name>/` (except `deploy.json`) or in the `roblox-core`
     submodule (pointer or checkout): what goes live must be a commit;
   - `ROBLOX_OPEN_CLOUD_API_KEY` is not set;
   - `--live` and the current HEAD was not published to `--test` first
     (`deploy.json test.published.commit` must equal HEAD, or have identical build inputs:
     no change in `games/<name>/` except `deploy.json`, or in the `roblox-core` pointer, between the two
     commits, e.g. when you committed the stamp, docs or tools in between).
2. **Checks**: `tools/lint` (incl. the framework pin), `tools/test games/<name>`, `tools/typecheck <name>`.
3. **Build**: `rojo build games/<name>/default.project.json -o build/<name>-<target>.rbxl`.
4. **Upload**: `POST https://apis.roblox.com/universes/v1/{universeId}/places/{placeId}/versions?versionType=Published`
   with header `x-api-key`, `Content-Type: application/octet-stream` and the `.rbxl` as the body.
   Success is HTTP 200 with `{"versionNumber": N}`. The key is read from a 0600 temp header file
   (`curl -H @file`), so it is never on a command line, in output, or in a `bash -x` trace.
   Rate limit (per key owner): 30 requests/minute.
5. **Stamp** (`roblox-core/tools/lune/deploy-stamp`): `deploy.json` gets `coreVersion` (StudWork
   version), `coreCommit` (last framework commit, short), `coreSha` (the pinned `roblox-core/`
   commit), `coreTag` (its tag), `coreStamp {how, at}` and `<target>.published = {commit, at, versionNumber}`; the game's
   **Core** cell in `GAMES.md` is updated. Commit both files afterwards.

`tools/framework-status` shows, for every game, the StudWork version/tag it was stamped with (vs the
pinned `roblox-core/` tag) and whether test and live
are in sync with HEAD (`in sync (vN)`, `behind HEAD`, `dry run of HEAD only`, `never published`,
`placeholder ids`).

### Dry runs

`--dry-run` runs the gate, all checks and the build, prints the exact request (key shown as
`<redacted>`, placeholder ids shown as `<PLACEHOLDER:0>`), stamps the core and records
`<target>.dryRun = {commit, at}`. It never contacts Roblox and does not need ids, a clean tree or
the key (those become warnings). So the whole flow can be rehearsed before any experience exists:

```sh
tools/publish my-game --test --dry-run   # records test.dryRun = HEAD
tools/publish my-game --live --dry-run   # accepted: test has a dry run of HEAD (warns)
```

A test **dry run never unlocks a real `--live`**: that needs a real `--test` of the same commit.
Dry runs modify `deploy.json` and `GAMES.md`; commit or `git checkout` them as you like.

### Adopted projects (v1.6.0)

In a project that adopted StudWork (`studwork.json` has `"adopted": true`, see
[adopting.md](adopting.md)):

- `tools/publish --live` (and `--live --dry-run`) runs `tools/adopt --verify .` first and refuses
  unless it passes: no `studwork-legacy.json` entry still lists `purchases`, no `onLegacyProduct`
  left, no critical risk, no script left in the place using DataStores or purchases. `--test` is
  allowed, so the migrated game can be tried in a test place of the same universe.
- A project whose `studwork.json` has `"placeFile"` (a Studio-only game) is never published by
  `tools/publish`, since its Rojo build has no map. The tool stops and prints the Studio steps: open
  the place, run `tools/dev` with the Rojo plugin connected, then File > Publish to Roblox (the test
  place first; live only after `tools/adopt --verify .` passes).

### Alternative endpoint (not used)

Roblox's place-publishing guide now shows the Assets API (`PATCH
https://apis.roblox.com/assets/v1/assets/{placeId}`, multipart, asynchronous with an operation to
poll, key permission "assets" read+write). The universes endpoint above is still in the Places
reference (marked Beta) with scope `universe-places:write` and a synchronous version number, so StudWork
keeps it: smaller key scope, simpler flow. If Roblox retires it, switch `tools/publish` step 4 and
`PublishGate.ENDPOINT` together.

## 6. Launch checklist (live experience, before making it public)

Do these on the **live** experience in the Creator Dashboard (Configure). Dashboard labels change;
search the Creator Docs for the item name if a menu moved.

- [ ] Latest commit published to test, playtested, then published to live with `tools/publish`;
      `tools/framework-status` shows live `in sync`.
- [ ] Name and description (no Robux-for-reward promises, no misleading claims).
- [ ] **Icon** (512x512, square, no text-heavy art).
- [ ] **Thumbnails** (1920x1080; several; first one is what most players see).
- [ ] **Maturity & compliance questionnaire** filled in honestly (it sets the content maturity
      label; unrated experiences have limited reach).
- [ ] Genre/subgenre, supported devices (phone/tablet/desktop/console as tested), max players and
      server fill settings.
- [ ] **Paid random items**: if anything sold for Robux (directly or via a currency bought with
      Robux) gives a random reward, declare it in the questionnaire, show the odds in game before
      purchase (StudWork's Rarity odds disclosure does this), and respect PolicyService restrictions
      (`Policy.paidRandomRestricted`; StudWork blocks paid rolls where they are not allowed).
- [ ] Developer products and game passes created **in the live experience** with their ids in the
      game's Config (test and live ids differ).
- [ ] Data store / API services enabled as the game needs (Configure > Security), Studio API
      access off unless needed.
- [ ] Privacy: switch the live experience to **Public**. Keep the test experience private.

## Troubleshooting

| Message | Fix |
|---|---|
| `refused: deploy.json test.universeId/placeId is a placeholder` | Step 3: paste the real ids and commit. |
| `refused: uncommitted changes in game/core paths` | Commit (or drop) them; publish what is committed. A dirty `roblox-core/`: `git -C roblox-core checkout -- .` (games never edit it). |
| `refused: --live needs this exact commit published to --test first` | `tools/publish <name> --test`, playtest, then `--live`. |
| `upload failed (HTTP 401)` | Key wrong/expired, missing `universe-places` Write, or experience not added to the key. |
| `upload failed (HTTP 403)` | The key owner can't publish to that place (group role). |
| `upload failed (HTTP 404)` / `409` | Wrong ids / place not in that universe. |
