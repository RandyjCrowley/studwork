--!strict
--[[
	StudWork: the public facade (module-api.md §4), shared by both sides.

	  StudWork.defineModule(spec) -> ModuleRef        validate + freeze a definition (§2)
	  StudWork.use(ref) -> API                         the module's frozen API on this side
	  StudWork.start(GameConfig, ServerConfig?)        boot (delegates to the side's runtime,
	                                                   installed by requiring server/ or client/)
	  StudWork.<Name>                                  untyped sugar for every ENABLED module
	  StudWork.hook()                                  a helper list for offering extensions (§8)

	C1: `use` accepts ONLY a ModuleRef. Data, Compliance, Net, Replication, Shop and Policy are
	framework internals with no ModuleRef and no facade; they are reachable only through the
	scoped ctx a module receives. StudWork.Data and friends error with that explanation.

	There is no item registration anywhere (CHANGELOG core-v1.3.0, Breaking): any register-/add-
	style key on this facade errors with ItemFields.NO_LATE_ITEMS_ERROR.
]]

local DefineModule = require(script.defineModule)
local ItemFields = require(script.ItemFields)
local Resolve = require(script.Resolve)

local StudWork = {}

StudWork.VERSION = "1.3.0"

export type ModuleRef<API = any, TxAPI = any, ClientAPI = any> = any

local INTERNALS =
	{ Data = true, Compliance = true, Net = true, Replication = true, Shop = true, Policy = true }

-- The side's runtime lives in RuntimeSlot, written only by server/Boot.luau (decision 3, Phase 0
-- step 4). It provides state: "booting" | "running" | "failed", bootError, phase,
-- isEnabled(ref), api(ref), byName(name).
local RuntimeSlot = require(script.RuntimeSlot)

StudWork.defineModule = DefineModule.defineModule
StudWork.isModuleRef = DefineModule.isModuleRef

function StudWork.start(...: any): any
	local starter = RuntimeSlot.starter
	if starter == nil then
		error(
			"[StudWork] StudWork.start: no runtime installed; require the framework's server (or client) part first",
			2
		)
	end
	return (starter :: any)(...)
end

local function notEnabledProxy(name: string): any
	local msg = Resolve.notEnabledMessage(name)
	return table.freeze(setmetatable(
		{},
		table.freeze({
			__index = function()
				error(msg, 2)
			end,
			__newindex = function()
				error(msg, 2)
			end,
		})
	) :: any)
end
StudWork._notEnabledProxy = notEnabledProxy

local function assertStarted(what: string)
	if RuntimeSlot.runtime == nil then
		error(`[StudWork] {what} called before StudWork.start`, 3)
	end
	if RuntimeSlot.runtime.state == "failed" then
		error(RuntimeSlot.runtime.bootError, 3)
	end
	if RuntimeSlot.runtime.phase ~= "start" and RuntimeSlot.runtime.phase ~= "running" then
		error(
			`[StudWork] {what} called before StudWork.start (boot phase '{tostring(RuntimeSlot.runtime.phase)}')`,
			3
		)
	end
end

function StudWork.use<A>(ref: ModuleRef<A>): A
	if not DefineModule.isModuleRef(ref) then
		if type(ref) == "string" and INTERNALS[ref] then
			error(
				`[StudWork] StudWork.use("{ref}"): {ref} is a framework internal, not a module; use the scoped ctx.{string.lower(
					ref
				)} inside your module (design review C1)`,
				2
			)
		end
		error(
			`[StudWork] StudWork.use expects a ModuleRef (the value returned by StudWork.defineModule), got {typeof(
				ref
			)} {tostring(ref)}`,
			2
		)
	end
	assertStarted("StudWork.use")
	if RuntimeSlot.runtime.isEnabled(ref) then
		return RuntimeSlot.runtime.api(ref)
	end
	return notEnabledProxy((ref :: any).name)
end

-- A tiny hook list for modules offering extensions (§8):
--   local removed = StudWork.hook()
--   extensions = { onItemRemoved = removed.register }  ...  removed.fire(tx, player, instance)
function StudWork.hook(): any
	local fns: { (...any) -> () } = {}
	return table.freeze({
		register = function(fn: (...any) -> ())
			assert(type(fn) == "function", "hook expects a function")
			table.insert(fns, fn)
		end,
		fire = function(...: any)
			for _, fn in fns do
				fn(...)
			end
		end,
		count = function(): number
			return #fns
		end,
	})
end

setmetatable(
	StudWork,
	table.freeze({
		__index = function(_, key: any)
			if type(key) == "string" and INTERNALS[key] then
				error(
					`[StudWork] StudWork.{key}: {key} is a framework internal with no public facade; use ctx.{string.lower(
						key
					)} inside your module (design review C1)`,
					2
				)
			end
			if RuntimeSlot.runtime ~= nil and RuntimeSlot.runtime.state == "failed" then
				error(RuntimeSlot.runtime.bootError, 2)
			end
			if
				RuntimeSlot.runtime ~= nil
				and (RuntimeSlot.runtime.phase == "start" or RuntimeSlot.runtime.phase == "running")
			then
				local ref = RuntimeSlot.runtime.byName(key)
				if ref then
					return RuntimeSlot.runtime.api(ref)
				end
			end
			if type(key) == "string" then
				local k = string.lower(key)
				if string.find(k, "register", 1, true) or string.find(k, "item", 1, true) then
					error(ItemFields.NO_LATE_ITEMS_ERROR, 2)
				end
			end
			error(
				`[StudWork] StudWork.{tostring(key)}: no such member, and no enabled module named {tostring(
					key
				)}`,
				2
			)
		end,
		__newindex = function(_, key: any)
			error(`[StudWork] StudWork is read-only (tried to set {tostring(key)})`, 2)
		end,
	})
)

return table.freeze(StudWork)
