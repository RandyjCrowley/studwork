--!strict
--[[
	Framework client bootstrap. LEAD-OWNED. Requiring it installs the StudWork CLIENT
	runtime (Runtime.luau) into the StudWork facade, so a game's client is one line:
	StudWork.start(Config). That boots the client modules (StudWork.use(X) = X's ClientAPI with
	its actions, §9) and this framework client UI, exposed as StudWork.Client:
	  state()            the replicated state, as sent (§10: { loaded, framework, modules })
	  Hud, Feedback, Input, onFeedbackEvent, onMailbox   the client UI on theme tokens + HUD slots
	  Hud.addWidget(id, spec | false)   the one call a module or game uses to contribute (or
	                     remove) a HUD widget (= UI.registerWidget; Phase 2)
	The UI reads the replicated state as sent (State.raw through Hud/Slices).

	v1.2 path (kept until step 4b-IIb converts the scaffolds): the Core facade requires this file
	on the client and calls Client.start(core, config, serverConfig, moduleOrder).
	Builds Core.Client (Types.ClientAPI) and starts the client modules in order (Actions learns
	the enabled modules first, so module-owned actions error when their module is off):
	State -> Input -> Feedback -> (game calls Core.Client.Hud.mount when it wants the HUD).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Charm = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Charm")) :: any
local Types = require(ReplicatedStorage:WaitForChild("Framework"):WaitForChild("Types"))

local Actions = require(script.Actions)
local Boot = require(script.Boot)
local Feedback = require(script.Feedback)
local Hud = require(script.Hud)
local Input = require(script.Input)
local Runtime = require(script.Runtime)
local State = require(script.State)
local Visibility = require(script.Hud.Visibility)

local Client = {}

-- M7: frozen tables with only the Types.ClientAPI fields (no start/init).
local function pick(source: { [string]: any }, names: { string }): any
	local out: { [string]: any } = {}
	for _, name in names do
		assert(source[name] ~= nil, "[Core.Client] contract mismatch: missing " .. name)
		out[name] = source[name]
	end
	return table.freeze(out)
end

-- v1.2 (N1): handler(count) when the loaded mailbox count changes (and once now if loaded).
local function onMailbox(handler: (count: number) -> ()): Types.Connection
	assert(type(handler) == "function", "Core.Client.onMailbox: handler must be a function")
	local function countOf(): number
		local s = State.atom()
		return if s.loaded then Visibility.mailboxCount(s) else -1
	end
	local last = countOf()
	if last >= 0 then
		task.spawn(handler, last)
	end
	local cleanup = Charm.subscribe(countOf, function(n: number)
		if n >= 0 and n ~= last then
			last = n
			task.spawn(handler, n)
		end
	end)
	local connection = { Connected = true }
	function connection.Disconnect(self: any)
		if self.Connected then
			self.Connected = false
			cleanup()
		end
	end
	return (connection :: any) :: Types.Connection
end

Client.api = table.freeze({
	state = State.atom,
	Feedback = pick(Feedback, { "pop", "flash", "sound", "shake" }),
	Input = pick(Input, { "device", "deviceChanged", "bind", "unbind" }),
	Actions = pick(Actions, {
		"display",
		"clearDisplay",
		"rebirth",
		"upgrade",
		"roll",
		"gift",
		"triggerEvent",
		"funnel",
		"claimMail",
	}),
	Hud = pick(Hud, { "mount", "unmount", "addWidget" }),
	onFeedbackEvent = Feedback.onFeedbackEvent,
	onMailbox = onMailbox,
}) :: Types.ClientAPI

function Client.start(
	_core: Types.CoreAPI,
	config: Types.GameConfig,
	_serverConfig: Types.ServerConfig,
	moduleOrder: { string }
)
	Actions.start(moduleOrder)
	local ctx = { config = config, net = require(script.Net.Generated), isEnabled = Actions.isEnabled }
	State.start(ctx)
	Input.start(ctx)
	Feedback.start(ctx)
	Hud.init(ctx)
end

-- StudWork.Client (client only).
Client.studWork = table.freeze({
	state = State.raw,
	Feedback = Client.api.Feedback,
	Input = Client.api.Input,
	Hud = Client.api.Hud,
	onFeedbackEvent = Feedback.onFeedbackEvent,
	onMailbox = onMailbox,
})

-- Step 4 of the client boot: the framework client UI. The state is the replicated state as sent
-- (Hud and onMailbox read it raw). The UI's config carries what it reads: GameConfig.client.palette
-- overrides and the primary currency (config.Economy.primaryCurrency, default "Coins").
local function startUi(info: any): any
	local names: { string } = {}
	for _, ref in info.order do
		table.insert(names, ref.name)
	end
	local configs = info.configs or {}
	local economy = configs.Economy
	local client = info.gameConfig.client
	local view = {
		gameId = info.gameConfig.gameId,
		modules = names,
		palette = if type(client) == "table" then client.palette else nil,
		balance = {
			primaryCurrency = if type(economy) == "table"
					and type(economy.primaryCurrency) == "string"
				then economy.primaryCurrency
				else "Coins",
		},
	}
	Client.start((nil :: any) :: Types.CoreAPI, view :: any, {}, names)
	return Client.studWork
end

Boot.installStarter(function(gameConfig: any, serverConfig: any?): any
	return Runtime.start(gameConfig, serverConfig, {
		ui = startUi,
		state = State.raw,
		computed = Charm.computed,
	})
end)

return Client
