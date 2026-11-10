# Core.Mail

`Mail.send(userId, kind, payload)` queues `{ kind, payload, sentAt }` in the target's profile via
`ProfileStore:MessageAsync` (same store Data uses, Mock in Studio without API access). Yields.
Works for offline users and other servers. Validation (`MailValidate`): kind `^[%w_-]{1,32}$`,
payload a JSON-safe table (finite numbers, depth <= 4), <= 1000 encoded bytes.

`Mail.onReceive(kind, handler)` — handler(player, payload) while the player is online. Messages
arrive through the profile MessageHandler: queued ones right after load, new ones on the
profile's next save (ProfileStore pings the owning server; for a player in this server Mail calls
`profile:Save()` immediately). A message is only marked processed if a handler for its kind
exists; otherwise it stays queued for the next session. At-least-once: make handlers idempotent.
