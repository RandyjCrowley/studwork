# tools/adopt test inputs (synthetic)

Small, made-up Rojo projects of NON-StudWork games for `tools/lune/AdoptAudit.spec.luau`. Their code
is deliberately legacy (raw DataStores, a ProcessReceipt without a history check, client-trusting
remotes). Nothing here is a real game or a real player's data; never "fix" these files.

- `raw-datastore/`: raw DataStore saves written from two scripts, a ProcessReceipt with no history
  check and a random product, a remote that trusts the client, leaderstats, `_G`.
- `profileservice/`: ProfileService saves and a ProcessReceipt that checks the history in the profile.
- `datastore2/`: DataStore2 with `Combine`.
- `lobby/`: a second place of the same universe writing `raw-datastore`'s store (`sharedStores`).
