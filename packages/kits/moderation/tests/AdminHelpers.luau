--!nocheck
--[[
	Shared setup for the Admin specs (Lune; not synced by Rojo).

	  H.boot(opts) -> (h, services)   a harness with Admin (+ opts.modules), the engine fakes of
	      ./Fakes.luau, policy answers that allow text, and an optional "Probe" game module that
	      registers into Admin's extensions in its init (opts.register(ext, ctx)).
	      opts: admin (config.Admin), serverAdmin (ServerConfig.Admin), groups (a groupService
	      fake), modules, config, isStudio, flags, compliance, register, probeOptional
	  H.join(h, userId, { gui = true? }) -> p   a player joins; with gui, a fake PlayerGui first
	  H.sentTo(h, p, event?) -> { entry }        what Admin sent that player (h:sent filtered)
	  H.results(h, p) -> { { ok, key } }         the RunResult replies to that player
	  H.withPanel(fn)                            run fn with a panel seam that records into the
	                                             fake PlayerGui (restored afterwards)
	  H.run(h, p, actionId, target?, preset?, duration?, text?)  h:action(p, Admin, "run", ...)
	  H.users(map) -> ServerConfig.Admin with that users map
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
H.Economy = kit("Economy")
H.TextFilter = kit("TextFilter")
H.AdminServer = require(game:GetService("ServerScriptService"):WaitForChild("Modules"):WaitForChild("Admin"))
H.State = require(
	game:GetService("ServerScriptService")
		:WaitForChild("Modules")
		:WaitForChild("Admin")
		:WaitForChild("Panel")
		:WaitForChild("State")
)
H.Fakes = Fakes

local OK = { IsContentSharingAllowed = true }

function H.boot(opts)
	opts = opts or {}
	local services = {
		Players = Fakes.players(),
		GroupService = opts.groups or Fakes.groupService(),
		TextChatService = Fakes.textChatService(),
		TextService = StudWork.test.fakes.textService({ replace = { badword = true } }),
	}
	local modules = {}
	for _, m in opts.modules or {} do
		table.insert(modules, m)
	end
	table.insert(modules, H.Admin)
	local servers = {}
	if opts.register then
		local probe = StudWork.defineModule({
			name = "Probe",
			version = "1.0.0",
			framework = "^1.7.0",
			dependsOn = { H.Admin },
			optional = opts.probeOptional,
		})
		table.insert(modules, probe)
		servers.Probe = {
			init = function(ctx)
				opts.register(ctx.depsExt[H.Admin], ctx)
			end,
		}
	end
	local config = table.clone(opts.config or {})
	config.Admin = opts.admin
	local policy = {}
	for id = 1, 100 do
		policy[id] = OK
	end
	local h = StudWork.test.harness({
		modules = modules,
		config = config,
		serverConfig = { Admin = opts.serverAdmin },
		services = services,
		servers = servers,
		isStudio = opts.isStudio,
		flags = opts.flags,
		compliance = opts.compliance,
		policy = policy,
	})
	return h, services
end

function H.users(map)
	return { users = map }
end

function H.join(h, userId, opts)
	if opts and opts.gui then
		local p = h.players[userId] or StudWork.test.player(userId, nil, true)
		h.players[userId] = p
		local gui = Fakes.giveGui(p)
		h:addPlayer({ userId = userId })
		return p, gui
	end
	return h:addPlayer({ userId = userId })
end

function H.sentTo(h, p, event)
	local out = {}
	for _, e in h:sent("Admin", event) do
		if e.player == p then
			table.insert(out, e)
		end
	end
	return out
end

function H.results(h, p)
	local out = {}
	for _, e in H.sentTo(h, p, "RunResult") do
		table.insert(out, { ok = e.args[1], key = e.args[2] })
	end
	return out
end

function H.last(h, p)
	local list = H.results(h, p)
	return list[#list]
end

function H.run(h, p, actionId, target, preset, duration, text)
	return h:action(p, H.Admin, "run", actionId, target, preset, duration, text)
end

function H.withPanel(fn)
	local original = H.AdminServer.placePanel
	H.AdminServer.placePanel = function(gui)
		local child = { Name = H.AdminServer.PANEL_NAME }
		function child.Destroy(self)
			local i = table.find(gui.children, self)
			if i then
				table.remove(gui.children, i)
			end
		end
		return gui.add(child)
	end
	local ok, err = pcall(fn)
	H.AdminServer.placePanel = original
	if not ok then
		error(err, 0)
	end
end

-- a registered action for the request specs (records its calls)
function H.action(id, opts)
	opts = opts or {}
	local calls = {}
	local def = {
		id = id,
		permission = opts.permission or "kick",
		labelKey = "Admin.action.bring",
		target = opts.target or "userId",
		presets = opts.presets,
		durations = opts.durations,
		freeText = opts.freeText,
		run = function(staff, targetUserId, args)
			table.insert(calls, { staff = staff, target = targetUserId, args = args })
			return true, "done"
		end,
	}
	return def, calls
end

return H
