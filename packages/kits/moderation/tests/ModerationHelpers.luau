--!nocheck
--[[
	Helpers for the Moderation specs (Lune only). Boots Moderation in the harness with the kit's
	engine fakes (./Fakes.luau), a fake Blink net (Notice is recorded), and an optional injected
	fake Admin server part.

	  H.boot(opts) -> env
	    opts = { config? (config.Moderation), extraConfig? ({ [Module] = config }), serverConfig?
	             (ServerConfig.Moderation), modules? (default { Moderation }), admin? (H.fakeAdmin(...)),
	             isStudio?, store?, startTime?, flags?, jobId?, players?, tcs?, textService?, policy? }
	    env = { h, m (the Moderation API), part (the server part), players, tcs, notices, text,
	            add(userId) -> player, shared() -> { [fullKey]: value }, breakShared(on), audit(q?) }
	  H.fakeAdmin({ ranks, perms, failRank?, limits? }) -> fake Admin server part (fake.registered)
	  H.raises(fn, needle) -> boolean
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Fakes = require("packages/kits/moderation/tests/Fakes.luau")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local function kit(name)
	return require(Modules:WaitForChild(name):WaitForChild("module"))
end

local H = {}

H.Admin = kit("Admin")
H.Moderation = kit("Moderation")
H.TextFilter = kit("TextFilter")
H.Server = require(game:GetService("ServerScriptService"):WaitForChild("Modules"):WaitForChild("Moderation"))

function H.raises(fn, needle)
	local ok, err = pcall(fn)
	return not ok and string.find(tostring(err), needle, 1, true) ~= nil
end

local function fakeNet(log)
	return {
		Notice = {
			Fire = function(player, key, argsJson)
				table.insert(log, { player = player, key = key, args = argsJson })
			end,
			FireAll = function() end,
		},
	}
end

function H.fakeAdmin(o)
	local ranks = o.ranks or {}
	local perms = o.perms or {}
	local limits = o.limits or {}
	local failRank = o.failRank or {}
	local reg = { actions = {}, tabs = {}, sink = nil, allowCalls = 0 }
	local part = { registered = reg }
	local function has(p, perm)
		local list = perms[p.UserId]
		return list ~= nil and (list["*"] or list[perm]) == true
	end
	part.api = {
		can = function(p, perm)
			return has(p, perm)
		end,
		allow = function(p, perm)
			reg.allowCalls += 1
			if has(p, perm) then
				return true, nil
			end
			return false, "no_permission"
		end,
		roleOf = function()
			return nil
		end,
		isStaff = function(p)
			return (ranks[p.UserId] or 0) > 0
		end,
		permissions = function()
			return {}
		end,
		rankOf = function(p)
			return ranks[p.UserId] or 0
		end,
		rankOfUserId = function(userId)
			if failRank[userId] then
				return false, 0
			end
			return true, ranks[userId] or 0
		end,
		limitsOf = function(p)
			return limits[p.UserId] or {}
		end,
		onlineStaff = function()
			return {}
		end,
		signals = {},
	}
	part.extensions = {
		registerPermission = function() end,
		registerAction = function(def)
			reg.actions[def.id] = def
		end,
		registerTab = function(def)
			reg.tabs[def.id] = def
		end,
		registerDataView = function() end,
		onStaffMove = function() end,
		registerAuditSink = function(fn)
			reg.sink = fn
		end,
	}
	function part.init() end
	function part.start() end
	return part
end

function H.boot(o)
	o = o or {}
	local players = o.players or Fakes.players()
	local tcs = o.tcs or Fakes.textChatService()
	local text = StudWork.test.fakes.textService(o.textService or {})
	local notices = {}
	local part = H.Server.new({ jobId = o.jobId or "server-a", net = fakeNet(notices) })
	local modules = o.modules or { H.Moderation }
	local servers = { Moderation = part }
	if o.admin then
		servers.Admin = o.admin
		local has = false
		for _, ref in modules do
			has = has or ref == H.Admin
		end
		if not has then
			modules = table.clone(modules)
			table.insert(modules, 1, H.Admin)
		end
	end
	local config = table.clone(o.extraConfig or {})
	config.Moderation = o.config
	local serverConfig = if o.serverConfig then { Moderation = o.serverConfig } else nil
	local h = StudWork.test.harness({
		modules = modules,
		config = config,
		serverConfig = serverConfig,
		services = {
			Players = players,
			TextChatService = tcs,
			TextService = text,
			GroupService = Fakes.groupService(),
		},
		servers = servers,
		isStudio = o.isStudio,
		store = o.store,
		startTime = o.startTime,
		flags = o.flags,
		policy = o.policy,
	})
	local env = {
		h = h,
		m = h:use(H.Moderation),
		part = part,
		players = players,
		tcs = tcs,
		notices = notices,
		text = text,
	}
	local backend = h.runtime.shared.backend
	local realUpdate = backend.update
	function env.breakShared(on)
		if on then
			backend.update = function()
				error("DataStore request failed: 502 HTTP", 0)
			end
		else
			backend.update = realUpdate
		end
	end
	function env.shared()
		local out = {}
		for k, v in backend.values do
			if not (type(v) == "table" and v["$deleted"] == true) then
				out[k] = v
			end
		end
		return out
	end
	function env.add(userId)
		local p = h:addPlayer({ userId = userId })
		local all = {}
		for _, q in h.players do
			table.insert(all, q)
		end
		players.setOnline(all)
		return p
	end
	-- every audit entry of today (server read, cache bypassed by a fresh limit each time)
	local reads = 0
	function env.audit(q)
		reads += 1
		q = q or {}
		local ok, list =
			env.m.audit({ by = "server", target = q.target, day = q.day, limit = 200 - reads % 50 })
		assert(ok, list)
		return list
	end
	return env
end

function H.find(list, pred)
	local out = {}
	for _, e in list do
		if pred(e) then
			table.insert(out, e)
		end
	end
	return out
end

return H
