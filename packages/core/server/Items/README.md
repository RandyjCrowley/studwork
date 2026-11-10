# Core.Items

Registry of `ItemDef`s (`Types.ItemsAPI`). Owner: agent C.

- `register(defs)`: validates the whole batch with `ItemValidate` (unique stable id of 1..64 chars
  `[%w_%-%.:]`, name, valid `RarityTier`, finite `incomePerSec >= 0`, `tags` = array of strings,
  `model/icon/source` strings). All-or-nothing: any error raises `[Core.Items] ...` and nothing is
  registered. Duplicates (within the batch or with already registered ids) are rejected.
  `init()` registers `GameConfig.items`; games may call `register` later.
- `get(id)`, `all()` (registration order), `byTag(tag)` (indexed, returns a fresh array).
- `incomeOf(instance)` = `incomePerSec * mutation.multiplier` (`balance.mutations`; unknown mutation = 1,
  unknown item = 0). Economy (B) owns income; this is just the per-copy number.

Config keys: `items`, `balance.mutations`. Registered defs are frozen copies; don't mutate them.
Tests: `ItemValidate.spec.luau`.
