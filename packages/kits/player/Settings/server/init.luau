--!strict
-- Preferences are validated against a server-owned schema. Only the owner receives values,
-- schema metadata and acknowledgements; client-only preferences never enter the save.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Schema = require(
	ReplicatedStorage:WaitForChild("Modules")
		:WaitForChild("Settings")
		:WaitForChild("shared")
		:WaitForChild("Schema")
)

local Settings = {}

local function finite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function copyDefinition(def: any): any
	local copy = table.clone(def)
	copy.apply = nil
	if copy.choices ~= nil then
		copy.choices = table.freeze(table.clone(copy.choices))
	end
	return table.freeze(copy)
end

-- Optional scheduling injection is for deterministic offline tests. Live parts use task.delay.
function Settings.new(options: any?): any
	local delay = if options and options.delay then options.delay else task.delay
	local ctx: any = nil
	local cfg: any = nil
	local defs: { [string]: any } = {}
	local schema: { [string]: any } = {}
	local players: { [any]: any } = {}
	local created: { [string]: any } = {}
	local signals = setmetatable({}, {
		__index = function(_, key: any): any
			return created[key]
		end,
		__newindex = function()
			error("Settings.signals is read-only", 2)
		end,
	})
	local frozen = false
	local stopped = false
	local count = 0
	local part: any = {}

	local function enabled(): boolean
		return not stopped and (cfg.flag == nil or ctx.flags.isOn(cfg.flag))
	end

	local function register(def: any): boolean
		if frozen or stopped or count >= cfg.maxSettings then
			return false
		end
		if not Schema.validateDefinition(def) or defs[def.id] ~= nil then
			return false
		end
		local copy = copyDefinition(def)
		defs[copy.id] = copy
		if copy.scope == "saved" then
			schema[copy.id] = copy
		end
		count += 1
		return true
	end

	local function valuesFor(player: any): any
		local values = ctx.data.get(player).values
		local out: { [string]: any } = {}
		for id, def in schema do
			out[id] = if Schema.validate(def, values[id]) then values[id] else def.default
		end
		return out
	end

	local function publish(player: any, ps: any)
		if players[player] ~= ps or not ctx.data.isLoaded(player) then
			return
		end
		ctx.replicate.set(player, "values", valuesFor(player))
		ctx.replicate.set(player, "revision", ps.revision)
	end

	local schedule: (any, any) -> ()
	schedule = function(player: any, ps: any)
		if stopped or ps.scheduled or ps.saving or not ps.dirty then
			return
		end
		ps.scheduled = true
		-- The first dirty edit fixes this deadline; continuous edits cannot postpone it.
		delay(cfg.saveDebounceSeconds, function()
			if stopped or players[player] ~= ps or not ctx.data.isLoaded(player) then
				return
			end
			ps.scheduled = false
			ps.saving = true
			local version = ps.dirtyVersion
			local called, saved = pcall(ctx.data.saveAsync, player)
			ps.saving = false
			if stopped or players[player] ~= ps then
				return
			end
			if called and saved == true and ps.dirtyVersion == version then
				ps.dirty = false
			end
			schedule(player, ps)
		end)
	end

	local function dirty(player: any, ps: any)
		ps.dirty = true
		ps.dirtyVersion += 1
		schedule(player, ps)
	end

	local function allow(ps: any): boolean
		local now = ctx.now()
		ps.tokens = math.min(cfg.rate.burst, ps.tokens + math.max(0, now - ps.lastAt) * cfg.rate.rate)
		ps.lastAt = now
		if ps.tokens < 1 then
			return false
		end
		ps.tokens -= 1
		return true
	end

	local function get(player: any, id: any): any
		local def = if type(id) == "string" then schema[id] else nil
		if def == nil or players[player] == nil or not ctx.data.isLoaded(player) then
			return nil
		end
		local value = ctx.data.get(player).values[id]
		return if Schema.validate(def, value) then value else def.default
	end

	local function set(player: any, id: any, value: any): (boolean, string?)
		local ps = players[player]
		if ps == nil or not ctx.data.isLoaded(player) then
			return false, "not_loaded"
		end
		if not enabled() then
			return false, "disabled"
		end
		local def = if type(id) == "string" then schema[id] else nil
		if def == nil then
			return false, "unknown"
		end
		if not allow(ps) then
			return false, "rate_limited"
		end
		if not Schema.validate(def, value) then
			return false, "invalid"
		end
		if ps.revision >= Schema.MAX_REQUEST then
			return false, "revision_limit"
		end
		local called, changed = pcall(ctx.data.update, player, function(section: any)
			section.values[id] = value
		end)
		if not called or not changed then
			return false, "try_later"
		end
		ps.revision += 1
		publish(player, ps)
		dirty(player, ps)
		created.Changed:Fire(player, id, value)
		return true, nil
	end

	local function acknowledge(player: any, ps: any, id: string, requestId: number, accepted: boolean)
		if players[player] ~= ps or not ctx.data.isLoaded(player) then
			return
		end
		local kind, b, n, s = Schema.encode(get(player, id))
		ctx.net.fire(player, part.net.Ack, id, kind, b, n, s, requestId, accepted, ps.revision)
	end

	local function onSet(player: any, id: any, kind: any, b: any, n: any, s: any, requestId: any): boolean
		local ps = players[player]
		local def = if type(id) == "string" then schema[id] else nil
		if
			ps == nil
			or def == nil
			or not ctx.data.isLoaded(player)
			or not finite(requestId)
			or requestId % 1 ~= 0
			or requestId < 1
			or requestId > Schema.MAX_REQUEST
		then
			return false
		end
		local previous = ps.requests[id] or 0
		if requestId <= previous then
			acknowledge(player, ps, id, requestId, false)
			return false
		end
		ps.requests[id] = requestId
		local valid, value = Schema.decode(def, kind, b, n, s)
		local accepted = false
		if valid then
			accepted = set(player, id, value)
		else
			allow(ps) -- Invalid writes consume the same per-player application budget.
		end
		acknowledge(player, ps, id, requestId, accepted)
		return accepted
	end

	function part.init(context: any)
		ctx = context
		cfg = ctx.config
		assert(finite(cfg.rate.rate) and cfg.rate.rate >= 0, "Settings: invalid write rate")
		assert(finite(cfg.rate.burst) and cfg.rate.burst >= 1, "Settings: invalid write burst")
		assert(
			finite(cfg.saveDebounceSeconds) and cfg.saveDebounceSeconds > 0,
			"Settings: invalid save delay"
		)
		created.Changed = ctx.signals.new("Changed")
		if cfg.flag ~= nil then
			ctx.flags.isOn(cfg.flag) -- Fail boot for an undeclared kill switch.
		end
		for id, def in Schema.resolve(cfg) do
			local copy = copyDefinition(def)
			defs[id] = copy
			if copy.scope == "saved" then
				schema[id] = copy
			end
			count += 1
		end
	end

	function part.start(_context: any)
		ctx.data.onLoaded(function(player: any)
			frozen = true
			local old = ctx.data.get(player).values
			local values = valuesFor(player)
			local changed = false
			for id, value in old do
				if values[id] ~= value then
					changed = true
					break
				end
			end
			if not changed then
				for id, value in values do
					if old[id] ~= value then
						changed = true
						break
					end
				end
			end
			local ps = {
				revision = 0,
				requests = {},
				tokens = cfg.rate.burst,
				lastAt = ctx.now(),
				dirty = false,
				dirtyVersion = 0,
				scheduled = false,
				saving = false,
			}
			players[player] = ps
			if changed then
				local updated = ctx.data.update(player, function(section: any)
					section.values = values
				end)
				if updated then
					dirty(player, ps)
				end
			end
			ctx.replicate.set(player, "schema", table.clone(schema))
			publish(player, ps)
		end)
		ctx.lifecycle.onPlayerRemoving(function(player: any)
			-- Values already joined the transaction; the framework's final save persists them.
			players[player] = nil
		end)
		ctx.lifecycle.onShutdown(function()
			stopped = true
			for player, ps in players do
				if ps.dirty and ctx.data.isLoaded(player) then
					pcall(ctx.data.saveAsync, player)
				end
			end
			players = {}
		end)
	end

	part.actions = {
		set = { limit = Schema.DEFAULTS.rate, handler = onSet },
	}
	part.api = { get = get, set = set, register = register, signals = signals }
	part.extensions = { register = register }
	return part
end
return Settings
