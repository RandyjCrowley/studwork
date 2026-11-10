--!strict
--[[
	Core.Client.state. OWNED BY AGENT G (core/g-client).

	State.atom is a Charm atom (Types.Atom<Types.ReplicatedState>) with the same identity for the
	whole session. The server (server/Replication) syncs it with charm-sync 0.4.1:
	  * the client registers State.atom under its own key tostring(LocalPlayer.UserId) with
	    CharmSync.client.addSignals, then fires StateInit;
	  * StateSync payloads ({ SyncPayload }) are applied with CharmSync.client.patch, which sets
	    the atom from "init" (full state) or merges "patch" diffs immutably (patch.apply clones
	    every changed table, so React/Charm selectors see new references only where data changed);
	  * loaded becomes true once the server has PlayerData for us (it ships loaded = data ~= nil).
	Client code should only READ the atom.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local Charm = require(Packages:WaitForChild("Charm"))
local CharmSync = require(Packages:WaitForChild("CharmSync")) :: any
local Types = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("Types"))

local PayloadCheck = require(script.PayloadCheck)

local State = {}

local initial: Types.ReplicatedState = {
	loaded = false,
	data = nil,
	ratePerSec = 0,
	multiplier = 1,
	paidRandomRestricted = true,
	activeEvents = {},
	plotName = nil,
}

State.atom = (Charm.atom(initial) :: any) :: Types.Atom<Types.ReplicatedState>

local started = false

function State.start(ctx: any)
	if started then
		return
	end
	started = true
	local key = tostring(Players.LocalPlayer.UserId)
	CharmSync.client.addSignals({ [key] = State.atom })
	ctx.net.StateSync.On(function(payloads: any)
		local ok, reason = PayloadCheck.check(payloads, key)
		if not ok then
			warn(`[State] ignored StateSync payload: {reason}`)
			return
		end
		CharmSync.client.patch(payloads)
	end)
	ctx.net.StateInit.Fire()
end

return State
