--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Rules = require(script.Parent.shared.Rules)
local Layout = require(script.Layout)
local Codes: any = { actions = { "redeem" } }
local config: any = nil
local items: any = {}
local pending = false
local listeners: { [any]: boolean } = {}
local latest: string? = nil
local disconnect: (() -> ())? = nil
local flagConnection: any = nil
local generation = 0
local function framework(): any
	return require(ReplicatedStorage:WaitForChild("Framework")) :: any
end
local function ui(): any
	return require(ReplicatedStorage:WaitForChild("UI")) :: any
end
local function enabled(): boolean
	if config == nil then
		return false
	end
	if config.flag == nil then
		return true
	end
	local ok, on = pcall(framework().flags.isOn, config.flag)
	return ok and on == true
end
local function result(value: any)
	local safe = Layout.result(value)
	if safe == nil then
		return
	end
	pending = false
	latest = safe
	generation += 1
	for fn in listeners do
		task.spawn(fn, safe)
	end
end
local function subscribe(fn: any): () -> ()
	listeners[fn] = true
	return function()
		listeners[fn] = nil
	end
end
local function ownExtra(): any
	local ref = require(script.Parent.module)
	return framework().use(ref).state().extra or {}
end
local function sources(): { string }
	local value = ownExtra().rollSources
	return if type(value) == "table" then value else {}
end
local function odds(source: string)
	local rarityFolder = ReplicatedStorage:WaitForChild("Modules"):FindFirstChild("Rarity")
	if rarityFolder == nil then
		return
	end
	local ok, detail = pcall(function()
		local rarity = framework().use(require(rarityFolder.module))
		local extra = rarity.state().extra or {}
		return (extra.odds or {})[source]
	end)
	if ok and detail ~= nil then
		ui().open("Odds", { detail = detail, items = items })
	end
end
Codes.api = {
	open = function()
		if enabled() then
			ui().open("Codes")
		end
	end,
	redeem = function(raw: any): boolean
		if pending or not enabled() then
			return false
		end
		if Rules.normalize(raw, config.maxLength) == nil then
			result("invalid")
			return false
		end
		pending = true
		latest = nil
		generation += 1
		local token = generation
		require(script.Net).Redeem.Fire(raw)
		-- Dropped/rate-limited requests receive no server event; allow a later retry.
		task.delay(10, function()
			if pending and generation == token then
				result("try_later")
			end
		end)
		return true
	end,
}
function Codes.init(ctx: any)
	config = ctx.config
	items = ctx.gameConfig.items or {}
end
function Codes.start(_ctx: any)
	disconnect = require(script.Net).RedeemResult.On(result)
	if config.flag then
		flagConnection = framework().flags.onChanged(config.flag, function(on: boolean)
			if not on then
				ui().close("Codes")
			end
		end)
	end
	local UI = ui()
	if UI.screens:get("Codes") == nil then
		UI.registerScreen("Codes", function(props: any): any
			local supplied = table.clone(props)
			supplied.api = Codes.api
			supplied.subscribe = subscribe
			supplied.latest = function()
				return latest
			end
			supplied.pending = function()
				return pending
			end
			supplied.sources = sources
			supplied.odds = odds
			return require(script.Views).Screen(supplied)
		end)
	end
end
function Codes.destroy()
	if disconnect then
		disconnect()
		disconnect = nil
	end
	if flagConnection then
		flagConnection:Disconnect()
		flagConnection = nil
	end
	generation += 1
	pending = false
	table.clear(listeners)
end
return Codes
