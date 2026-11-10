--!strict
--[[
	Core client bootstrap. LEAD-OWNED. Required by the Core facade on the client.
	Builds Core.Client (Types.ClientAPI) and starts the client modules in order:
	State -> Input -> Feedback -> (game calls Core.Client.Hud.mount when it wants the HUD).
]]

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))

local Actions = require(script.Actions)
local Feedback = require(script.Feedback)
local Hud = require(script.Hud)
local Input = require(script.Input)
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
	Actions = pick(
		Actions,
		{ "display", "clearDisplay", "rebirth", "upgrade", "roll", "gift", "triggerEvent", "funnel" }
	),
	Hud = pick(Hud, { "mount", "unmount" }),
	onFeedbackEvent = Feedback.onFeedbackEvent,
}) :: Types.ClientAPI

function Client.start(
	_core: Types.CoreAPI,
	config: Types.GameConfig,
	_serverConfig: Types.ServerConfig,
	_moduleOrder: { string }
)
	local ctx = { config = config, net = require(script.Net.Generated) }
	State.start(ctx)
	Input.start(ctx)
	Feedback.start(ctx)
	Hud.init(ctx)
end

return Client
