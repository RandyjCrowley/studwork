--[[
	core-v1.3.1 R22: Data.saveAsync -> Store.saveNow replaces root._framework (copy-on-write, to
	stamp _framework.stats._saveSeq). It must bump the `_framework` section version so a cached
	`_framework` read view (Data.view, the incremental replication diff) is current right after
	the save. Real Data + real Store.profileStore + real ProfileStore on the sim's mock DataStore.
]]

local F = require(script.Parent.Fixtures)

describe("R22: saveNow bumps the _framework section version", function()
	it("a cached _framework view is current while saveNow waits and after it returns", function()
		local world = F.world()
		local s = F.server(world)
		local p = s:join(901)
		assert(
			world:advanceUntil(function()
				return s:isLoaded(p)
			end, 30),
			"loaded"
		)
		local data = s.runtime.data
		local before = data.sectionVersion(p, "_framework")
		local view0 = data.view(p, "_framework") -- caches the view at `before`
		local seq0 = (view0.stats or {})._saveSeq or 0
		local h = s:spawn(function()
			return s:save(p)
		end)
		-- saveNow stamped the new _saveSeq synchronously, before yielding on the write
		local during = data.sectionVersion(p, "_framework")
		expect(during > before).toBe(true)
		expect(data.view(p, "_framework").stats._saveSeq).toBe(seq0 + 1)
		assert(
			world:advanceUntil(function()
				return h.done
			end, 40),
			"saveAsync returned"
		)
		expect(h.result).toBe(true)
		expect(data.sectionVersion(p, "_framework") >= during).toBe(true)
		local view1 = data.view(p, "_framework")
		expect(view1.stats._saveSeq).toBe(seq0 + 1)
		expect(view1.stats._saveSeq).toBe(data.frameworkField(p, "stats")._saveSeq)
		expect(#world:errors()).toBe(0)
	end)
end)
