--!strict
--[[
	Framework client bootstrap. Requiring it installs the StudWork CLIENT
	runtime (Runtime.luau) into the StudWork facade, so a game's client is one line:
	StudWork.start(Config). That boots the client modules (StudWork.use(X) = X's ClientAPI with
	its actions, §9) and this framework client UI, exposed as StudWork.Client:
	  state()            the replicated state, as sent (§10: { loaded, framework, modules })
	  Hud, Feedback, Input, onFeedbackEvent   the client UI on theme tokens + HUD slots
	                     (v1.3.1: onMailbox moved to the mail module's client API)
	  Hud.addWidget(id, spec | false)   the one call a module or game uses to contribute (or
	                     remove) a HUD widget (= UI.registerWidget; v1.3.0)
	The UI reads the replicated state as sent (State.raw through Hud/Slices).

	v1.2 path (kept until v1.3.0 converts the scaffolds): the Core facade requires this file
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

Client.api = table.freeze({
	state = State.atom,
	Feedback = pick(Feedback, { "pop", "flash", "sound", "shake" }),
	Input = pick(Input, { "device", "deviceChanged", "bind", "unbind" }),
	Actions = pick(Actions, { "triggerEvent", "funnel" }),
	Hud = pick(Hud, { "mount", "unmount", "addWidget" }),
	onFeedbackEvent = Feedback.onFeedbackEvent,
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
})

-- Step 4 of the client boot: the framework client UI. The state is the replicated state as sent
-- (the HUD reads it raw). The UI's config carries what it reads: GameConfig.client.palette
-- overrides. v1.3.1 (R19): no module's config is read here (the currency widget, with its
-- primary currency, is the economy module's client part).
local function startUi(info: any): any
	local names: { string } = {}
	for _, ref in info.order do
		table.insert(names, ref.name)
	end
	local client = info.gameConfig.client
	local view = {
		gameId = info.gameConfig.gameId,
		modules = names,
		palette = if type(client) == "table" then client.palette else nil,
	}
	Client.start((nil :: any) :: Types.CoreAPI, view :: any, {}, names)
	return Client.studWork
end

Boot.installStarter(function(gameConfig: any, serverConfig: any?): any
	local rt = Runtime.start(gameConfig, serverConfig, {
		ui = startUi,
		state = State.raw,
		computed = Charm.computed,
	})
	-- (v1.7.0) the server's flag values arrive in state.framework.flags: keep the client in step
	pcall(function()
		Charm.subscribe(State.raw, function()
			rt.syncFramework()
		end)
	end)
	return rt
end)

return Client
