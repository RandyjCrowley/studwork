--!strict
--[[
	Offline module definition (kit: economy). core-v1.3.0 Phase 1: a real StudWork module; the
	server part is ../server/Offline.

	config (config.Offline): offline = {
	  capSeconds      the most time away that counts            default 28800 (8 h)
	  minSeconds      shorter absences are ignored               default 60
	  payoutFraction  0..1 of the rate paid for the time away    default 0.5
	  autoPay         pay automatically (needs Economy)          default true }
	No save data: it reads ctx.framework.lastSeen / sessions.
	optional: Economy (autoPay).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Economy = require(script.Parent.Economy)

return StudWork.defineModule({
	name = "Offline",
	version = "1.3.0",
	framework = "^1.3.0",
	description = "Time-away detection and the offline payout (economy kit)",
	optional = { Economy },
	config = {
		schema = {
			offline = {
				capSeconds = { type = "number(0..)", description = "the most time away that counts" },
				minSeconds = { type = "number(0..)", description = "shorter absences are ignored" },
				payoutFraction = {
					type = "number(0..1)",
					description = "share of the rate paid for the time away",
				},
				autoPay = {
					type = "boolean",
					description = "pay the offline earnings automatically (needs Economy)",
				},
			},
		},
		defaults = {
			offline = { capSeconds = 8 * 3600, minSeconds = 60, payoutFraction = 0.5, autoPay = true },
		},
	},
})
