# Known issues

Open problems in StudWork that are known, understood and not yet fixed. Each entry says where the
problem is, what fails, and what to do until it is fixed. Fixed issues are not listed here; see
`CHANGELOG.md` for those.

**Ids.** `R<n>` ids come from the framework's code reviews and keep their original numbers, so gaps
in the sequence are issues that have since been fixed. `V<n>` ids are issues that only show up when
StudWork is used from a games repo (as a submodule). `O<n>` ids are smaller limits that were noted
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

## Not verified live

Some behaviour needs a person in Studio: Local Server with one and two clients, Device Emulator
presets, listening to the sounds, and the real DataStore on a published test place.
`docs/manual-qa.md` has the checklist; the automated cover is in `packages/framework/test/sim/`.
