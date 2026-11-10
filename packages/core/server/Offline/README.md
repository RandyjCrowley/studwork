# Core.Offline

Public API: `Types.OfflineAPI` (`onReturn(fn(player, secondsAway))`). Pure math: `OfflineMath.luau`.

## Config: `balance.offline`
`capSeconds`, `minSeconds`, `payoutFraction` (clamped 0..1), `autoPay`.

## Behaviour
In `Data.onLoaded`: skipped on the first session (`stats.sessions <= 1`) or `lastSeen <= 0`.
`secondsAway = clamp(now - lastSeen, 0, capSeconds)` (clock skew -> 0 -> skipped); skipped below
`minSeconds`. If `autoPay`: pays `floor(Economy.getRate * secondsAway * payoutFraction)` (reason
`offline`, logged as an analytics Source by Economy) and sends feedback `pop` `"+N"`. Handlers
always run when not skipped.

## Ordering
`Economy.getRate` computes from PlayerData (displayed/inventory, rebirths, upgrade levels, saved
multipliers) on demand, so no waiting on Plot/Upgrades onLoaded handlers is needed. Session boosts
applied later (co-play, passes) are not included in the offline payout.
