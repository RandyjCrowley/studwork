--!strict
--[[
	Rebirth module definition (kit: economy). v1.3.0: a real StudWork module; the
	server part is ../server/Rebirth (README there: the rebirth transaction and the inventory
	rules with their compliance limits).

	config (config.Rebirth):
	  rebirth = { baseCost, costGrowth, currency? (default Economy's primary),
	    multiplierPerRebirth, keepInventory, keepDisplayed?, resetCurrencies? (default
	    { primary }), maxRebirths? }    (v1.2 keys; defaults = the template's: 5000, 3, 0.5, false, false)
	  onRebirth = { paid = "keep", paidCurrency = "wipe" | "keep", earned = "wipe" | "keep",
	    itemOverrides = boolean }        default { "keep", "wipe", "wipe", true } (the v1.2 rules)
	  paid accepts only "keep": a Robux-bought copy can never be made wipeable.
	data: section `rebirth` = { rebirths }.
	client: the `rebirth` action (own Blink event `Rebirth`, ./net.blink), served by ./client/init.luau.
	optional: Inventory (the inventory wipe uses Inventory.txApi.list / remove).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Economy =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Economy"):WaitForChild("module"))
local Inventory =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Inventory"):WaitForChild("module"))

return StudWork.defineModule({
	name = "Rebirth",
	version = "1.3.0",
	framework = "^1.3.0",
	description = "Rebirths: reset progress for a permanent income multiplier (economy kit)",
	dependsOn = { Economy },
	optional = { Inventory },
	config = {
		schema = {
			rebirth = {
				baseCost = { type = "number(0..)", description = "cost of the first rebirth" },
				costGrowth = {
					type = "number(0..)",
					description = "cost = floor(baseCost * costGrowth ^ rebirths)",
				},
				currency = { type = "string?", description = "cost currency (default Economy's primary)" },
				multiplierPerRebirth = {
					type = "number(0..)",
					description = "income multiplier = 1 + rebirths * multiplierPerRebirth",
				},
				keepInventory = { type = "boolean", description = "true = a rebirth wipes no inventory copy" },
				keepDisplayed = {
					type = "boolean?",
					description = "true = Plot keeps displayed slots (read by Plot)",
				},
				resetCurrencies = {
					type = "{string}?",
					description = "currencies reset to their starting balance (default { primary })",
				},
				maxRebirths = { type = "integer(0..)?", description = "no limit when nil" },
			},
			onRebirth = {
				paid = {
					type = "enum(keep)",
					description = "Robux-bought copies (paid:) are always kept; no other value is allowed",
				},
				paidCurrency = {
					type = '"wipe"|"keep"',
					description = "copies rolled with a paid currency (paidcur:); the tag is kept either way",
				},
				earned = { type = '"wipe"|"keep"', description = "every other copy" },
				itemOverrides = {
					type = "boolean",
					description = "ItemDef.keepOnRebirth true keeps / false wipes a non-Robux copy",
				},
			},
		},
		defaults = {
			rebirth = {
				baseCost = 5000,
				costGrowth = 3,
				multiplierPerRebirth = 0.5,
				keepInventory = false,
				keepDisplayed = false,
			},
			onRebirth = { paid = "keep", paidCurrency = "wipe", earned = "wipe", itemOverrides = true },
		},
	},
	data = { key = "rebirth", version = 1, default = { rebirths = 0 }, replicate = { "rebirths" } },
	client = "Rebirth",
})
