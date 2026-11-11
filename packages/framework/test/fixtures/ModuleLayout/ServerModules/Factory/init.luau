--!nocheck
-- A part factory (new, no init/start): the loader builds a fresh part per call.
local Factory = {}
local built = 0
function Factory.new()
	built += 1
	return { api = {
		id = function()
			return built
		end,
	} }
end
return Factory
