# Core.Policy

Paid random item policy (`Types.PolicyAPI`). Owner: agent C.

- `paidRandomRestricted(player)`: `PolicyService:GetPolicyInfoForPlayerAsync(player).ArePaidRandomItemsRestricted`.
  **Fails closed**: `true` until the lookup succeeds and after every attempt fails.
- Lookup on join: up to `MAX_ATTEMPTS` (4) with backoff `BASE_DELAY_SEC * 2^(n-1)` capped at
  `MAX_DELAY_SEC`; stops when the player leaves. State is cleared on `PlayerRemoving`.
- Replicates `paidRandomRestricted` with `ctx.setReplicated` (true first, then the known value), so
  client UI can hide paid-random prompts.
- Used by `Rarity.roll(..., { paid = true })` (refuses with `"restricted"`) and `Inventory.transfer`
  (refuses `paid:` items).

Studio console: `restrict <true|false|clear> [userId]` overrides the value for testing.
