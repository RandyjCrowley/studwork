--!strict
--[[
	The second example game's import (StudWork v1.6.0, adopting.md §3). The old save (synthetic) is
	split over two stores, a map of sources:
	  main   = PlayerData / Player_{userId}: { coins, rebirths, pets = { { id, uid } }, purchases =
	           { [receiptId]: true } }
	  backup = CoinsBackup / {userId}: { coins } (the old game restored max(main, backup) at join)
	Either store may be missing for a player.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Inventory = require(Modules:WaitForChild("Inventory"):WaitForChild("module"))
local Economy = require(Modules:WaitForChild("Economy"):WaitForChild("module"))

local LegacySplit = {}

function LegacySplit.init(ctx: any)
	ctx.data.importLegacy({
		id = "v1-split",
		version = 1,
		source = {
			main = { kind = "datastore", name = "PlayerData", key = "Player_{userId}" },
			backup = { kind = "datastore", name = "CoinsBackup", key = "{userId}" },
		},
		import = function(tx: any, old: any)
			local main = if type(old.main) == "table" then old.main else {}
			local backup = if type(old.backup) == "table" then old.backup else {}
			local coins = math.max(
				if type(main.coins) == "number" then main.coins else 0,
				if type(backup.coins) == "number" then backup.coins else 0
			)
			if coins > 0 then
				ctx.depsTx[Economy].grant(tx, coins, "legacy_import", "Coins")
			end
			for _, pet in (if type(main.pets) == "table" then main.pets else {}) :: { any } do
				if type(pet) == "table" and type(pet.id) == "string" then
					ctx.depsTx[Inventory].add(tx, pet.id)
				end
			end
			if type(main.rebirths) == "number" then
				ctx.section(tx).rebirths = main.rebirths
			end
		end,
		receipts = function(old: any): any
			return if type(old.main) == "table" then old.main.purchases else nil
		end,
	})
end

return LegacySplit
