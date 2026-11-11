--!strict
--[[
	COMPAT (deleted in Phase 2). The v1.2 Data API (Types.DataAPI + DataInternal.sectionVersion)
	that the unchanged v1.2 kit services call as ctx.services.Data, served by the framework's
	per-module save sections (module-api.md §6) through CompatDoor.

	Flat view over sections. v1.2 code reads and writes ONE flat PlayerData. Each v1.2 field maps
	to (section key, field) through FrameworkSection.V12_MAP (currency -> economy.currency,
	inventory -> inventory.inventory, pity -> rarity.pity, displayed -> plot.displayed, stats ->
	_framework.stats, ...); `game[gameId]` is the game module's own section. A field whose section
	isn't there (its module is not enabled) reads as its v1.2 default and is never written.

	  get(player) -> flat view            LIVE (as v1.2 Data.get): reads go to the committed sections
	  update(player, fn(data)) -> boolean ONE framework transaction (ctx.tx rules: working copy,
	                                      commit on success, no yield, no nesting, one player);
	                                      `data` is the flat view over that tx's working copies
	  onLoaded(fn(player, data)), isLoaded, getGame, updateGame, saveAsync,
	  sectionVersion(player, field)       the version of the field's SECTION (coarser than v1.2's
	                                      per-field version: a sibling field's write also moves it,
	                                      which only costs an extra copy, never a missed change)
	The v1.2 schemaVersion reads as 1.
]]

local ServerScriptService = game:GetService("ServerScriptService")
local FrameworkSection = (require :: any)(
	ServerScriptService:WaitForChild("Framework"):WaitForChild("FrameworkSection")
)

local V12Data = {}

-- v1.2 defaults of every flat field (Data/Schema.luau default()), for sections that don't exist.
local DEFAULTS: { [string]: () -> any } = {
	currency = function()
		return {}
	end,
	inventory = function()
		return {}
	end,
	displayed = function()
		return {}
	end,
	upgrades = function()
		return {}
	end,
	rebirths = function()
		return 0
	end,
	multipliers = function()
		return {}
	end,
	streak = function()
		return { day = 0, lastDay = 0 }
	end,
	pity = function()
		return {}
	end,
	mail = function()
		return { seen = {}, attempts = {}, dead = {} }
	end,
	stats = function()
		return { sessions = 0 }
	end,
	funnel = function()
		return {}
	end,
	purchases = function()
		return {}
	end,
}
V12Data.DEFAULTS = DEFAULTS

V12Data.MAP = FrameworkSection.V12_MAP

