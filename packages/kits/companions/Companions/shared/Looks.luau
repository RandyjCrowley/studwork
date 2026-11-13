--!strict
-- Appearance callbacks must finish before the final safety pass.
local function invoke(fn: any, ...: any)
	local thread = coroutine.create(fn)
	coroutine.resume(thread, ...)
	if coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)
	end
end
local Types = require(script.Parent.Types)
export type Registry = {
	registerLook: (string, Types.Look) -> Types.Connection,
	applyLook: (Instance, any, string?) -> (),
	version: () -> number,
}
local function new(): Registry
	local callbacks: { [string]: Types.Look } = {}
	local revision = 0
	return {
		version = function()
			return revision
		end,
		registerLook = function(key: string, fn: Types.Look): Types.Connection
			assert(type(key) == "string" and #key > 0 and type(fn) == "function", "invalid look")
			assert(callbacks[key] == nil, "duplicate look")
			callbacks[key] = fn
			revision += 1
			return {
				Disconnect = function(_self: any)
					if callbacks[key] == fn then
						callbacks[key] = nil
						revision += 1
					end
				end,
			}
		end,
		applyLook = function(model: Instance, def: any, mutation: string?)
			local variant = if def and def.companions then def.companions.look else nil
			local applied: { [string]: boolean } = {}
			for _, key in { variant or "", mutation or "" } do
				local callback = callbacks[key]
				if callback and not applied[key] then
					applied[key] = true
					invoke(callback, model, def)
				end
			end
		end,
	}
end
return { new = new }
