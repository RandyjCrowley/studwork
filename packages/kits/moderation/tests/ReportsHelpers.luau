--!nocheck
--[[
	Shared helpers for the Reports specs: a booted harness, small fake server parts for Admin and
	Moderation (injected through the harness `servers` option, so the stubs' behaviour doesn't
	matter), and a deep search for a value in replicated state or sent events.
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
H.Reports = kit("Reports")
H.TextFilter = kit("TextFilter")

-- user ids chosen so they can't collide with clock values or counts in a deep search
H.TARGET = 90001
H.STAFF = 80001
H.reporter = function(i)
	return 70000 + i
end

function H.boot(opts)
	opts = opts or {}
	local config = opts.config or {}
	if config.TextFilter == nil then
		config.TextFilter = { maxLength = 200, respectContentSharing = false }
	end
	return StudWork.test.harness({
		modules = opts.modules or { H.Reports },
		config = config,
		serverConfig = opts.serverConfig,
		servers = opts.servers,
		isStudio = opts.isStudio or false,
		flags = opts.flags,
		store = opts.store,
		policy = opts.policy,
		services = {
			Players = Fakes.players(),
			GroupService = Fakes.groupService(),
			TextChatService = Fakes.textChatService(),
			TextService = StudWork.test.fakes.textService({ replace = { badword = "#######" } }),
		},
	})
end

-- roles = { [userId] = { rank = number, permissions = { string } } }
function H.fakeAdmin(roles)
	local part = { tabs = {}, allowCalls = {} }
	local function role(p)
		return if p ~= nil then roles[p.UserId] else nil
	end
	local function can(p, permission)
		local r = role(p)
		return r ~= nil and table.find(r.permissions, permission) ~= nil
	end
	local noop = function() end
	part.api = {
		can = can,
		allow = function(p, permission)
			table.insert(part.allowCalls, { p.UserId, permission })
			if can(p, permission) then
				return true, nil
			end
			return false, "no_permission"
		end,
		roleOf = function(p)
			return if role(p) then "staff" else nil
		end,
		isStaff = function(p)
			return role(p) ~= nil
		end,
		permissions = function(p)
			local r = role(p)
			return if r then table.clone(r.permissions) else {}
		end,
		rankOf = function(p)
			local r = role(p)
			return if r then r.rank else 0
		end,
		rankOfUserId = function(userId)
			local r = roles[userId]
			return true, if r then r.rank else 0
		end,
		onlineStaff = function()
			return {}
		end,
		signals = {},
	}
	part.extensions = {
		registerPermission = noop,
		registerAction = noop,
		registerTab = function(def)
			part.tabs[def.id] = def
		end,
		registerDataView = noop,
		onStaffMove = noop,
		registerAuditSink = noop,
	}
	part.init = noop
	part.start = noop
	return part
end

function H.fakeModeration()
	local part = { reports = {}, records = {} }
	local noop = function()
		return false, "disabled"
	end
	part.api = {
		ban = noop,
		unban = noop,
		history = noop,
		kick = noop,
		serverBan = noop,
		mute = noop,
		unmute = noop,
		isMuted = function()
			return false
		end,
		warn = noop,
		punish = noop,
		audit = noop,
		report = function(target, source, severity, details)
			table.insert(
				part.reports,
				{ target = target, source = source, severity = severity, details = details }
			)
			return true
		end,
		record = function(entry, opts)
			table.insert(part.records, { entry = entry, by = opts.by })
			return true
		end,
		signals = {},
	}
	part.init = function() end
	part.start = function() end
	return part
end

-- every number equal to n, or string containing it, anywhere inside value (tables walked, keys too)
function H.contains(value, n, seen)
	seen = seen or {}
	local text = tostring(n)
	if type(value) == "number" then
		return value == n
	elseif type(value) == "string" then
		return string.find(value, text, 1, true) ~= nil
	elseif type(value) == "table" then
		if seen[value] then
			return false
		end
		seen[value] = true
		for k, v in value do
			if H.contains(k, n, seen) or H.contains(v, n, seen) then
				return true
			end
		end
	end
	return false
end

-- (k) Feedback events sent to one player
function H.feedback(h, p)
	local out = {}
	for _, ev in h.fake.serverEvents do
		if ev.event == "Feedback" and ev.player == p then
			table.insert(out, ev.args[1].Text)
		end
	end
	return out
end

-- every server -> client message that reached player p (framework events, module events, broadcasts)
function H.reached(h, p)
	local out = {}
	for _, ev in h.fake.serverEvents do
		if ev.player == p or ev.all then
			table.insert(out, ev)
		end
	end
	for _, ev in h:sent() do
		if ev.player == p or ev.all then
			table.insert(out, ev)
		end
	end
	return out
end

function H.report(h, reporter, target, category, note)
	return h:action(reporter, H.Reports, "submit", target or H.TARGET, category or "cheating", note)
end

return H
