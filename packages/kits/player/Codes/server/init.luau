--!strict
-- Free promotion grants are data-only transactions; durable slots fail closed on uncertainty.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Rules = require(Modules:WaitForChild("Codes"):WaitForChild("shared"):WaitForChild("Rules"))
local Economy = require(Modules:WaitForChild("Economy"):WaitForChild("module"))
local Inventory = require(Modules:WaitForChild("Inventory"):WaitForChild("module"))
local Rarity = require(Modules:WaitForChild("Rarity"):WaitForChild("module"))
local Rebirth = require(Modules:WaitForChild("Rebirth"):WaitForChild("module"))
local Ledger = require(script.Ledger)
local Catalog = require(script.Catalog)
local Codes = {}
local runtimeNumber = 0
local MINUTE = 60
local RECOVERY_SHARE = 0.25

function Codes.new(): any
	runtimeNumber += 1
	local instanceNumber = runtimeNumber
	local ctx: any = nil
	local cfg: any = nil
	local part: any = {}
	local signals: any = {}
	local publicSignals = setmetatable({}, {
		__index = function(_, key: any): any
			return signals[key]
		end,
		__newindex = function()
			error("Codes.signals is read-only", 2)
		end,
	})
	local base: any = {}
	local liveDefinitions: any = {}
	local liveDisabled: any = {}
	local localDisabled: any = {}
	local catalog: any = {}
	local lookup: any = {}
	local retained: any = {}
	local generation = 0
	local catalogReady = false
	local players: { [any]: any } = {}
	local rewardHandlers: any = {}
	local requirementHandlers: any = {}
	local budget = { minute = -1, total = 0, fresh = 0 }
	local stopped = false
	local snapshot: any = nil
	local connection: any = nil
	local inflight = false
	local refreshWanted = false
	local lastRead = -math.huge
	local nextRead = -math.huge
	local failures = 0
	local warnedLive = false
	local releases: { [string]: any } = {}
	local nonce = ""

	local function on(): boolean
		if stopped then
			return false
		end
		if cfg.flag == nil then
			return true
		end
		local ok, enabled = pcall(ctx.flags.isOn, cfg.flag)
		return ok and enabled == true
	end
	local function environment(): string
		local ok, name = pcall(ctx.env.name)
		return if ok and (name == "studio" or name == "test") then name else "live"
	end
	local function take(recovery: boolean): boolean
		local minute = math.floor(ctx.now() / MINUTE)
		if budget.minute ~= minute then
			budget.minute, budget.total, budget.fresh = minute, 0, 0
		end
		if budget.total >= cfg.sharedOpsPerMinute then
			return false
		end
		if
			not recovery
			and (
				budget.total >= cfg.sharedOpsPerMinute - 1
				or budget.fresh >= math.floor(cfg.sharedOpsPerMinute * (1 - RECOVERY_SHARE))
			)
		then
			return false
		end
		budget.total += 1
		if not recovery then
			budget.fresh += 1
		end
		return true
	end
	local function shared(id: string, recovery: boolean, transform: (any) -> any): (boolean, any)
		if not take(recovery) then
			return false, nil
		end
		local called, ok, result = pcall(ctx.data.shared.update, "cap/" .. id, transform)
		return called and ok == true, result
	end
	local function release(id: string, token: string)
		local key = id .. "/" .. token
		local ok = shared(id, true, function(old: any): any
			return Ledger.finish(old, token, false)
		end)
		if ok then
			releases[key] = nil
		else
			releases[key] = { id = id, token = token }
		end
	end
	local function drainReleases(): boolean
		for _, item in table.clone(releases) do
			release(item.id, item.token)
		end
		return next(releases) == nil
	end

	local function clearPending(player: any, id: string, token: string): boolean
		local called, ok = pcall(ctx.data.update, player, function(section: any)
			local receipt = section.pending[id]
			if receipt ~= nil and receipt.token == token then
				section.pending[id] = nil
			end
		end)
		return called and ok == true
	end
	-- The caller holds the same gate used by redeem. Eligibility never blocks existing receipts.
	local function recover(player: any): boolean
		if not ctx.data.isLoaded(player) then
			return false
		end
		local pending = ctx.data.get(player).pending
		if next(pending) == nil then
			return true
		end
		local saved, confirmed = pcall(ctx.data.saveAsync, player)
		if not saved or confirmed ~= true or not ctx.data.isLoaded(player) then
			return false
		end
		for id, receipt in pending do
			if receipt.capped then
				local ok = shared(id, true, function(old: any): any
					return Ledger.finish(old, receipt.token, true)
				end)
				if not ok then
					return false
				end
			end
			if not clearPending(player, id, receipt.token) then
				return false
			end
		end
		return true
	end
	local function prune(player: any)
		if not catalogReady or not ctx.data.isLoaded(player) then
			return
		end
		local old = ctx.data.get(player)
		local dirty = false
		for id in old.redeemed do
			if not retained[id] and old.pending[id] == nil then
				dirty = true
				break
			end
		end
		if dirty then
			ctx.data.update(player, function(section: any)
				for id in section.redeemed do
					if not retained[id] and section.pending[id] == nil then
						section.redeemed[id] = nil
					end
				end
			end)
		end
	end
	local function publishSources(player: any)
		local ids, seen = {}, {}
		for id, def in catalog do
			if localDisabled[id] or liveDisabled[id] then
				continue
			end
			for _, reward in def.rewards do
				if reward.kind == "roll" and not seen[reward.tableId] then
					seen[reward.tableId] = true
					table.insert(ids, reward.tableId)
				end
			end
		end
		table.sort(ids)
		ctx.replicate.set(player, "rollSources", ids)
		for _, sourceId in ids do
			ctx.compliance.disclose(player, sourceId)
		end
	end
	local function rebuild(): boolean
		local disabled = table.clone(liveDisabled)
		for id in localDisabled do
			disabled[id] = true
		end
		local ok, ids, codes, keep = pcall(Catalog.merge, base, liveDefinitions, disabled, cfg)
		if not ok then
			return false
		end
		catalog, lookup, retained = ids, codes, keep
		generation += 1
		for player in players do
			if ctx.data.isLoaded(player) then
				publishSources(player)
			end
		end
		return true
	end
	local function warnLive()
		if not warnedLive then
			ctx.log.warn("invalid live promotion entry ignored")
			warnedLive = true
		end
	end
	local function applySnapshot(): boolean
		local ok, raw = pcall(function(): any
			return snapshot:GetValue(cfg.live.key)
		end)
		if not ok then
			return false
		end
		local valid, incoming, disabled = Catalog.live(raw, cfg, warnLive)
		if not valid then
			warnLive()
			return false
		end
		-- Skip individual duplicate/over-limit entries while preserving valid entries.
		local accepted = {}
		for _, def in incoming do
			local candidate = table.clone(accepted)
			table.insert(candidate, def)
			if pcall(Catalog.merge, base, candidate, disabled, cfg) then
				accepted = candidate
			else
				warnLive()
			end
		end
		local oldDefinitions, oldDisabled = liveDefinitions, liveDisabled
		liveDefinitions, liveDisabled = accepted, disabled
		if not rebuild() then
			liveDefinitions, liveDisabled = oldDefinitions, oldDisabled
			return false
		end
		catalogReady = true
		for player, state in players do
			if not state.busy then
				prune(player)
			end
		end
		return true
	end
	local function refresh()
		if stopped or inflight or ctx.now() < nextRead then
			return
		end
		if snapshot ~= nil and ctx.now() - lastRead < cfg.live.refreshSeconds then
			return
		end
		inflight = true
		lastRead = ctx.now()
		local ok = pcall(function()
			if snapshot == nil then
				snapshot = ctx.configValues.snapshot()
				if stopped then
					return
				end
				assert(snapshot ~= nil, "missing configuration snapshot")
				connection = snapshot.UpdateAvailable:Connect(function()
					if not stopped then
						refreshWanted = true
					end
				end)
			else
				snapshot:Refresh()
			end
		end)
		if ok and not stopped and applySnapshot() then
			failures = 0
			nextRead = ctx.now() + cfg.live.refreshSeconds
			refreshWanted = false
		else
			failures = math.min(failures + 1, 3)
			nextRead = ctx.now() + cfg.live.refreshSeconds * 2 ^ (failures - 1)
			ctx.log.warn("live promotion refresh failed; keeping last valid catalog")
		end
		inflight = false
	end
	local function availability(def: any, captured: number): string?
		if not on() then
			return "try_later"
		end
		if
			generation ~= captured
			or catalog[def.id] ~= def
			or localDisabled[def.id]
			or liveDisabled[def.id]
		then
			return "try_later"
		end
		if def.testOnly and environment() == "live" then
			return "invalid"
		end
		local now = ctx.now()
		if def.startsAt ~= nil and now < def.startsAt then
			return "not_yet"
		end
		if def.expiresAt ~= nil and now >= def.expiresAt then
			return "expired"
		end
		return nil
	end
	local function eligible(player: any, def: any, tx: any?): boolean
		for _, requirement in def.requires or {} do
			local kind = requirement.kind
			if kind == "item" then
				if not ctx.isEnabled(Inventory) then
					return false
				end
				local list = if tx ~= nil
					then ctx.depsTx[Inventory].list(tx)
					else ctx.deps[Inventory].list(player)
				local found = false
				for _, item in list do
					if item.itemId == requirement.itemId then
						found = true
						break
					end
				end
				if not found then
					return false
				end
			elseif kind == "rebirth" then
				if not ctx.isEnabled(Rebirth) or ctx.deps[Rebirth].count(player) < requirement.count then
					return false
				end
			elseif kind == "newPlayer" then
				if ctx.now() - ctx.framework.firstJoin(player) > requirement.maxAgeSeconds then
					return false
				end
			elseif tx == nil then
				if kind == "group" then
					local ok, member = pcall(function(): boolean
						return player:IsInGroupAsync(requirement.groupId)
					end)
					if not ok or member ~= true then
						return false
					end
				else
					local handler = requirementHandlers[kind]
					if handler == nil or handler(player, requirement) ~= true then
						return false
					end
				end
			end
		end
		return true
	end
	local function grant(tx: any, player: any, rewards: any)
		for _, reward in rewards do
			local kind = reward.kind
			if kind == "currency" then
				assert(ctx.isEnabled(Economy), "missing reward dependency")
				local currency = reward.currency or ctx.deps[Economy].primaryCurrency()
				assert(not ctx.compliance.isPaidCurrency(currency), "paid promotion reward refused")
				assert(ctx.depsTx[Economy].grant(tx, reward.amount, "promotion", currency), "reward refused")
			elseif kind == "item" then
				assert(ctx.isEnabled(Inventory), "missing reward dependency")
				for _ = 1, reward.count or 1 do
					assert(
						ctx.depsTx[Inventory].add(tx, reward.itemId, { source = "promotion" }),
						"reward refused"
					)
				end
			elseif kind == "roll" then
				assert(ctx.isEnabled(Rarity) and ctx.isEnabled(Inventory), "missing reward dependency")
				local detail = ctx.deps[Rarity].getOddsDetail(reward.tableId, player)
				assert(detail ~= nil and detail.paid ~= true, "paid or unknown promotion roll refused")
				assert(
					ctx.compliance.disclosed(player, reward.tableId) ~= nil,
					"promotion odds not disclosed"
				)
				local item, info =
					ctx.depsTx[Rarity].roll(tx, reward.tableId, nil, { grant = true, reason = "promotion" })
				assert(item ~= nil and info.ok == true, "reward refused")
			else
				local handler = rewardHandlers[kind]
				assert(handler ~= nil and handler(tx, player, reward) == true, "reward refused")
			end
		end
	end
	local function outcome(player: any, state: any, result: string, normalized: string?): string
		if result ~= "ok" and result ~= "try_later" then
			local now = ctx.now()
			if now - state.failureAt >= cfg.failureWindowSeconds then
				state.failureAt, state.failures = now, 0
			end
			state.failures += 1
			if state.failures >= cfg.failureLimit then
				state.lockedUntil = now + cfg.lockoutSeconds
			end
		end
		ctx.analytics.custom(
			player,
			"CodeAttempt",
			1,
			{ codeHash = Rules.hash(normalized or ""), result = result }
		)
		return result
	end
	local function redeemInner(player: any, raw: any, state: any): string
		if not recover(player) or not drainReleases() then
			return "try_later"
		end
		local normalized = Rules.normalize(raw, cfg.maxLength)
		if normalized == nil then
			return outcome(player, state, "invalid", nil)
		end
		local def = lookup[normalized]
		if not def then
			return outcome(player, state, "invalid", normalized)
		end
		local captured = generation
		local unavailable = availability(def, captured)
		if unavailable then
			return outcome(player, state, unavailable, normalized)
		end
		local data = ctx.data.get(player)
		if data.redeemed[def.id] then
			return outcome(player, state, "already_used", normalized)
		end
		if not eligible(player, def, nil) then
			return outcome(player, state, "not_eligible", normalized)
		end
		unavailable = availability(def, captured)
		if unavailable or not ctx.data.isLoaded(player) then
			return outcome(player, state, unavailable or "try_later", normalized)
		end
		if data.sequence >= Rules.SAFE_INTEGER then
			return "try_later"
		end
		local token = tostring(player.UserId) .. ":" .. tostring(data.sequence + 1) .. ":" .. nonce
		local capped = def.maxUses ~= nil
		local limit = def.maxUses or 0
		local reserved, record = shared(def.id, false, function(old: any): any
			return Ledger.reserve(old, limit, token)
		end)
		if not reserved or not Ledger.valid(record) or record.limit ~= limit then
			return "try_later"
		end
		if capped and record.reserved[token] ~= true then
			return outcome(player, state, "limit_reached", normalized)
		end
		local committed = false
		local refusal = "try_later"
		local called, ran = pcall(ctx.tx, player, function(tx: any)
			local s = ctx.section(tx)
			local why = availability(def, captured)
			if why ~= nil then
				refusal = why
				error("promotion no longer available", 0)
			end
			if s.redeemed[def.id] then
				refusal = "already_used"
				error("promotion already used", 0)
			end
			if not eligible(player, def, tx) then
				refusal = "not_eligible"
				error("promotion not eligible", 0)
			end
			grant(tx, player, def.rewards)
			s.redeemed[def.id] = true
			s.sequence += 1
			s.pending[def.id] = { token = token, capped = capped }
		end)
		committed = called and ran == true
		if not committed then
			if capped then
				release(def.id, token)
			end
			return outcome(player, state, refusal, normalized)
		end
		if not recover(player) then
			return "try_later"
		end
		signals.Redeemed:Fire(player, def.id)
		return outcome(player, state, "ok", normalized)
	end
	local function redeem(player: any, raw: any): string
		local state = players[player]
		if state == nil or state.busy or not ctx.data.isLoaded(player) then
			return "try_later"
		end
		local now = ctx.now()
		if now < state.lockedUntil then
			return "try_later"
		end
		state.tokens =
			math.min(cfg.rate.burst, state.tokens + math.max(0, now - state.rateAt) * cfg.rate.rate)
		state.rateAt = now
		if state.tokens < 1 then
			return "try_later"
		end
		state.tokens -= 1
		state.busy = true
		local ok, result = pcall(redeemInner, player, raw, state)
		state.busy = false
		pcall(prune, player)
		return if ok then result else "try_later"
	end
	local function define(def: any): (boolean, string?)
		local valid, reason = Rules.validateDefinition(def, cfg)
		if not valid then
			return false, reason
		end
		local previous = base[def.id]
		if previous ~= nil and previous.maxUses ~= def.maxUses then
			return false, "limit_policy"
		end
		base[def.id] = Catalog.copy(def)
		if not rebuild() then
			base[def.id] = previous
			return false, "duplicate_or_limit"
		end
		return true, nil
	end
	local function disable(id: string): boolean
		if not Rules.id(id) or catalog[id] == nil then
			return false
		end
		localDisabled[id] = true
		rebuild()
		return true
	end
	local function uses(id: string): (number?, string?)
		if not Rules.id(id) or catalog[id] == nil then
			return nil, "unknown"
		end
		if catalog[id].maxUses == nil then
			return nil, "uncapped"
		end
		local ok, record = shared(id, false, function(old: any): any
			return Ledger.reserve(old, catalog[id].maxUses, "")
		end)
		if not ok or not Ledger.valid(record) then
			return nil, "try_later"
		end
		return Ledger.count(record), nil
	end
	local builtin =
		{ currency = true, item = true, roll = true, rebirth = true, group = true, newPlayer = true }
	local function registerReward(kind: string, handler: any)
		assert(
			type(kind) == "string"
				and #kind > 0
				and #kind <= 32
				and not builtin[kind]
				and type(handler) == "function"
				and rewardHandlers[kind] == nil,
			"invalid promotion reward registration"
		)
		rewardHandlers[kind] = handler
	end
	local function registerRequirement(kind: string, handler: any)
		assert(
			type(kind) == "string"
				and #kind > 0
				and #kind <= 32
				and not builtin[kind]
				and type(handler) == "function"
				and requirementHandlers[kind] == nil,
			"invalid promotion requirement registration"
		)
		requirementHandlers[kind] = handler
	end
	function part.init(context: any)
		ctx, cfg = context, context.config
		nonce = tostring(instanceNumber)
		pcall(function()
			nonce = tostring(game.JobId) .. ":" .. tostring(instanceNumber)
		end)
		signals.Redeemed = ctx.signals.new("Redeemed")
		rewardHandlers.preview = function(): boolean
			return true
		end
		if cfg.flag ~= nil then
			ctx.flags.isOn(cfg.flag)
		end
		local definitions = {}
		for _, def in cfg.definitions do
			table.insert(definitions, def)
		end
		if ctx.serverConfig ~= nil and ctx.serverConfig.definitions ~= nil then
			assert(
				Rules.validateCatalog(ctx.serverConfig.definitions, cfg),
				"invalid server promotion catalog"
			)
			for _, def in ctx.serverConfig.definitions do
				table.insert(definitions, def)
			end
		end
		assert(Rules.validateCatalog(definitions, cfg), "invalid merged promotion catalog")
		for _, def in definitions do
			base[def.id] = Catalog.copy(def)
		end
		catalogReady = not cfg.live.enabled
		assert(rebuild(), "invalid promotion catalog")
		part.actions.redeem.limit = cfg.rate
		ctx.console.register("list", function(): string
			local ids = {}
			for id in catalog do
				table.insert(ids, id)
			end
			table.sort(ids)
			return table.concat(ids, ", ")
		end, "codes list: list promotion identifiers")
		ctx.console.register("inspect", function(_caller: any, id: any): string
			if not Rules.id(id) or catalog[id] == nil then
				return "unknown promotion"
			end
			local n, reason = uses(id)
			return if n ~= nil then `reserved and completed: {n}` else reason or "unavailable"
		end, "codes inspect <id>: inspect a promotion use count")
		ctx.console.register("add", function(_caller: any, id: any, code: any): string
			if environment() == "live" then
				return "test promotion refused in live"
			end
			local def = { id = id, code = code, rewards = { { kind = "preview" } }, testOnly = true }
			local ok = define(def)
			return if ok then "test promotion added" else "invalid test promotion"
		end, "codes add <id> <code>: add a test-only promotion")
	end
	function part.start()
		ctx.data.onLoaded(function(player: any)
			local state = {
				busy = true,
				tokens = cfg.rate.burst,
				rateAt = ctx.now(),
				failureAt = ctx.now(),
				failures = 0,
				lockedUntil = 0,
			}
			players[player] = state
			publishSources(player)
			task.spawn(function()
				local ok = pcall(recover, player)
				if ok and players[player] == state then
					prune(player)
				end
				state.busy = false
			end)
		end)
		ctx.lifecycle.onPlayerRemoving(function(player: any)
			players[player] = nil
		end)
		ctx.lifecycle.onShutdown(function()
			stopped = true
			if connection then
				connection:Disconnect()
			end
		end)
		if cfg.flag ~= nil then
			ctx.flags.onChanged(cfg.flag, function()
				for player in players do
					publishSources(player)
				end
			end)
		end
		if cfg.live.enabled then
			ctx.lifecycle.onTick(cfg.live.refreshSeconds, function()
				if inflight or stopped then
					return
				end
				local outdated = snapshot == nil
				if snapshot ~= nil then
					pcall(function()
						outdated = snapshot.Outdated == true
					end)
				end
				if outdated or refreshWanted then
					task.spawn(refresh)
				end
			end)
			task.spawn(refresh)
		end
	end
	part.api = {
		redeem = redeem,
		define = define,
		disable = disable,
		uses = uses,
		registerReward = registerReward,
		registerRequirement = registerRequirement,
		signals = publicSignals,
	}
	part.extensions = { registerReward = registerReward, registerRequirement = registerRequirement }
	part.actions = {
		redeem = {
			limit = Rules.DEFAULTS.rate,
			handler = function(player: any, raw: any): string
				local result = redeem(player, raw)
				if part.net ~= nil and part.net.RedeemResult ~= nil then
					ctx.net.fire(player, part.net.RedeemResult, result)
				end
				return result
			end,
		},
	}
	return part
end
return Codes
