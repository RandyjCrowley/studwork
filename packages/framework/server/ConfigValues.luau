--!strict
-- Public server configuration snapshots. Modules own validation, caching and refresh cadence.
local ConfigValues = {}
function ConfigValues.new(services: any, assertUsable: (() -> ())?): any
	return table.freeze({
		snapshot = function(): any
			if assertUsable then
				assertUsable()
			end
			return services.configSnapshot()
		end,
	})
end
return ConfigValues
