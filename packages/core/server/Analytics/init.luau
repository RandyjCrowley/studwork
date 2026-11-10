--!strict
--[[
	Core.Analytics. OWNED BY AGENT E (core/e-meta). Public API: Types.AnalyticsAPI.

	PHASE 0 STUB: funnel steps logged once per player (PlayerData.funnel) through
	AnalyticsService:LogOnboardingFunnelStepEvent (step number = index in
	GameConfig.analytics.funnel); economy -> LogEconomyEvent with the ending balance; custom ->
	LogCustomEvent. Logs "Joined" automatically. Agent E: verify the current AnalyticsService
	signatures, ClientFunnel handler (clientSteps whitelist), economy hooks, tests for step math.
]]

local AnalyticsService = game:GetService("AnalyticsService")

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))

local Analytics = {}

local ctx: any = nil

function Analytics.init(context: any)
	ctx = context
end

function Analytics.start()
	ctx.services.Data.onLoaded(function(player: Player)
		Analytics.funnel(player, "Joined")
	end)
	ctx.net.handle("ClientFunnel", function(player: Player, step: string)
		local allowed = ctx.config.analytics and ctx.config.analytics.clientSteps
		if allowed and table.find(allowed, step) then
			Analytics.funnel(player, step)
		end
	end)
end

function Analytics.funnel(player: Player, step: string)
	local steps = ctx.config.analytics and ctx.config.analytics.funnel or {}
	local index = table.find(steps, step)
	if index == nil then
		return
	end
	local data: Types.PlayerData? = ctx.services.Data.get(player)
	if data == nil or data.funnel[step] then
		return
	end
	ctx.services.Data.update(player, function(d: Types.PlayerData)
		d.funnel[step] = os.time()
	end)
	pcall(function()
		AnalyticsService:LogOnboardingFunnelStepEvent(player, index, step)
	end)
end

function Analytics.economy(
	player: Player,
	flow: "Source" | "Sink",
	currency: string,
	amount: number,
	transactionType: string,
	sku: string?
)
	local ending = ctx.services.Economy.balance(player, currency)
	pcall(function()
		local flowType = if flow == "Source"
			then Enum.AnalyticsEconomyFlowType.Source
			else Enum.AnalyticsEconomyFlowType.Sink
		AnalyticsService:LogEconomyEvent(player, flowType, currency, amount, ending, transactionType, sku)
	end)
end

function Analytics.custom(player: Player, name: string, value: number?)
	pcall(function()
		AnalyticsService:LogCustomEvent(player, name, value or 1)
	end)
end

return Analytics
