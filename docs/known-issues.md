# Known issues

Open problems in StudWork that are known, understood and not yet fixed. Each entry says where the
problem is, what fails, and what to do until it is fixed. Fixed issues are listed only by id
at the end ("Fixed ids"); `CHANGELOG.md` has the details.

**Ids.** `R<n>` ids come from the framework's code reviews and keep their original numbers, so gaps
in the sequence are issues that have since been fixed. `V<n>` ids are issues that only show up when
StudWork is used from a games repo (as a submodule). `S<n>` ids only show up in a single-game project (v1.5.0). `O<n>` ids are smaller limits that were noted
without a review id.

**Severity.**
- **High:** can lose or duplicate player data or purchases in realistic use.
- **Medium:** wrong behaviour or a guardrail gap that needs care from game code or reviewers.
- **Low:** an edge case, a cosmetic problem, or a limit that is unlikely to matter in practice.

There are no open Critical or High issues.

## Medium

### R3. An unsent gift waits for its sender
- **Where:** `packages/kits/social/Mail/server/Outbox.luau`.
- **What fails:** a gift is written to the sender's outbox and saved before it is sent. If the server
  shuts down or the sender leaves before the send succeeds, the outbox is retried once more on leave
  and again at the sender's next login, but not from any other server (that would need the sender's
  save session). A sender who never returns leaves the gift undelivered. The item is never lost or
  duplicated, only delayed.
- **Workaround:** none needed for correctness; tell players that gifts can take until the sender's
  next visit if a server closes mid-send.

### R9. The "games don't edit the framework" guardrail is a convention in the framework repo
- **Where:** `tools/lune/guardrails.luau` (`packages` check).
- **What fails:** inside this repo the check works on branch names (`game/*` branches may not change
  `packages/`) and on staged changes that mix `packages/` with game files. A `packages/` change
  committed on its own on a branch with another name, or anything already merged, is not caught. (In
  a games repo the check is strict: the framework submodule must sit exactly on a release tag.)
- **Workaround:** review merges of game branches.

### R25. The framework still carries v1.2-shaped kit data
- **Where:** `packages/framework/shared/Types.luau` (`BalanceConfig` sections such as `income`,
  `inventory`, `rarityTables`, `upgrades`, `rebirth`, `offline`, `streak`, `friends`, `plot`, and
  `PlayerData.mail`), the flat `ReplicatedState` fields (`ratePerSec`, `multiplier`, `plotName`,
  `odds`, `mailbox`) filled by `Replication/Snapshot.build` and the client `State`,
  `FrameworkSection.V12_MAP`, and the default theme's `rebirth`/`streak` sounds.
- **What fails:** nothing at runtime, and no kit gets a capability a third-party module lacks (module
  state lives under `state.modules.<Name>`, config under `config.<Name>`). But the framework still
  knows these lower-case kit shapes, which the `special` guardrail does not flag. Removing them would
  break the v1.2-compatible client surface and saves made before v1.3.
- **Workaround:** new modules should use their own section, config and `state.modules.<Name>`, never
  the flat fields. Planned fix for a major version: move the kit types into each kit's
  `module.luau`, drop the flat view, and let the scan derive each kit's `data.key`.

## Low

### R11. Purchase effects are dropped if the final save fails after the buyer leaves
- **Where:** `packages/framework/server/Shop/` (see its README).
- **What fails:** if the buyer leaves while a grant's save is unconfirmed, the framework makes one
  more confirmed save and then runs the `tx.after` effects. If that save also fails, the effects are
  dropped with a warning. The grant itself is safe: it is in the save, or the receipt is retried.
- **Workaround:** never put grant logic in `tx.after`; it is for effects (toasts, sounds,
  analytics), and must not assume the buyer is still in the server.

### R12. `tools/publish` trusts `deploy.json`
- **Where:** `tools/lune/PublishGate.luau`.
- **What fails:** the "tested before live" gate reads `test.published.commit` from `deploy.json`;
  hand-editing it unlocks `--live` without a test publish.
