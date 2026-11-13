--!nocheck
--[[
	Helpers for Integration.spec (Lune; not synced by Rojo): the three moderation modules booted
	TOGETHER with their real server parts (no injected fakes), plus TextFilter (fake TextService)
	and Economy, and the kit's engine fakes (./Fakes.luau).

	  I.boot(opts) -> env
	    opts = { users? ({ [userId] = role }), groups? (ServerConfig.Admin.groups), config?
	             ({ [Module] = config }, merged over the defaults below), isStudio?, modules? }
	    env = { h, admin, mod, reports, economy (APIs), players, groups, tcs,
	            add(userId) -> player, run(p, ...) -> RunResult {ok, key} | nil,
	            fetch(p, tabId, page) -> rows | nil, audit(q?) -> { AuditEntry } (flushed first),
	            results(p) -> { {ok, key} } }
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local HttpService = game:GetService("HttpService")
local Fakes = require("packages/kits/moderation/tests/Fakes.luau")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local function kit(name)
	return require(Modules:WaitForChild(name):WaitForChild("module"))
end

local I = {}

I.Admin = kit("Admin")
I.Moderation = kit("Moderation")
I.Reports = kit("Reports")
I.TextFilter = kit("TextFilter")
I.Economy = kit("Economy")
I.Fakes = Fakes

local OK = { IsContentSharingAllowed = true }

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

function I.boot(opts)
	opts = opts or {}
	local services = {
		Players = Fakes.players(),
		GroupService = opts.groupService or Fakes.groupService(),
		TextChatService = Fakes.textChatService(),
		TextService = StudWork.test.fakes.textService({ replace = { badword = true } }),
	}
	local config = merge({
		Economy = { primaryCurrency = "Coins", startingCurrency = { Coins = 0 } },
		TextFilter = { maxLength = 200, respectContentSharing = false },
		Moderation = { kick = { allowFreeText = true } },
	}, opts.config or {})
	local policy = {}
	for id = 1, 100 do
		policy[id] = OK
	end
	local h = StudWork.test.harness({
		modules = opts.modules or { I.Economy, I.TextFilter, I.Admin, I.Moderation, I.Reports },
		config = config,
		serverConfig = {
			Admin = { users = opts.users or {}, groups = opts.groups },
		},
		services = services,
		servers = opts.servers,
		isStudio = opts.isStudio or false,
		policy = policy,
	})
	local env = {
		h = h,
		admin = h:use(I.Admin),
		mod = h:use(I.Moderation),
		reports = h:use(I.Reports),
		economy = h:use(I.Economy),
		players = services.Players,
		groups = services.GroupService,
		tcs = services.TextChatService,
	}
	function env.add(userId)
		local p = h:addPlayer({ userId = userId })
		local all = {}
		for _, q in h.players do
			table.insert(all, q)
		end
		services.Players.setOnline(all)
		return p
	end
	function env.results(p)
		local out = {}
		for _, e in h:sent("Admin", "RunResult") do
			if e.player == p then
				table.insert(out, { ok = e.args[1], key = e.args[2] })
			end
		end
		return out
	end
	-- Admin's Run as player p; the RunResult it answered (nil = no reply at all)
	function env.run(p, actionId, target, preset, duration, text)
		local before = #env.results(p)
		local ran = h:action(p, I.Admin, "run", actionId, target, preset, duration, text)
		assert(ran == true, "the framework refused the request")
		h:tick(1.1) -- stay inside the framework's per-action rate limit
		local list = env.results(p)
		return if #list > before then list[#list] else nil
	end
	-- Admin's Fetch as player p; the decoded rows (nil = no Rows reply)
	function env.fetch(p, tabId, page)
		local before = #h:sent("Admin", "Rows")
		local ran = h:action(p, I.Admin, "fetch", tabId, page or 1)
		assert(ran == true, "the framework refused the request")
		h:tick(1.1)
		local sent = h:sent("Admin", "Rows")
		for i = #sent, before + 1, -1 do
			local e = sent[i]
			if e.player == p and e.args[1] == tabId then
				return HttpService:JSONDecode(e.args[3])
			end
		end
		return nil
	end
	-- every audit entry (flushes the buffer first: the audit flushes every flushSeconds)
	local reads = 0
	function env.audit(q)
		h:tick(16)
		reads += 1
		q = q or {}
		local ok, list = env.mod.audit({ by = "server", target = q.target, limit = 200 - reads % 50 })
		assert(ok, list)
		return list
	end
	return env
end

function I.find(list, pred)
	local out = {}
	for _, e in list do
		if pred(e) then
			table.insert(out, e)
		end
	end
	return out
end

-- every number equal to n, or string containing it, anywhere inside value (keys too)
function I.contains(value, n, seen)
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
			if I.contains(k, n, seen) or I.contains(v, n, seen) then
				return true
			end
		end
	end
	return false
end

return I
