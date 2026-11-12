--!strict
--[[
	Sandbox demo hook for the TextFilter module (docs/framework/kits/textfilter.md). Required from
	server/init.luau, which calls `init(ctx)` and `start(ctx)`; does nothing when the game leaves
	TextFilter out of GameConfig.modules.
	  - Studio console: `sandbox petname <name...>` filters a pet name through TextFilter.store (context "public") and answers with what other
	    players would see, TextFilter.shown(stored), or the refusal reason. The original stays in
	    TextFilter's own section; this demo keeps only the Stored record (no original text) in
	    memory, and `sandbox petname-clear` releases it.
	A real game does the same from an action handler and keeps the Stored record in its own section.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local TextFilter = require(Modules:WaitForChild("TextFilter"):WaitForChild("module"))

local DemoTextFilter = {}

local stored: { [number]: any } = {} -- userId -> Stored record (never the original text)

local function firstPlayer(): Player?
	return game:GetService("Players"):GetPlayers()[1]
end

function DemoTextFilter.init(ctx: any)
	if not ctx.isEnabled(TextFilter) or not ctx.isStudio then
		return
	end
	ctx.console.register("petname", function(_player: any, ...: string): string
		local player = firstPlayer()
		if player == nil then
			return "no player"
		end
		local name = table.concat({ ... }, " ")
		local tf = ctx.deps[TextFilter]
		local ok, result = tf.store(player, name, "public")
		if not ok then
			return `refused: {result}`
		end
		local previous = stored[player.UserId]
		if previous ~= nil then
			tf.release(player, previous)
		end
		stored[player.UserId] = result
		return `others see: {tf.shown(result) or ctx.text.english("TextFilter.hidden")}`
	end, "sandbox petname <name>: filter a pet name (public) and show what others see (Studio)")
	ctx.console.register("petname-clear", function(): string
		local player = firstPlayer()
		local record = if player then stored[player.UserId] else nil
		if player == nil or record == nil then
			return "no pet name"
		end
		ctx.deps[TextFilter].release(player, record)
		stored[player.UserId] = nil
		return "released"
	end, "sandbox petname-clear: release the demo pet name (Studio)")
end

function DemoTextFilter.start(_ctx: any) end

return DemoTextFilter