- **Workaround:** don't edit the publish stamps by hand; review `deploy.json` changes.

### R17. Mail handlers before a `false` run again on claim
- **Where:** `packages/kits/social/Mail/server/Delivery.luau`.
- **What fails:** when one handler of a mail kind returns `false` ("can't accept now"), the handlers
  before it have already run, and they run again when the message is claimed from the mailbox.
- **Workaround:** documented contract: mail handlers must be safe to run twice.

### R18. ProcessReceipt replacement can't be detected on live servers
- **Where:** `packages/framework/server/Shop/`, `packages/framework/server/Platform.luau`.
- **What fails:** `MarketplaceService.ProcessReceipt` is write-only in the engine, so the framework's
  runtime check (warn, analytics event, reclaim) only works with the test platform. Live,
  `receiptCheck().status` reports the check as unavailable.
- **Workaround:** enforcement is the `purchases` lint guardrail plus Shop claiming the callback as
  the very last boot step. Never assign ProcessReceipt yourself; patch vendored packages that do.

### R21. Only the last 200 receipts are remembered
- **Where:** `_framework.purchases` (`packages/framework/server/Data.luau`, `PURCHASES_CAP`).
- **What fails:** a receipt that Roblox re-delivers after more than 200 newer purchases by the same
  player could be granted twice.
- **Workaround:** none needed in practice. The fix (receipts in their own section) is a data-contract
  change, left for a later version.

### R23. Writing `_framework` every tick is slow
- **Where:** framework data commits.
- **What fails:** a module that writes into `_framework` every tick costs about 1.6–1.9 ms per tick
  at 50 players, because each commit re-walks the stored receipts. The shipped kits don't do this
  (0.60–0.65 ms per tick).
- **Workaround:** keep per-tick stats in your module's own data section.

### R24. Wide display fonts can crowd the HUD
- **Where:** framework HUD (action bar).
- **What fails:** with a wider theme display font, auto-widened action-bar buttons can touch the
  top-centre HUD in a small viewport. Cosmetic.
- **Workaround:** pick a narrower display font or shorter action labels.

### R26. Runtime-built names evade the framework scan
- **Where:** `tools/lune/guardrails.luau` (`special` check).
- **What fails:** names built at runtime (`string.char`, `string.format`, `string.reverse`,
  `table.concat`, `gsub`) are not seen. Lint guards against mistakes, not deliberate obfuscation.
- **Workaround:** review framework merges.

### R27. One sim spec doesn't guard the save-version bump
- **Where:** `packages/framework/test/sim/` (the stolen-save / `saveNow` version case).
- **What fails:** the sim spec passes even without the `_framework` version bump on `saveNow`,
  because ProfileStore's own `beforeSave` bumps it during the save.
- **Workaround:** the unit spec `packages/framework/test/SaveNowVersion.spec.luau` is the regression
  guard; keep it.

### O1. A long DataStore outage at join leaves the player waiting
- **Where:** `packages/framework/server/Store.luau` (`StartSessionAsync` with `Cancel`).
- **What fails:** the load cancels only when the player leaves, so ProfileStore's own load timeout is
  off and a player waits unloaded, without a kick, until the outage ends. Defaults are never written
  over an existing save (tested).
- **Workaround:** none; the loading screen stays up.

### O2. Net's pre-start queue is shared
- **Where:** `packages/framework/server/Net/init.luau` (`PENDING_CAP = 256`).
- **What fails:** requests that arrive before boot finishes are queued in one buffer for all players
  and events; past 256 they are dropped.
- **Workaround:** none needed; boot is short.

### O3. Odds don't show a pity-adjusted long-run rate
- **Where:** `OddsDetail` (Rarity kit).
- **What fails:** disclosed odds are per roll; the effective rate including pity is not computed.
- **Workaround:** describe pity in the game's own UI text if you use it.

