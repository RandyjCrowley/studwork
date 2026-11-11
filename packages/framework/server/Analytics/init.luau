--!strict
--[[
	Framework Analytics (ported from v1.2 core/server/Analytics). Framework internal; modules see
	ctx.analytics = { funnel, economy, custom }. Thin, pcall'd wrappers around AnalyticsService:
	  LogOnboardingFunnelStepEvent(player, step: int, stepName)
	  LogEconomyEvent(player, flowType, currency, amount, endingBalance, transactionType, sku?)
	  LogCustomEvent(player, eventName, value)

	  funnel(player, step)  step must be in GameConfig.analytics.funnel; step number = index; logged
	                        once per player (_framework.funnel[step] = now, in its own tx). "Joined"
	                        is logged automatically when a player's data loads, if it's a step.
	  economy(player, flow, currency, amount, endingBalance, transactionType, sku?)
	                        (revised in step 4b: the CALLER passes endingBalance. v1.2 looked it up
	                        through Economy.balance, i.e. the framework calling a kit; nothing in the
	                        framework may depend on a kit, so the currency's owner supplies it.)
	                        amount finite and > 0; strings sanitized (control chars, length).
	  custom(player, name, value?, fields?)  value defaults to 1; non-finite values are dropped.
	                        fields (step 4b, additive): { [string]: string } -> customFields.
	  ClientFunnel (framework Blink event): only GameConfig.analytics.clientSteps are accepted.

	Analytics.new(opts): opts.config (GameConfig.analytics or nil), opts.service ({ funnel, economy,
	custom } platform calls), opts.data (framework Data), opts.now, opts.log(msg).
]]

local AnalyticsUtil = require(script.AnalyticsUtil)

local Analytics = {}

Analytics.MAX_NAME_LENGTH = 50
Analytics.MAX_FIELD_LENGTH = 100
Analytics.JOINED_STEP = "Joined"

function Analytics.new(opts: any): any
	local cfg = opts.config
	local service = opts.service
	local data = opts.data
	local now: () -> number = opts.now
	local log: (string) -> () = opts.log

	local a: any = {}

	local function steps(): { string }?
		return if type(cfg) == "table" then cfg.funnel else nil
	end

	function a.funnel(player: any, step: string)
		local index = AnalyticsUtil.stepIndex(steps(), step)
		if index == nil or not data.isLoaded(player) then
			return
		end
		local funnel = data.frameworkField(player, "funnel")
		if type(funnel) == "table" and funnel[step] ~= nil then
			return
		end
		local ok, recorded = pcall(data.runTx, player, function(tx: any)
			local fw = data.section(tx, "_framework")
			fw.funnel = fw.funnel or {}
			fw.funnel[step] = now()
		end)
		if not ok then
			log("[StudWork.Analytics] funnel: " .. tostring(recorded))
			return
		end
		if not recorded then
			return
		end
		local okLog, err = pcall(service.funnel, player, index, step)
		if not okLog then
			log("[StudWork.Analytics] funnel: " .. tostring(err))
		end
	end

	function a.economy(
		player: any,
		flow: string,
		currency: string,
		amount: number,
		endingBalance: number,
		transactionType: string,
		sku: string?
	)
		if flow ~= "Source" and flow ~= "Sink" then
			return
		end
		if not AnalyticsUtil.validAmount(amount) then
			return
		end
		if
			type(endingBalance) ~= "number"
			or endingBalance ~= endingBalance
			or math.abs(endingBalance) == math.huge
		then
			return
		end
		local cleanCurrency = AnalyticsUtil.sanitize(currency, Analytics.MAX_NAME_LENGTH)
		local cleanType = AnalyticsUtil.sanitize(transactionType, Analytics.MAX_NAME_LENGTH)
		if cleanCurrency == nil or cleanType == nil then
			return
		end
		local cleanSku = AnalyticsUtil.sanitize(sku, Analytics.MAX_NAME_LENGTH)
		local ok, err =
			pcall(service.economy, player, flow, cleanCurrency, amount, endingBalance, cleanType, cleanSku)
		if not ok then
			log("[StudWork.Analytics] economy: " .. tostring(err))
		end
	end

	function a.custom(player: any, name: string, value: number?, fields: { [string]: string }?)
		local cleanName = AnalyticsUtil.sanitize(name, Analytics.MAX_NAME_LENGTH)
		if cleanName == nil then
			return
		end
		local v = if value == nil then 1 else value
		if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
			return
		end
		local cleanFields: { [string]: string }? = nil
		if type(fields) == "table" then
			local out: { [string]: string } = {}
			for k, fv in fields do
				local ck = AnalyticsUtil.sanitize(k, Analytics.MAX_NAME_LENGTH)
				local cv = AnalyticsUtil.sanitize(tostring(fv), Analytics.MAX_FIELD_LENGTH)
				if ck and cv then
					out[ck] = cv
				end
			end
			cleanFields = out
		end
		local ok, err = pcall(service.custom, player, cleanName, v, cleanFields)
		if not ok then
			log("[StudWork.Analytics] custom: " .. tostring(err))
		end
	end

	function a.onLoaded(player: any)
		if AnalyticsUtil.stepIndex(steps(), Analytics.JOINED_STEP) ~= nil then
			a.funnel(player, Analytics.JOINED_STEP)
		end
	end

	function a.clientFunnel(player: any, step: any)
		local clientSteps = if type(cfg) == "table" then cfg.clientSteps else nil
		if AnalyticsUtil.clientAllowed(clientSteps, step) then
			a.funnel(player, step)
		end
	end

	a.api = table.freeze({ funnel = a.funnel, economy = a.economy, custom = a.custom })
	return a
end

return Analytics
