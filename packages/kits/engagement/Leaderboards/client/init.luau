--!strict
--[[
	Leaderboards client part (docs/framework/kits/leaderboards.md, "Client part and UI").

	There is no client action: a score can't be submitted from a client. The client only receives
	the rows (extra.boards) and its own line (extra.mine).

	  StudWork.use(Leaderboards).board(boardId) -> { Row }     the rows from state ({} when unknown)
	  StudWork.use(Leaderboards).mine(boardId) -> { value, rank? }?
	  StudWork.use(Leaderboards).attach(parent, boardId, options?) -> () -> ()
	      mounts a UI.Leaderboard in `parent` (a SurfaceGui the game placed in the world: a lobby
	      board) and returns a function that unmounts it. options = { format?, title? (a string key) }.
	  StudWork.use(Leaderboards).open(boardId?, options?)       opens the "Leaderboards" screen
	      (options.formats = { [boardId] = "number" | "time" }).
	  StudWork.use(Leaderboards).read.<reader>(StudWork.Client.state())   pure readers (client/State.luau)

	Registers the screen "Leaderboards" (UI.registerScreen) at start unless the game registered its
	own first: a tab per board, the player's own row pinned when outside the top N.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local State = require(script.State)

local SCREEN = "Leaderboards"

local function studWork(): any
	return require(ReplicatedStorage:WaitForChild("Framework")) :: any
end

local function ui(): any
	return require(ReplicatedStorage:WaitForChild("UI")) :: any
end

local function views(): any
	return require(script.Views) :: any
end

local Leaderboards = {}

function Leaderboards.start(_ctx: any)
	local UI = ui()
	if UI.screens:get(SCREEN) == nil then
		UI.registerScreen(SCREEN, function(props: any): any
			return views().Screen(props)
		end)
	end
end

Leaderboards.api = {
	board = function(boardId: string): { any }
		return State.rows(studWork().Client.state(), boardId)
	end,
	mine = function(boardId: string): any
		return State.mine(studWork().Client.state(), boardId)
	end,
	attach = function(parent: Instance, boardId: string, options: any?): () -> ()
		assert(
			typeof(parent) == "Instance",
			"Leaderboards.attach(parent, boardId): parent must be an Instance"
		)
		assert(type(boardId) == "string", "Leaderboards.attach(parent, boardId): boardId must be a string")
		local o = options or {}
		local ReactRoblox =
			require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("ReactRoblox")) :: any
		local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React")) :: any
		local root = ReactRoblox.createRoot(parent)
		root:render(
			React.createElement(views().Mounted, { boardId = boardId, format = o.format, title = o.title })
		)
		return function()
			root:unmount()
		end
	end,
	open = function(boardId: string?, options: any?)
		local o = options or {}
		ui().open(SCREEN, { boardId = boardId, formats = o.formats })
	end,
	read = State,
}

return Leaderboards
