--!strict
--[[
	Player data schema. OWNED BY AGENT A (core/a-data).
	Pure: default data + migrations, no Roblox globals. Tested in Lune.

	Phase 0 stub: version 1 defaults only. Agent A adds migrations/001_init.luau ... and the
	migration runner (Schema.migrate) with tests.
]]

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))

local Schema = {}

Schema.CURRENT_VERSION = 1

function Schema.default(config: Types.GameConfig, now: number): Types.PlayerData
	local currency: { [string]: number } = {}
	currency[config.balance.primaryCurrency] = 0
	if config.balance.startingCurrency then
		for id, amount in config.balance.startingCurrency do
			currency[id] = amount
		end
	end
	local gameTable: { [string]: any } = {}
	if config.data then
		gameTable = table.clone(config.data.defaults)
	end
	return {
		schemaVersion = Schema.CURRENT_VERSION,
		currency = currency,
		inventory = {},
		displayed = {},
		upgrades = {},
		rebirths = 0,
		multipliers = {},
		streak = { day = 0, lastDay = 0 },
		lastSeen = 0,
		firstJoin = now,
		purchases = {},
		pity = {},
		stats = {},
		funnel = {},
		game = { [config.gameId] = gameTable },
	}
end

return Schema
