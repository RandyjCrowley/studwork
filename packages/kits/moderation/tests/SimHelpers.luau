--!nocheck
--[[
	Helpers for ModerationSim.spec (Lune; not synced by Rojo): the moderation kit on several
	StudWork.test.sim servers sharing one World (saves, ctx.data.shared, ctx.data.messages, sorted
	maps), with the kit's engine fakes (./Fakes.luau). One Players fake is shared by every server
	(Roblox bans are universe-wide: a ban kicks the player wherever they are online); TextChatService
	is per server. Each server's Admin / Moderation / Reports parts are the REAL ones, built in the
	sim server's own module environment, with a recording fake net (no Blink wire in the sim).

	  S.world(opts) -> env
	    opts = { users? (ServerConfig.Admin.users), config? ({ [Module] = config }), modules? }
	    env = { w, players (shared Players fake), groups, sent (every recorded server -> client
	            event: { server, module, event, player?, all?, args }), servers }
	  env.server() -> server                  a new sim server (job-<n>)
	  env.join(server, userId) -> player      joins and waits until loaded (+ 1 s for roles)
	  env.call(server, fn, ...) -> ...        fn in a server thread, the world run until it returns
	  env.run(server, p, actionId, ...) -> { ok, key } | nil    Admin's Run as p (nil = no reply)
	  env.fetch(server, p, tabId, page) -> rows | nil           Admin's Fetch as p
	  env.audit(server, q?) -> { AuditEntry }  every entry (buffers flushed first)
	  env.sentTo(p, module?, event?) -> { entry }
	  env.tcs(server) -> that server's TextChatService fake
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local HttpService = game:GetService("HttpService")
local Fakes = require("packages/kits/moderation/tests/Fakes.luau")
local F = StudWork.test.sim

local S = {}

S.MODULES = { "Economy", "TextFilter", "Admin", "Moderation", "Reports" }
S.PARTS = { "Admin", "Moderation", "Reports" }
S.EVENTS = {
	Admin = { "Run", "Fetch", "PanelOpen", "Rows", "RunResult", "Spectate", "Announce" },
	Moderation = { "Notice" },
	Reports = { "Submit" },
}

local function merge(into, from)
	for k, v in from do
		if type(v) == "table" and type(into[k]) == "table" and #v == 0 and next(v) ~= nil then
			merge(into[k], v)
		else
			into[k] = v
		end
	end
	return into
end

-- one recording Blink-like event (On for the actions the framework binds, Fire / FireAll recorded)
local function fakeEvent(env, server, module, name)
	local ev = { name = name, listeners = {} }
	function ev.On(fn)
		table.insert(ev.listeners, fn)
	end
	function ev.Fire(player, ...)
		table.insert(env.sent, {
			server = server,
			module = module,
			event = name,
			player = player,
			args = table.pack(...),
		})
	end
	function ev.FireAll(...)
		table.insert(
			env.sent,
			{ server = server, module = module, event = name, all = true, args = table.pack(...) }
		)
	end
	return ev
end

function S.world(opts)
	opts = opts or {}
	local config = merge({
		Economy = { primaryCurrency = "Coins", startingCurrency = { Coins = 0 } },
		TextFilter = { maxLength = 200, respectContentSharing = false },
	}, opts.config or {})
	local w = F.world({ config = { modules = opts.modules or S.MODULES, config = config } })
	local env = { w = w, sent = {}, servers = {}, users = opts.users or {}, tcsBy = {} }
	-- universe-wide: who is online on any live server
	env.players = Fakes.players({
		online = function(userId)
			for _, s in env.servers do
				if s.alive then
					for _, p in s.players do
						if p.UserId == userId then
							return p
						end
					end
				end
			end
			return nil
		end,
	})
	env.groups = Fakes.groupService()

	function env.server()
		local parts = {}
		local tcs = Fakes.textChatService()
		local server
		-- this server's view of Players: bans go to the shared (universe) fake, lookups are local
		local localPlayers = setmetatable({}, { __index = env.players })
		function localPlayers.GetPlayers(_self)
			return if server then table.clone(server.players) else {}
		end
		function localPlayers.GetPlayerByUserId(_self, userId)
			for _, p in if server then server.players else {} do
				if p.UserId == userId then
					return p
				end
			end
			return nil
		end
		server = F.server(w, {
			services = {
				Players = localPlayers,
				GroupService = env.groups,
				TextChatService = tcs,
				TextService = StudWork.test.fakes.textService({ replace = { badword = true } }),
			},
			serverConfig = { Admin = { users = env.users } },
			serverParts = parts,
			beforeStart = function(s)
				local folder = s.game:GetService("ServerScriptService"):FindFirstChild("Modules")
				for _, name in S.PARTS do
					local instance = folder and folder:FindFirstChild(name)
					if instance ~= nil and table.find(opts.modules or S.MODULES, name) ~= nil then
						local factory = s.require(instance)
						local net = {}
						for _, e in S.EVENTS[name] do
							net[e] = fakeEvent(env, s, name, e)
						end
						local part = factory.new({ net = net })
						part.net = net
						parts[name] = part
					end
				end
			end,
		})
		env.tcsBy[server] = tcs
		table.insert(env.servers, server)
		return server
	end

	function env.tcs(server)
		return env.tcsBy[server]
	end

	function env.join(server, userId)
		local p = server:join(userId)
		assert(
			w:advanceUntil(function()
				return server:isLoaded(p)
			end, 60),
			`player {userId} loaded`
		)
		w:advance(1)
		return p
	end

	function env.call(server, fn, ...)
		local h = server:spawn(fn, ...)
		assert(
			w:advanceUntil(function()
				return h.done
			end, 120, 0.25),
			"server call returned"
		)
		if h.error ~= nil then
			error(h.error, 2)
		end
		return table.unpack(h.results, 1, h.results.n)
	end

	function env.sentTo(p, module, event)
		local out = {}
		for _, e in env.sent do
			if
				(e.player == p or e.all and e.server == p.server)
				and (module == nil or e.module == module)
				and (event == nil or e.event == event)
			then
				table.insert(out, e)
			end
		end
		return out
	end

	function env.run(server, p, actionId, target, preset, duration, text)
		local before = #env.sentTo(p, "Admin", "RunResult")
		local ran = server:action(p, "Admin", "run", actionId, target, preset, duration, text)
		assert(ran == true, "the framework refused the request")
		w:advance(1.1)
		local list = env.sentTo(p, "Admin", "RunResult")
		if #list > before then
			local e = list[#list]
			return { ok = e.args[1], key = e.args[2] }
		end
		return nil
	end

	function env.fetch(server, p, tabId, page)
		local before = #env.sentTo(p, "Admin", "Rows")
		local ran = server:action(p, "Admin", "fetch", tabId, page or 1)
		assert(ran == true, "the framework refused the request")
		w:advance(1.1)
		local list = env.sentTo(p, "Admin", "Rows")
		if #list > before then
			return HttpService:JSONDecode(list[#list].args[3])
		end
		return nil
	end

	local reads = 0
	function env.audit(server, q)
		w:advance(16, 0.5) -- every server flushes its buffer (audit.flushSeconds)
		reads += 1
		q = q or {}
		local api = server:use("Moderation")
		local ok, list = env.call(server, api.audit, {
			by = "server",
			target = q.target,
			limit = 200 - reads % 50,
		})
		assert(ok, list)
		return list
	end

	return env
end

function S.find(list, pred)
	local out = {}
	for _, e in list do
		if pred(e) then
			table.insert(out, e)
		end
	end
	return out
end

-- every number equal to n, or string containing it, anywhere inside value (keys too)
function S.contains(value, n, seen)
	seen = seen or {}
	if type(value) == "number" then
		return value == n
	elseif type(value) == "string" then
		return string.find(value, tostring(n), 1, true) ~= nil
	elseif type(value) == "table" then
		if seen[value] then
			return false
		end
		seen[value] = true
		for k, v in value do
			if S.contains(k, n, seen) or S.contains(v, n, seen) then
				return true
			end
		end
	end
	return false
end

-- a key named `name` anywhere inside value
function S.hasKey(value, name, seen)
	seen = seen or {}
	if type(value) ~= "table" or seen[value] then
		return false
	end
	seen[value] = true
	for k, v in value do
		if k == name or S.hasKey(v, name, seen) then
			return true
		end
	end
	return false
end

return S
