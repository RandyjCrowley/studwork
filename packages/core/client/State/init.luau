--!strict
--[[
	Core.Client.state. OWNED BY AGENT G (core/g-client).

	PHASE 0 STUB: a Charm atom set from full snapshots ({ full = ReplicatedState }) received
	through the Blink StateSync event. Agent G replaces this with charm-sync's client syncer
	applying patches, keeping the same atom identity (State.atom) and ReplicatedState shape.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Charm = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Charm"))
local Types = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("Types"))

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

function State.start(ctx: any)
	ctx.net.StateSync.On(function(payload: any)
		if type(payload) == "table" and type(payload.full) == "table" then
			State.atom(payload.full)
		end
	end)
	ctx.net.StateInit.Fire()
end

return State
