--!strict
--[[
	Pure readers of the replicated state for the HUD, on the per-module client slices
	(module-api.md §10; keys pinned in PHASE1-CONTRACT.md "Theme and UI reads"):
	  state.modules.Economy.data.currency, .extra.ratePerSec / .extra.multiplier
	  state.modules.Mail.extra.mailbox, state.modules.Plot.extra.plotName
	  state.modules.Rarity.extra.odds, state.modules.Inventory.data.inventory
	A v1.2-shaped state (no `modules`: a scaffold still on the v1.2 Core facade) is read from its
	flat fields, so the HUD works on both without the compat FlatState selector.
]]

local Slices = {}

local function slice(state: any, name: string): any
	if type(state) ~= "table" or type(state.modules) ~= "table" then
		return nil
	end
	local m = state.modules[name]
	return if type(m) == "table" then m else {}
end

local function field(t: any, key: string): any
	return if type(t) == "table" then t[key] else nil
end

function Slices.isModular(state: any): boolean
	return type(state) == "table" and type(state.modules) == "table"
end

function Slices.data(state: any, name: string): any
	local m = slice(state, name)
	if m ~= nil then
		return field(m, "data")
	end
	return field(state, "data")
end

function Slices.extra(state: any, name: string, key: string): any
	local m = slice(state, name)
	if m ~= nil then
		return field(field(m, "extra"), key)
	end
	return field(state, key)
end

function Slices.loaded(state: any): boolean
	return type(state) == "table" and state.loaded == true
end

function Slices.currency(state: any, currency: string): number
	local balance = field(field(Slices.data(state, "Economy"), "currency"), currency)
	return if type(balance) == "number" then balance else 0
end

function Slices.ratePerSec(state: any): number?
	local rate = Slices.extra(state, "Economy", "ratePerSec")
	return if type(rate) == "number" then rate else nil
end

function Slices.mailbox(state: any): { any }
	local box = Slices.extra(state, "Mail", "mailbox")
	return if type(box) == "table" then box else {}
end

function Slices.odds(state: any): { [string]: any }
	local odds = Slices.extra(state, "Rarity", "odds")
	return if type(odds) == "table" then odds else {}
end

function Slices.inventory(state: any): { any }
	local inv = field(Slices.data(state, "Inventory"), "inventory")
	return if type(inv) == "table" then inv else {}
end

function Slices.plotName(state: any): string?
	local name = Slices.extra(state, "Plot", "plotName")
	return if type(name) == "string" then name else nil
end

return Slices