### O4. ProfileStore always writes once when a session ends
- **Where:** framework Data/Store.
- **What fails:** on a migration failure the player is kicked and the session ends with one save of
  the untouched loaded data (never defaults). Harmless, but it is a write.
- **Workaround:** none needed.

### O5. A failed `capBonus` counts as no bonus
- **Where:** `packages/kits/collection/Inventory/server/init.luau` (`capOf`),
  `packages/kits/economy/Economy/server/init.luau` (`recompute`, `rateFactor`).
- **What fails:** both kits pcall a bonus function and treat an error as 0. A bonus that asks
  `ctx.shop.ownsPass` for a pass whose lookup hasn't answered yet (v1.6.1: an error inside a
  transaction) then counts as no bonus until it answers: a lower cap or rate, never a higher one.
  Purchases are not affected (the retry survives the pcall).
- **Workaround:** none needed for correctness; read pass perks after the player loaded, or track
  them with `ctx.shop.onPassOwned`.

### O6. Undeclared legacy writes are only caught in tests and Studio, and not every kind
- **Where:** `packages/framework/server/Shop/` (`onLegacyProduct`, v1.6.1).
- **What fails:** a write deferred past the old handler's return (`task.defer`, `task.delay`, a
  later event) isn't caught. In Studio only the keys the registered `importLegacy` sources read are
  compared (no import, no comparison), and nothing is compared with API access off. Live servers
  only get the boot warning.
- **Workaround:** the bridge is for test places only, and `tools/adopt --verify` refuses it before
  a live publish.

### O7. The legacy anchor and the adopted marker live in git history
- **Where:** `tools/lune/guardrails.luau`, `tools/lune/AdoptedMarker.luau`.
- **What fails:** a history rewrite resets both. In a project with no remote (or never pushed) that
  can't be detected; `tools/lint --anchor-remote` needs a remote default branch and full history. In
  a shallow clone, lint only notes that the marker's history can't be read (`tools/publish --live`
  refuses there).
- **Workaround:** push the adoption commit and run `tools/lint --anchor-remote` in CI (the
  single-game CI template does).

## Games-repo mode

### V2. Generated module READMEs have a wrong docs link in a games repo
- **Where:** `templates/module/README.md.tmpl` (written by `tools/make-module`).
- **What fails:** the README links `../../../../docs/framework/...`, which is right inside this repo
  but not inside a games repo (the output was kept byte-identical to v1.3.1).
- **Workaround:** fix the link by hand, or point it at the framework's docs online.

### V3. Games mode depends on Rokit's storage layout
- **Where:** `tools/_common.sh`.
- **What fails:** in a games repo the tools link Rokit's tool storage
  (`~/.rokit/tool-storage/<owner>/<repo>/<version>`) into `.cache/studwork-bin/`, because Rokit can't
  be pointed at the core's `rokit.toml`. A change to Rokit's storage layout breaks this.
- **Workaround:** if tools aren't found, check that path; the fix is in one place.

### V4. The pin guardrail runs from the pinned framework
- **Where:** the `packages` guardrail, run from the submodule.
- **What fails:** pinning a tag older than v1.4.0 disables the pin check, because older releases
  don't have it.
- **Workaround:** only move the pin forward.

