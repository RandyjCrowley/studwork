--!strict
--[[
	Sandbox demo hook for the Leaderboards module (docs/framework/kits/leaderboards.md): wires the
	sandbox's "dailyTouches" board (config Balance.Leaderboards: a daily board, mode "sum") to the
	block touches the sandbox already counts, and adds a Studio console line that shows the top rows
	and the player's own rank. The "coins" board reads the Economy balance by itself (a built-in
	source), so it needs nothing here.

	Required from server/init.luau, which calls `init(ctx)` and `start(ctx)` with the sandbox module's
	ctx. Both do nothing when the module isn't enabled.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Leaderboards =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Leaderboards"):WaitForChild("module"))

local BOARD = "dailyTouches"

local DemoLeaderboards = {}

local ctx: any = nil
local seen: { [any]: number } = {} -- block touches already submitted, per player in this server

local function touchesOf(player: any): number?
	if not ctx.data.isLoaded(player) then
		return nil
	end
	local section = ctx.data.get(player)
	return if type(section) == "table" and type(section.blockTouches) == "number"
		then section.blockTouches
		else nil
end

-- Submits the touches counted since the last look (the board adds them up for the day).
local function submitNew(player: any)
	local touches = touchesOf(player)
	if touches == nil then
		return
	end
	local before = seen[player]
	seen[player] = touches
	if before ~= nil and touches > before then
		ctx.deps[Leaderboards].submit(player, BOARD, touches - before)
	end
end

local function describe(boardId: string, player: any?): string
	local api = ctx.deps[Leaderboards]
	local top = api.top(boardId)
	local lines = { `{boardId} (period {tostring(top.periodId or "all")}, {#top.rows} rows)` }
	for _, row in top.rows do
		table.insert(lines, `  #{row.rank} {row.name} {row.value}`)
	end
	if player ~= nil then
		local rank, value = api.rank(player, boardId)
		local place = if rank then ` (#{rank})` else ""
		table.insert(lines, `  you: {value}{place}`)
	end
	return table.concat(lines, "\n")
end

function DemoLeaderboards.init(context: any)
	ctx = context
	if not ctx.isEnabled(Leaderboards) then
		return
	end
	ctx.console.register("top", function(player: any, boardId: any): string
		local id = if type(boardId) == "string" and boardId ~= "" then boardId else BOARD
		return describe(id, player)
	end, "sandbox top [boardId]: the shared top rows and your own value and rank (Studio)")
end

function DemoLeaderboards.start(_context: any)
	if not ctx.isEnabled(Leaderboards) then
		return
	end
	ctx.data.onLoaded(function(player: any)
		seen[player] = touchesOf(player) or 0
	end)
	ctx.lifecycle.onPlayerRemoving(function(player: any)
		seen[player] = nil
	end)
	-- once a second, submit the touches counted since the last look
	ctx.lifecycle.onTick(1, function()
		for player in table.clone(seen) do
			submitNew(player)
		end
	end)
end

return DemoLeaderboards
