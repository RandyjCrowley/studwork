--!strict
--[[
	Core.Analytics. OWNED BY AGENT E (core/e-meta). Public API: Types.AnalyticsAPI.

	Thin, pcall'd wrappers around AnalyticsService (signatures checked against the creator-docs
	AnalyticsService reference, 2026-11; none deprecated):
	  LogOnboardingFunnelStepEvent(player, step: int, stepName: string?, customFields?)
	  LogEconomyEvent(player, flowType: Enum.AnalyticsEconomyFlowType, currencyType, amount,
	                  endingBalance, transactionType, itemSku?, customFields?)
	  LogCustomEvent(player, eventName, value?, customFields?)
	The configured funnel is the onboarding funnel (one per experience, steps logged once per
	player), so LogOnboardingFunnelStepEvent is right; LogFunnelStepEvent is for recurring funnels
	with a funnelSessionId (e.g. a shop flow) and is not used by core.

	  - funnel(player, step): step must be in GameConfig.analytics.funnel; step number = index;
	    logged once per player (PlayerData.funnel[step] = os.time()). "Joined" is logged
	    automatically on DataLoaded when it is a configured step.
	  - economy(player, flow, currency, amount, transactionType, sku?): amount must be finite
	    and > 0; the ending balance comes from Economy.balance(player, currency); strings are
	    sanitized (control chars stripped, length capped).
	  - custom(player, name, value?): value defaults to 1; non-finite values are dropped.
	  - ClientFunnel remote: only GameConfig.analytics.clientSteps are accepted.
]]

local AnalyticsService = game:GetService("AnalyticsService")

local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Types"))
local AnalyticsUtil = require(script.AnalyticsUtil)

local MAX_NAME_LENGTH = 50
local JOINED_STEP = "Joined"

local Analytics = {}

local ctx: any = nil

local function funnelSteps(): { string }?
	local cfg: Types.AnalyticsConfig? = ctx.config.analytics
	return cfg and cfg.funnel
end

function Analytics.init(context: any)
	ctx = context
end

function Analytics.start()
	ctx.services.Data.onLoaded(function(player: Player)
		if AnalyticsUtil.stepIndex(funnelSteps(), JOINED_STEP) ~= nil then
			Analytics.funnel(player, JOINED_STEP)
		end
	end)
	ctx.net.handle("ClientFunnel", function(player: Player, step: any)
		local cfg: Types.AnalyticsConfig? = ctx.config.analytics
		if AnalyticsUtil.clientAllowed(cfg and cfg.clientSteps, step) then
			Analytics.funnel(player, step)
		end
	end)
end

function Analytics.funnel(player: Player, step: string)
	local index = AnalyticsUtil.stepIndex(funnelSteps(), step)
	if index == nil then
		return
	end
	local data: Types.PlayerData? = ctx.services.Data.get(player)
	if data == nil or (data.funnel and data.funnel[step]) then
		return
	end
	local recorded = ctx.services.Data.update(player, function(d: Types.PlayerData)
		d.funnel = d.funnel or {}
		d.funnel[step] = os.time()
	end)
	if not recorded then
		return
	end
	local ok, err = pcall(function()
		AnalyticsService:LogOnboardingFunnelStepEvent(player, index, step)
	end)
	if not ok then
		warn("[Core.Analytics] funnel: " .. tostring(err))
	end
end

function Analytics.economy(
	player: Player,
	flow: "Source" | "Sink",
	currency: string,
	amount: number,
	transactionType: string,
	sku: string?
)
	if flow ~= "Source" and flow ~= "Sink" then
		return
	end
	if not AnalyticsUtil.validAmount(amount) then
		return
	end
	local cleanCurrency = AnalyticsUtil.sanitize(currency, MAX_NAME_LENGTH)
	local cleanType = AnalyticsUtil.sanitize(transactionType, MAX_NAME_LENGTH)
	if cleanCurrency == nil or cleanType == nil then
		return
	end
	local cleanSku = AnalyticsUtil.sanitize(sku, MAX_NAME_LENGTH)
	if not ctx.isEnabled("Economy") then
		return -- economy events need an ending balance; games without Economy use custom events
	end
	local okBalance, ending = pcall(ctx.services.Economy.balance, player, currency)
	if not okBalance or type(ending) ~= "number" or ending ~= ending then
		return
	end
	local ok, err = pcall(function()
		local flowType = if flow == "Source"
			then Enum.AnalyticsEconomyFlowType.Source
			else Enum.AnalyticsEconomyFlowType.Sink
		AnalyticsService:LogEconomyEvent(player, flowType, cleanCurrency, amount, ending, cleanType, cleanSku)
	end)
	if not ok then
		warn("[Core.Analytics] economy: " .. tostring(err))
	end
end

function Analytics.custom(player: Player, name: string, value: number?)
	local cleanName = AnalyticsUtil.sanitize(name, MAX_NAME_LENGTH)
	if cleanName == nil then
		return
	end
	local v = if value == nil then 1 else value
	if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
		return
	end
	local ok, err = pcall(function()
		AnalyticsService:LogCustomEvent(player, cleanName, v)
	end)
	if not ok then
		warn("[Core.Analytics] custom: " .. tostring(err))
	end
end

return Analytics