Fixed in v1.4.1: **V1**, the games-repo pre-commit hook failing the pin check on every commit (git's
hook environment broke the check's `git -C` calls).

## Single-game projects

`S<n>` ids are issues that only show up in a single-game project (`tools/new-project`, v1.5.0).

### S1. `tools/new-project` leaves parent folders it created after a failure
- **Where:** `tools/new-project` (cleanup removes only the target folder).
- **What fails:** `tools/new-project deep/a/b ...` that fails (for example a missing tag) removes `b`
  but leaves `deep/a`. Nothing it didn't create is ever deleted.
- **Workaround:** remove the empty folders by hand, or create the parent folder first.

### S2. A project created inside another git repo is a silent nested repo
- **Where:** `tools/new-project`.
- **What fails:** no warning when the target is inside another repository's working tree; the outer
  repo then shows the project as untracked.
- **Workaround:** create projects outside other repos (or add them to the outer repo's ignore file).

### S3. The layout marker is matched as text
- **Where:** `tools/_common.sh` (`layout_of`) and `tools/lune/Roots.luau` (`isSingleMarker`).
- **What fails:** any `"layout": "single-game"` in `studwork.json`, even nested under another key,
  switches the project to single-game mode, and the core folder's name isn't checked against it.
- **Workaround:** keep `studwork.json` as `tools/new-project` writes it; never add the marker to a
  games repo.

### S4. The sim loads only `src/` and `modules/` of a single-game project
- **Where:** `packages/framework/test/sim/Loader.luau`.
- **What fails:** a game that maps another top-level folder in `default.project.json` gets it in the
  place, linted and type-checked, but a `Boot.spec` running in the sim doesn't see it.
- **Workaround:** keep game code under `src/` and `modules/` (the layout `tools/new-project` makes).

## Not verified live

Some behaviour needs a person in Studio: Local Server with one and two clients, Device Emulator
presets, listening to the sounds, and the real DataStore on a published test place.
`docs/manual-qa.md` has the checklist; the automated cover is in `packages/framework/test/sim/`.

## Fixed ids (index)

Code comments, `CHANGELOG.md` and `docs/decisions.md` still cite some ids of issues that are fixed.
`N<n>` ids come from the v1.1.0 review, `R<n>` from later reviews.

| Id | Fixed in | What it was |
|---|---|---|
| N1 | v1.2.0 | A Mail handler that couldn't accept a message dead-lettered it; now it waits in the mailbox |
| N2 | v1.1.0 | A failed `PolicyService` lookup stayed unknown; now it is retried |
| N3 | v1.2.0 | Items registered later weren't added to odds already disclosed to clients |
| N4 | v1.2.0 | A paid roll could use luck the client hadn't been shown odds for |
| N5 | v1.1.0 | Copies rolled with a paid currency weren't tagged (`paidcur:`) and could be traded |
| N6 | v1.2.0 | Legacy mail messages without an id could be delivered twice |
| N7 | v1.1.0 | A boot that failed part-way left the framework half-usable |
| N8 | v1.2.0 / v1.3.0 | Read APIs returned live save tables that callers could mutate (now frozen views) |
| N9 | v1.2.0 | Receipts dropped when a player left were not reported |
| N10 | v1.1.0 | Mail tried to deliver to players who had already left |
| R1 | v1.3.0 | Gifts to a player who never returns could overflow ProfileStore's message queue (now capped per recipient, returned after 14 days) |
| R2 | v1.2.0 | A same-server gift bypassed the crash-safe outbox |
| R4, R5 | v1.2.0 | Paid-currency tables and table-wide luck could reach paid rolls without disclosure |
| R6, R7 | v1.3.0 | Dead letters couldn't be replayed on live servers; duplicate detection had a short window |
| R8, R13, R14 | v1.2.0 / v1.3.0 | Guardrail evasions (aliases, string tricks, neutral folders) |
| R10 | v1.3.0 | The rest of N8: frozen read views everywhere, not only in Studio |
| R15 | v1.2.0 | The mail payload hash wasn't real FNV-1a |
| R16 | v1.3.0 | A generator bug in `tools/new-game` |
| R19 | v1.3.1 | The framework still knew kit names and kit actions; now each kit is one folder with its own `net.blink` |
| R20 | v1.3.1 | A paid currency with no registered spender wasn't caught; now a boot error |
| R22 | v1.3.1 | `saveNow` didn't bump the `_framework` section version |
| V1 | v1.4.1 | The games-repo pre-commit hook failed the pin check on every commit |
