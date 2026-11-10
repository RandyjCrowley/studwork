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

Client.api = {
	state = State.atom,
	Feedback = Feedback,
	Input = Input,
	Actions = Actions,
	Hud = Hud,
	onFeedbackEvent = Feedback.onFeedbackEvent,
} :: Types.ClientAPI

function Client.start(_core: Types.CoreAPI, config: Types.GameConfig)
	local ctx = { config = config, net = require(script.Net.Generated) }
	State.start(ctx)
	Input.start(ctx)
	Feedback.start(ctx)
	Hud.init(ctx)
end

return Client
