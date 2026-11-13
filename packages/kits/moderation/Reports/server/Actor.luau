--!strict
--[[
	Actor: who is acting on a mutating moderation call (design B5; docs/framework/kits/moderation.md,
	"Actors and permissions"). Pure. Moderation and Reports each ship an identical copy in their own
	server part (no cross-module internal requires: the `special` guardrail); a kit spec checks that
	the copies stay identical.

	`opts.by` is REQUIRED:
	  a Player     "staff"    a staff request: permission and rank are checked
	  "server"     "server"   trusted game code
	  "console"    "console"  a console line typed with no player (Studio command bar)
	  "system"     "system"   automatic (Moderation.report, Reports' autoAction): only the actions in
	                          config.Moderation.auto.permissions
	Anything else (nil included) raises an error naming the fix.

	  Actor.kind(by, where) -> "staff" | "server" | "console" | "system"   (raises on a bad `by`)
	  Actor.of(opts, where) -> (by, kind)       reads opts.by (opts must be a table)
	  Actor.userId(by) -> number                the staff member's UserId; 0 for the trusted kinds
	  Actor.isTrusted(kind) -> boolean          "server" or "console"
	  Actor.isPlayer(value) -> boolean          a live Player (typeof Instance + IsA("Player"))
]]

local Actor = {}

export type Kind = "staff" | "server" | "console" | "system"

local TRUSTED = table.freeze({ server = true, console = true, system = true })

function Actor.isPlayer(value: any): boolean
	if typeof(value) ~= "Instance" then
		return false
	end
	local ok, isA = pcall(function(): boolean
		return value:IsA("Player")
	end)
	return ok and isA == true
end

local function fix(where: string, got: any): string
	return where
		.. ': opts.by is required: pass the acting staff Player, "server" (game code), "console" (a console line'
		.. ' with no player) or "system" (automatic); got '
		.. typeof(got)
		.. " "
		.. tostring(got)
end

function Actor.kind(by: any, where: string): Kind
	if Actor.isPlayer(by) then
		return "staff"
	end
	if type(by) == "string" and TRUSTED[by] then
		return by :: any
	end
	error(fix(where, by), 3)
end

function Actor.of(opts: any, where: string): (any, Kind)
	if type(opts) ~= "table" then
		error(fix(where, nil) .. " (opts must be a table)", 3)
	end
	local by = opts.by
	if Actor.isPlayer(by) then
		return by, "staff"
	end
	if type(by) == "string" and TRUSTED[by] then
		return by, by :: any
	end
	error(fix(where, by), 3)
end

function Actor.userId(by: any): number
	if Actor.isPlayer(by) then
		return by.UserId
	end
	return 0
end

function Actor.isTrusted(kind: string): boolean
	return kind == "server" or kind == "console"
end

return Actor
