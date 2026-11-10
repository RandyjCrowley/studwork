--!strict
--[[
	Creates the typed CoreSignals table (see Types.CoreSignals) on top of sleitnick/signal.
	Signals are created on both server and client; server-side game signals only fire on the server.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(script.Parent.Types)
local Signal = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Signal"))

local NAMES = {
	"DataLoaded",
	"DataChanged",
	"CurrencyChanged",
	"ItemAdded",
	"ItemRemoved",
	"ItemDisplayed",
	"ItemUndisplayed",
	"Rebirthed",
	"UpgradePurchased",
	"StreakAdvanced",
	"CoPlay",
	"EventStarted",
	"EventEnded",
	"ProductGranted",
	"PlotAssigned",
	"PlotReleased",
}

local Signals = {}

function Signals.new(): Types.CoreSignals
	local set = {}
	for _, name in NAMES do
		set[name] = Signal.new()
	end
	return (set :: any) :: Types.CoreSignals
end

Signals.NAMES = NAMES

return Signals