-- opts: { rt, gameId, gameKey, spawn(fn, ...), log(msg), signals (v1.2 signal set) }
function V12Data.new(opts: any): any
	local rt = opts.rt
	local data = rt.data
	local gameId: string = opts.gameId
	local gameKey: string? = opts.gameKey
	local spawn: (...any) -> () = opts.spawn
	local signals = opts.signals
	local loadedHandlers: { (any, any) -> () } = {}
	local warned: { [string]: boolean } = {}

	local D: any = {}

	local function warnOnce(key: string, msg: string)
		if not warned[key] then
			warned[key] = true
			opts.log(msg)
		end
	end

	-- Live flat view (reads committed data; a write outside a tx goes to the live section).
	local function liveView(player: any): any
		return setmetatable({}, {
			__index = function(_, field: any): any
				local root = data.compatLive(player)
				if root == nil then
					return nil
				end
				if field == "schemaVersion" then
					return 1
				elseif field == "game" then
					local g = if gameKey then root[gameKey] else nil
					return { [gameId] = g }
				end
				local key = V12Data.MAP[field]
				if key == nil then
					return nil
				end
				local section = root[key]
				if type(section) ~= "table" then
					local make = DEFAULTS[field]
					return if make then make() else nil
				end
				local value = section[field]
				if value == nil and DEFAULTS[field] then
					value = DEFAULTS[field]() -- not written back: committed data changes only in a tx
				end
				return value
			end,
			__newindex = function(_, field: any, value: any)
				local root = data.compatLive(player)
				local key = V12Data.MAP[field]
				if root == nil or key == nil or type(root[key]) ~= "table" then
					warnOnce(
						"live:" .. tostring(field),
						`[Compat.Data] dropped a write to '{tostring(field)}' (no such section loaded)`
					)
					return
				end
				root[key][field] = value
				data.compatTouch(player, key)
			end,
		})
	end

	-- Flat view over an OPEN framework tx (working copies, copied on first access). The view
	-- remembers its tx (txOf) so a hook the bridge hands a flat view to (Rebirth reset steps,
	-- PHASE1-CONTRACT Rebirth.extensions.resetStep) can get the framework tx back.
	local viewTx: { [any]: any } = setmetatable({}, { __mode = "k" }) :: any
	local function txView(tx: any): any
		local gameTable: any = nil
		local view = setmetatable({}, {
			__index = function(_, field: any): any
				if field == "schemaVersion" then
					return 1
				elseif field == "game" then
					if gameTable == nil then
						gameTable = { [gameId] = if gameKey then data.section(tx, gameKey) else nil }
					end
					return gameTable
				end
				local key = V12Data.MAP[field]
				if key == nil then
					return nil
				end
				local section = data.section(tx, key)
				if type(section) ~= "table" then
					local make = DEFAULTS[field]
					return if make then make() else nil
				end
				local value = section[field]
				if value == nil and DEFAULTS[field] then
					value = DEFAULTS[field]()
					section[field] = value
				end
				return value
			end,
			__newindex = function(_, field: any, value: any)
				local key = V12Data.MAP[field]
				local section = if key then data.section(tx, key) else nil
				if type(section) ~= "table" then
					warnOnce(
						"tx:" .. tostring(field),
						`[Compat.Data] dropped a write to '{tostring(field)}' (its module is not enabled)`
					)
					return
				end
				section[field] = value
			end,
		})
		viewTx[view] = tx
		return view
	end
	D.txView = txView

	-- The framework tx under a flat view made by txView (nil for a live view or anything else).
	function D.txOf(view: any): any
		return viewTx[view]
	end

	function D.get(player: any): any
		if not data.isLoaded(player) then
			return nil
		end
		return liveView(player)
	end

	function D.isLoaded(player: any): boolean
		return data.isLoaded(player)
	end

	-- v1.2 Data.update: false (fn not run) when not loaded; errors propagate (nothing committed).
	function D.update(player: any, fn: (any) -> ()): boolean
		if not data.isLoaded(player) then
			return false
		end
		local committed = data.runTx(player, function(tx: any)
			fn(txView(tx))
		end)
		return committed == true
	end

	-- Runs fn(tx, flat) inside one framework tx (the v1.2 Tx.run shape for the bridge's ops).
	function D.runTx(player: any, fn: (any, any) -> any): (boolean, any)
		return data.runTx(player, function(tx: any)
			return fn(tx, txView(tx))
		end)
	end

	function D.getGame(player: any): any
		local root = data.compatLive(player)
		return if root and gameKey then root[gameKey] else nil
	end

	function D.updateGame(player: any, fn: (any) -> ()): boolean
		return D.update(player, function(d: any)
			fn(d.game[gameId])
		end)
	end

	function D.saveAsync(player: any): boolean
		return data.saveAsync(player)
	end

	function D.sectionVersion(player: any, field: string): number
		if field == "game" then
			return if gameKey then data.sectionVersion(player, gameKey) else 0
		end
		local key = V12Data.MAP[field]
		return if key then data.sectionVersion(player, key) else 0
	end

	-- v1.2 semantics: every handler runs in its own thread after a load (and at once for players
	-- already loaded); returns a Connection.
	function D.onLoaded(handler: (any, any) -> ()): any
		table.insert(loadedHandlers, handler)
		for _, player in data.players() do
			spawn(handler, player, liveView(player))
		end
		local connection: any = { Connected = true }
		function connection.Disconnect(self: any)
			self.Connected = false
			local i = table.find(loadedHandlers, handler)
			if i then
				table.remove(loadedHandlers, i)
			end
		end
		return connection
	end

	-- Called by the bridge from the framework's onPlayerLoaded (must not yield: spawns).
	function D.fireLoaded(player: any)
		local view = liveView(player)
		if signals and signals.DataLoaded then
			signals.DataLoaded:Fire(player, view)
		end
		for _, handler in table.clone(loadedHandlers) do
			spawn(handler, player, view)
		end
	end

	return D
end

return V12Data
