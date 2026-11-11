# Items (collection kit)

Real StudWork module (core-v1.3.0). Definition: `../../shared/Items.luau`; server part: `init.luau`.

- The catalog is `GameConfig.items`, validated once at boot: the framework checks the base ItemDef
  (`id, name, rarity, model, icon, tags, source, keepOnRebirth`) plus every enabled module's
  namespaced `itemFields` (Economy: `item.economy.incomePerSec`); `ItemValidate` adds id/name length
  and tag checks. Rarity checks `rarity` against the active tier list.
- `api`: `get(id)`, `all()`, `byTag(tag)` (frozen defs), `mutation(id)`, `mutations()` (frozen
  MutationDefs from `config.Rarity.mutations`, namespaced fields included; a v1.2 `multiplier`
  without an `economy` table also gives `economy.incomeMultiplier`).
- `register` errors: no items after boot (§12). `extensions.mutations(list)` is the kit-internal
  hand-over from Rarity's init.
- Breaking: `incomeOf`, `register`, `onRegistered` and the base `incomePerSec` are gone. Income is
  Economy's (`item.economy.incomePerSec × mutation.economy.incomeMultiplier`); the compat adapter
  serves `incomeOf` to the bridged v1.2 Economy until it is real.
