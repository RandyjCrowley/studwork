--!strict
--[[
	COMPAT ADAPTER for the Economy kit (Economy, Upgrades, Rebirth, Offline). Owned by Phase 1
	agent B; DELETED IN PHASE 2 with the rest of packages/kits/compat.

	The economy kit's four modules are REAL. The compat bridge calls this once per real module:

	  adapter(name, rt, api, txApi, extensions) -> { [v1.2 function name]: fn }?

	and uses the result as `services.<Module>` for the still-bridged v1.2 services and for the sim's
	Bridge.compatServices(rt). Only what is still called is returned:
	  Economy   grant / spend / balance / getRate / getMultiplier / addMultiplier /
	            removeMultiplier / addIncomeSource / removeIncomeSource (api), and grantInto(tx12,
	            amount, reason, currency?) for the v1.2 Shop (the sim): the flat view's framework
	            tx (V12Data.txOf) -> Economy.txApi.grant.
	  Upgrades  level / cost / purchase (Inventory.cap reads Upgrades.level).
	  Rebirth   addResetStep(id, fn(flatData, player)) (bridged Plot) -> Rebirth.extensions
	            .resetStep, with the v1.2 flat view of the rebirth tx; canRebirth / rebirth / cost /
	            multiplier.
	  Offline   onReturn.
	Only parts built by this kit's ModuleServers are adapted (a test-injected part isn't).

	Two bridged-sibling links the real modules can't make themselves (they never see compat):
	  - the v1.2 signal set: Economy.CurrencyChanged, Upgrades.UpgradePurchased and
	    Rebirth.Rebirthed are forwarded to the v1.2 signals (bridged Plot re-renders on
	    Rebirthed; the sim reads CurrencyChanged history). Connected once the first player has
	    loaded (the real modules create their signals in init, after this adapter ran).
	  - income.source = "displayed": the bridged Plot's contract api.displayed(player) becomes
	    Economy.extensions.displayedSource, invalidated on Plot's ItemDisplayed / DisplayCleared.
	    A real Plot registers it itself (PHASE1 report, request to agent C).
]]

local ServerScriptService = game:GetService("ServerScriptService")

local cache: { [any]: any } = setmetatable({}, { __mode = "k" }) :: any

local function kitServers(): any
	return (require :: any)(
		ServerScriptService:WaitForChild("Kits"):WaitForChild("Economy"):WaitForChild("ModuleServers")
	)
end

local function refNamed(rt: any, name: string): any
	for _, ref in rt.order or {} do
		if ref.name == name then
			return ref
		end
	end
	return nil
end

local function stateOf(rt: any): any
	local st = cache[rt]
	if st == nil then
		st = { forwards = {}, connected = false, v12 = nil }
		cache[rt] = st
	end
	return st
end

-- The bridge's v1.2 services + signals of this runtime, once it has finished building them.
local function v12(rt: any): (any, any)
	local st = stateOf(rt)
	if st.v12 == nil then
		local Bridge = (require :: any)(script.Parent.Parent:WaitForChild("Bridge"))
		local services, signals = Bridge.compatServices(rt)
		st.v12 = { services = services, signals = signals }
	end
	return st.v12.services, st.v12.signals
end

-- Forward a real module's signal to the v1.2 signal of the same name, once players load.
local function forward(rt: any, api: any, signalName: string)
	local st = stateOf(rt)
	table.insert(st.forwards, { api = api, name = signalName })
	if #st.forwards > 1 then
		return
	end
	rt.lifecycle.api("Compat.EconomyAdapter").onPlayerLoaded(function()
		if st.connected then
			return
		end
		st.connected = true
		local _, signals = v12(rt)
		for _, f in st.forwards do
			local real = f.api.signals[f.name]
			local old = signals[f.name]
			if real ~= nil and old ~= nil then
				real:Connect(function(...: any)
					old:Fire(...)
				end)
			end
		end
	end)
end

local function flatOf(rt: any, tx: any): any
	local services = v12(rt)
	return services.Data.txView(tx)
end

local function economy(rt: any, api: any, txApi: any, _extensions: any): any
	forward(rt, api, "CurrencyChanged")
	-- (Plot registers Economy.extensions.displayedSource itself since Phase 1 integration)
	local out: { [string]: any } = {}
	for _, fn in
		{
			"grant",
			"spend",
			"balance",
			"getRate",
			"getMultiplier",
			"addMultiplier",
			"removeMultiplier",
			"addIncomeSource",
			"removeIncomeSource",
		}
	do
		out[fn] = api[fn]
	end
	-- v1.2 grantInto over a v1.2 tx { player, data = flat view, after } (the v1.2 Shop in the sim)
	out.grantInto = function(tx12: any, amount: number, reason: string, currency: string?): boolean
		local services = v12(rt)
		local tx = services.Data.txOf(tx12.data)
		assert(tx ~= nil, "[Compat.Economy] grantInto: the v1.2 tx has no framework tx")
		return txApi.grant(tx, amount, reason, currency)
	end
	return out
end

return function(name: string, rt: any, api: any, txApi: any, extensions: any): any
	local ref = refNamed(rt, name)
	if ref == nil or not kitServers().isReal(ref) then
		return nil -- not this kit's own part (e.g. a test-injected one): nothing to adapt
	end
	if name == "Economy" then
		return economy(rt, api, txApi, extensions)
	elseif name == "Upgrades" then
		forward(rt, api, "UpgradePurchased")
		return { level = api.level, cost = api.cost, purchase = api.purchase }
	elseif name == "Rebirth" then
		forward(rt, api, "Rebirthed")
		return {
			canRebirth = api.canRebirth,
			rebirth = api.rebirth,
			cost = api.cost,
			multiplier = api.multiplier,
			addResetStep = function(id: string, fn: (data: any, player: any) -> ())
				extensions.resetStep(id, function(tx: any, player: any)
					fn(flatOf(rt, tx), player)
				end)
			end,
		}
	elseif name == "Offline" then
		return { onReturn = api.onReturn }
	end
	return nil
end
