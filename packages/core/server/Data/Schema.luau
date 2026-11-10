--!strict
--[[
	Player data schema. OWNED BY AGENT A (core/a-data).
	Pure: default data + migrations + load-time preparation, no Roblox globals. Tested in Lune.

	CURRENT_VERSION  schema version written by this code (PlayerData.schemaVersion).
	MIGRATIONS       [toVersion] = fn(old) -> new, built from Data/migrations/NNN_*.luau.
	default(config, now)            fresh PlayerData (currency/game defaults from GameConfig).
	prepare(raw, config, now, migrations?, currentVersion?) -> (data, status, message?, report?)
	  Runs on every load. Works on a deep COPY of raw, so on failure raw is untouched.
	  status "new"    raw was empty (first join): defaults, lastSeen = firstJoin = now.
	         "ok"     migrated (schema + game table), reconciled, sanitized, purchases pruned.
	         "newer"  raw.schemaVersion (or the game table's _version) is newer than this code.
	         "error"  a migration failed.
	  For "newer"/"error" the returned data is raw itself; the caller must NOT save over it.

	Game table: PlayerData.game[config.gameId], defaults = config.data.defaults, migrations =
	config.data.migrations ([toVersion] = fn), version = config.data.version (default 1). Its own
	version is stored inside it under the reserved key "_version" (Migrate.GAME_VERSION_KEY); a
	saved game table without "_version" counts as version 1.
]]

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))
local Migrate = require(script.Parent.Migrate)
local Sanitize =
	require(game:GetService("ServerScriptService"):WaitForChild("Compat"):WaitForChild("V12Sanitize"))

local Schema = {}

Schema.CURRENT_VERSION = 1
-- Receipt ids kept in PlayerData.purchases (oldest pruned beyond this). Engineering constant:
-- Roblox retries an unprocessed receipt for days, never across 200 newer purchases.
Schema.PURCHASES_CAP = 200
Schema.GAME_VERSION_KEY = Migrate.GAME_VERSION_KEY

local migrationsFolder: any = script.Parent:WaitForChild("migrations")
local MIGRATION_MODULES: { any } = {
	require(migrationsFolder:WaitForChild("001_init")) :: any,
}

local MIGRATIONS: { [number]: Migrate.MigrationFn } = {}
for _, module in MIGRATION_MODULES do
	assert(MIGRATIONS[module.version] == nil, "duplicate migration version " .. tostring(module.version))
	assert(module.version <= Schema.CURRENT_VERSION, "migration newer than CURRENT_VERSION")
	MIGRATIONS[module.version] = module.migrate
end
Schema.MIGRATIONS = MIGRATIONS

local function gameDefaults(config: Types.GameConfig): { [string]: any }
	local defaults: { [string]: any } = if config.data then Sanitize.deepCopy(config.data.defaults) else {}
	defaults[Migrate.GAME_VERSION_KEY] = if config.data then config.data.version or 1 else 1
	return defaults
end

function Schema.default(config: Types.GameConfig, now: number): Types.PlayerData
	local currency: { [string]: number } = {}
	currency[config.balance.primaryCurrency] = 0
	if config.balance.startingCurrency then
		for id, amount in config.balance.startingCurrency do
			currency[id] = amount
		end
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
		lastSeen = now, -- first join: "previous session" = now, so offline time is 0
		firstJoin = now,
		purchases = {},
		pity = {},
		stats = { sessions = 0 },
		funnel = {},
		game = { [config.gameId] = gameDefaults(config) },
		mail = { seen = {}, attempts = {}, dead = {} },
	}
end

export type Status = "new" | "ok" | "newer" | "error"

function Schema.prepare(
	raw: { [string]: any },
	config: Types.GameConfig,
	now: number,
	migrations: { [number]: Migrate.MigrationFn }?,
	currentVersion: number?
): ({ [string]: any }, Status, string?, Sanitize.Report?)
	local target = currentVersion or Schema.CURRENT_VERSION
	if next(raw) == nil then
		local fresh = Schema.default(config, now) :: any
		fresh.schemaVersion = target
		return fresh, "new", nil
	end

	local data: { [string]: any } = Sanitize.deepCopy(raw)
	local fromVersion = Migrate.readVersion(data.schemaVersion, 0)
	local migrated, status, _, message = Migrate.run(data, fromVersion, target, migrations or MIGRATIONS)
	if status == "newer" then
		return raw, "newer", `schemaVersion {fromVersion} > {target}`
	elseif status == "error" then
		return raw, "error", message
	end
	data = migrated
	data.schemaVersion = target

	-- Top-level reconcile. Currency ids added later start at 0 for existing players (the
	-- startingCurrency gift is for new players only).
	local defaults = Schema.default(config, now) :: any
	for id in defaults.currency do
		defaults.currency[id] = 0
	end
	defaults.lastSeen = 0
	defaults.game = {}
	Sanitize.reconcile(data, defaults)

	-- Per-game table.
	local gameId = config.gameId
	local gameTable = data.game[gameId]
	local gameTarget = if config.data then config.data.version or 1 else 1
	if type(gameTable) ~= "table" then
		data.game[gameId] = gameDefaults(config)
	else
		local gameFrom = Migrate.readVersion(gameTable[Migrate.GAME_VERSION_KEY], 1)
		local gameMigrations = if config.data then config.data.migrations else nil
		local newGame, gameStatus, _, gameMessage =
			Migrate.run(gameTable, gameFrom, gameTarget, gameMigrations)
		if gameStatus == "newer" then
			return raw, "newer", `game[{gameId}] version {gameFrom} > {gameTarget}`
		elseif gameStatus == "error" then
			return raw, "error", gameMessage
		end
		newGame[Migrate.GAME_VERSION_KEY] = gameTarget
		if config.data then
			Sanitize.reconcile(newGame, config.data.defaults)
		end
		data.game[gameId] = newGame
	end

	local _, report = Sanitize.playerData(data)
	Sanitize.reconcile(data.currency, defaults.currency) -- dropped invalid balances -> 0
	if not Sanitize.isFinite(data.stats.sessions) then
		data.stats.sessions = 0
	end
	Sanitize.prunePurchases(data.purchases, Schema.PURCHASES_CAP)
	return data, "ok", nil, report
end

return Schema
