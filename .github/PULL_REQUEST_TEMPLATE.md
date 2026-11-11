## What and why

<!-- What does this change, and why? Link the issue. -->

## Checks

- [ ] `tools/lint`
- [ ] `tools/typecheck --all`
- [ ] `tools/test` (includes `tools/test-games-repo` and `tools/test-single-game`)
- [ ] `tools/test-sim`
- [ ] `tools/build --all`
- [ ] `tools/bench` (only if per-tick or per-player code changed; within +20%)

## Rules

- [ ] A `*.spec.luau` that fails without this change; no assertion weakened or removed
- [ ] Server-authoritative; every client argument validated; network only through the framework
- [ ] Balance numbers in config, defaults documented
- [ ] Paid random items: odds disclosed, paid rolls via `ctx.compliance`, PolicyService fallback
- [ ] Nothing is special (no framework internals from kits/modules; framework names no kit)
- [ ] Module API additive only; new API in `module-api.md` §19+ marked `(added in ...)`
- [ ] Docs page updated; `CHANGELOG.md` entry under `[Unreleased]`; `docs/decisions.md` if it is a design choice
- [ ] No secrets, no absolute paths
