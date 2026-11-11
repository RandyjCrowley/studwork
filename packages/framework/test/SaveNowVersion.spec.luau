--!nocheck
--[[
	v1.3.1 R22: Store.saveNow replaces root._framework (copy-on-write, to stamp
	_framework.stats._saveSeq). Data must bump the `_framework` section version so a cached
	`_framework` read view (Data.view; replication diffs on section versions) is never one change
	behind. The fake store below does exactly what Store.profileStore.saveNow does to the root,
	minus ProfileStore (whose OnSave -> beforeSave bump hid the gap in the sim).
]]
local Harness = require(script.Parent.harness)
local Store = require(script.Parent.Parent.server.Store)

local function stampingStore(useHook: boolean)
	local store = Store.memory()
	local hooksOf = {}
	local seen = {}
	store.attach = function(userId, _root, hooks)
		hooksOf[userId] = hooks
	end
	store.saveNow = function(userId, root)
		local fw = table.clone(root._framework)
		fw.stats = if type(fw.stats) == "table" then table.clone(fw.stats) else {}
		fw.stats._saveSeq = (fw.stats._saveSeq or 0) + 1
		root._framework = fw
		local hooks = hooksOf[userId]
		if useHook and hooks and hooks.frameworkReplaced then
			hooks.frameworkReplaced()
		end
		if store.onStamped then
			store.onStamped(seen)
		end
		return true
	end
	return store, seen
end

describe("R22: saveNow bumps the _framework section version", function()
	it("Store's frameworkReplaced hook: the view is current while saveNow is still waiting", function()
		local store, seen = stampingStore(true)
		local h = Harness.new({ modules = {}, store = store })
		local p = h:addPlayer({ userId = 1 })
		local data = h.runtime.data
		local before = data.sectionVersion(p, "_framework")
		local seq0 = (data.view(p, "_framework").stats or {})._saveSeq or 0 -- cached view
		store.onStamped = function(out)
			out.version = data.sectionVersion(p, "_framework")
			out.seq = data.view(p, "_framework").stats._saveSeq
		end
		expect(data.saveAsync(p)).toBe(true)
		expect(seen.version > before).toBe(true)
		expect(seen.seq).toBe(seq0 + 1)
		expect(data.view(p, "_framework").stats._saveSeq).toBe(seq0 + 1)
	end)

	it("a store without the hook: saveAsync still bumps the version once saveNow returns", function()
		local store = stampingStore(false)
		local h = Harness.new({ modules = {}, store = store })
		local p = h:addPlayer({ userId = 2 })
		local data = h.runtime.data
		local before = data.sectionVersion(p, "_framework")
		local seq0 = (data.view(p, "_framework").stats or {})._saveSeq or 0
		expect(data.saveAsync(p)).toBe(true)
		expect(data.sectionVersion(p, "_framework") > before).toBe(true)
		expect(data.view(p, "_framework").stats._saveSeq).toBe(seq0 + 1)
		expect(data.view(p, "_framework").stats._saveSeq).toBe(data.frameworkField(p, "stats")._saveSeq)
	end)
end)
