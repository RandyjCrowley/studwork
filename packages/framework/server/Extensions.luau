--!strict
--[[
	Wraps a module's server surfaces for other modules (module-api.md §4, §5.1, §8):

	  api         -> StudWork.use(ref) / ctx.deps[ref]      blocked during the init phase (§3 step 4:
	                                                       no calls into other modules' APIs in init)
	  txApi       -> ctx.depsTx[ref]                        first argument must be an OPEN tx
	  extensions  -> ctx.depsExt[ref]                       callable in init (register hooks there)

	Every wrapped function also fails closed after a boot failure (N7). Non-function members
	(e.g. api.signals) are passed through; plain tables are frozen copies.

	Extensions in both directions use the same mechanism. The *inverted* pattern (H3): the module
	being acted on (Collection) offers `onItemRemoved(fn)`; a dependent (Plot) registers a hook
	that closes over ITS OWN ctx, so when Collection fires the hook inside Collection's tx, the
	hook's `ctx.section(tx)` is Plot's section. No new runtime concept: ctx.section is bound to
	the registering module's data.key, and the tx is the one shared handle.
]]

local Shared = require(script.Parent.Shared)
local requireShared = require :: any -- see Shared.luau
local Freeze = requireShared(Shared.Freeze)

local Extensions = {}

local function wrapTable(_rt: any, owner: string, surface: string, t: any, guard: (string) -> ()): any
	if t == nil then
		return table.freeze({})
	end
	assert(type(t) == "table", `{owner}.{surface} must be a table`)
	local out = {}
	for key, value in t do
		local label = `{owner}.{surface}.{tostring(key)}`
		if type(value) == "function" then
			out[key] = function(...: any): ...any
				guard(label)
				return value(...)
			end
		else
			out[key] = Freeze.freezeCopy(value)
		end
	end
	return table.freeze(out)
end

function Extensions.wrapApi(rt: any, owner: string, api: any): any
	return wrapTable(rt, owner, "api", api, function(label: string)
		rt.assertUsable()
		if rt.phase == "init" then
			error(
				`{label} called during init: modules may not call other modules' APIs in init(ctx); move the call to start(ctx)`,
				3
			)
		end
	end)
end

function Extensions.wrapTxApi(rt: any, owner: string, txApi: any): any
	if txApi == nil then
		return table.freeze({})
	end
	local out = {}
	for key, value in txApi do
		local label = `{owner}.txApi.{tostring(key)}`
		assert(type(value) == "function", `{label} must be a function(tx, ...)`)
		out[key] = function(tx: any, ...: any): ...any
			rt.assertUsable()
			if not rt.data.isTxHandle(tx) then
				error(`{label}: first argument must be the open tx from ctx.tx(player, fn)`, 2)
			end
			return value(tx, ...)
		end
	end
	return table.freeze(out)
end

function Extensions.wrapExtensions(rt: any, owner: string, ext: any): any
	return wrapTable(rt, owner, "extensions", ext, function(_label: string)
		rt.assertUsable()
	end)
end

return Extensions
