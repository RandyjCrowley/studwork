--!strict
--[[
	Mail module definition (kit: social). core-v1.3.0 Phase 1: a real module; the server part is
	../server/Mail (README.md there). Save section "mail" = { mail = { seen, attempts, dead,
	box?, outbox?, sent? } }: the v1.2 field, unchanged (FrameworkSection.V12_MAP); `sent` is new
	(escrowed gifts awaiting their recipient, R1). Not replicated (the mailbox goes out as
	extra.mailbox).

	config (GameConfig.config.Mail.mail)
	  maxAttempts      integer?   handler errors before a message is dead-lettered (default 10)
	  mailboxCap       integer?   held messages per player (default 500)
	  backoff          table?     { base, factor, max } seconds between retries (30, 2, 900)
	  giftCap          integer    undelivered escrowed gifts per recipient (default 100; R1)
	  returnAfterDays  number     an uncollected escrowed gift returns to its sender (default 14)
	  returnKinds      {string}   kinds that are escrowed (default { "core_gift" })
	  sweepSeconds     number     how often online senders' gifts are checked for return (3600)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))

return StudWork.defineModule({
	name = "Mail",
	version = "1.3.0",
	framework = "^1.3.0",
	description = "Cross-server mail, mailbox, crash-safe outbox and gift escrow (social kit)",
	config = {
		schema = {
			mail = {
				maxAttempts = "integer(1..)?",
				mailboxCap = "integer(1..)?",
				backoff = "table?",
				giftCap = "integer(1..)",
				returnAfterDays = "number(0..)",
				returnKinds = "{string}",
				sweepSeconds = "number(1..)",
			},
		},
		defaults = {
			mail = {
				giftCap = 100,
				returnAfterDays = 14,
				returnKinds = { "core_gift" },
				sweepSeconds = 3600,
			},
		},
	},
	data = {
		key = "mail",
		version = 1,
		default = { mail = { seen = {}, attempts = {}, dead = {} } },
		replicate = false,
	},
	client = "Mail",
})
