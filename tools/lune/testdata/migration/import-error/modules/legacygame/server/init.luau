--!strict
--[[
	A copy of ../legacy-game whose import prints and then fails (v1.6.0 dogfood): tools/test-migration
	must show the LegacyImportFailed reason, the error and the print. Its fixture lives in fixtures/
	(not tests/legacy), so a bare tools/test-migration skips this game.
	The example game's import (StudWork v1.6.0, adopting.md §3). The old save (synthetic):
	  { coins, level, inventory = { itemId, ... }, settings = { music }, purchases = { [id]: t },
	    lastLogin }
	Coins go through Economy, items through Inventory (txApi only), the rest into this section.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Inventory = require(Modules:WaitForChild("Inventory"):WaitForChild("module"))
local Economy = require(Modules:WaitForChild("Economy"):WaitForChild("module"))

local LegacyGame = {}

function LegacyGame.init(ctx: any)
	local function copyFields(tx: any, old: any)
		local s = ctx.section(tx)
		if type(old.level) == "number" then
			s.level = old.level
		end
		if type(old.settings) == "table" and type(old.settings.music) == "boolean" then
			s.music = old.settings.music
		end
	end

	ctx.data.importLegacy({
		id = "v1-save",
		version = 1,
		source = { kind = "datastore", name = "PlayerData", key = "Player_{userId}" },
		import = function(tx: any, old: any)
			-- planted (tools/lune/MigrationCheck.spec.luau): test-migration must show this print and error
			print("import-error example: importing coins", old.coins)
			if old ~= nil then
				error("import-error example: planted failure")
			end
			if type(old.coins) == "number" and old.coins > 0 then
				ctx.depsTx[Economy].grant(tx, old.coins, "legacy_import", "Coins")
			end
			for _, id in (if type(old.inventory) == "table" then old.inventory else {}) :: { any } do
				ctx.depsTx[Inventory].add(tx, id)
			end
			copyFields(tx, old)
		end,
		-- idempotent: brings the balance up to the old value and copies the fields again
		merge = function(tx: any, old: any)
			local have = ctx.depsTx[Economy].balance(tx, "Coins")
			if type(old.coins) == "number" and old.coins > have then
				ctx.depsTx[Economy].grant(tx, old.coins - have, "legacy_merge", "Coins")
			end
			copyFields(tx, old)
		end,
		receipts = function(old: any): any
			return old.purchases
		end,
	})
end

return LegacyGame
