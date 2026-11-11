--!nocheck
--[[
	tools/lune/MigrationRun: the sim side of tools/test-migration (StudWork v1.6.0, adopting.md §3).
	Not a spec file: tools/lune/test-migration.luau runs it through the test harness
	(Harness.runSpec) with the plan in the environment:
	  STUDWORK_MIGRATION_PLAN = JSON { project = "<dir>/default.project.json",
	                                   fixtures = { { name, module?, data } } }
	Every fixture boots the PROJECT's real game (its Config, game module and kit modules, like a
	game's Boot spec: StudWork.test.sim gameServer) with a StudWork.test.legacyStore seeded in the
	import's own source format, and runs checks 1-7 (MigrationCheck.luau documents the fixture).
]]

local luneRequire = (getmetatable(getfenv(1)) :: any).__index.require
local process = luneRequire("@lune/process")
local serde = luneRequire("@lune/serde")

local coreDir = process.env.STUDWORK_CORE_DIR
if coreDir == nil or coreDir == "" or coreDir == "./" then
	coreDir = "."
end
local function core(path: string): string
	return if coreDir == "." then path else coreDir .. "/" .. path
end

local F = require(core("packages/framework/test/sim/Fixtures.luau"))
local Legacy = require(core("packages/framework/server/Legacy.luau"))
local MigrationCheck = require(core("tools/lune/MigrationCheck.luau"))

local KICK_LEGACY =
	"We couldn't bring over your save from the previous version yet. Nothing was lost. Please rejoin in a minute."

local plan = serde.decode("json", process.env.STUDWORK_MIGRATION_PLAN or "{}")
local project = plan.project

local function fail(errs: { string }, what: string)
	if #errs > 0 then
		error(what .. ":\n        - " .. table.concat(errs, "\n        - "), 0)
	end
end

-- One World + one server of the project's game, reading `store` as its legacy store.
local function boot()
	local world = F.world()
	local store = Legacy.memory()
	store.now = function()
		return world:now()
	end
	local server = F.gameServer(world, project, { legacy = store })
	return world, server, store
end

local function importOf(server, fixture, module)
	local specs = server.runtime.data.legacyImportSpecs()
	local picked = {}
	for _, s in specs do
		if
			(fixture.data.import ~= nil and s.id == fixture.data.import)
			or (fixture.data.import == nil and module ~= nil and s.owner == module)
		then
			table.insert(picked, s)
		end
	end
	if #picked == 0 and fixture.data.import == nil and module == nil and #specs == 1 then
		picked = { specs[1] }
	end
	if #picked ~= 1 then
		local ids = {}
		for _, s in specs do
			table.insert(ids, `{s.id} ({s.owner})`)
		end
		error(
			`no single importLegacy for this fixture (import = {tostring(fixture.data.import)}, module = {tostring(
				module
			)}); registered: {if #ids == 0 then "none" else table.concat(ids, ", ")}`,
			0
		)
	end
	return picked[1]
end

local function seed(store, spec, userId, value, at)
	for _, op in MigrationCheck.seedOps(spec.source, userId, value, at) do
		if op.op == "set" then
			store.set(op.name, op.key, op.value, op.at, op.scope)
		else
			store.setOrdered(op.name, op.key, op.n, op.scope)
		end
	end
end

local function kickOf(server, userId)
	local last = nil
	for _, k in server.kicks do
		if k.userId == userId then
			last = k.message
		end
	end
	return last
end

-- -> player, loaded, kick message
local function join(world, server, userId)
	local kicksBefore = #server.kicks
	local p = server:join(userId)
	world:advanceUntil(function()
		return server:isLoaded(p) or #server.kicks > kicksBefore
	end, 120, 0.25)
	local loaded = server:isLoaded(p)
	local kick = if #server.kicks > kicksBefore then kickOf(server, userId) else nil
	return p, loaded, kick
end

local function leave(world, server, p)
	server:leave(p)
	world:advance(15)
end

local function saved(world, server, userId)
	local raw = world:peek("PlayerData_" .. server.config.gameId, "Player_" .. tostring(userId))
	return raw and raw.Data
end

local function noSections(s): boolean
	if type(s) ~= "table" then
		return true
	end
	for k in s do
		if k ~= "_framework" and k ~= "_versions" then
			return false
		end
	end
	return true
end

local function same(a, b, what)
	local d = MigrationCheck.diff(MigrationCheck.stable(a), MigrationCheck.stable(b))
	-- item instances carry per-import uids; the content check is check 1's job
	fail(d, what)
end

local OLD_AGE = 3600

for _, fixture in plan.fixtures or {} do
	local f = fixture.data
	local uid = f.userId or 1001
	describe(fixture.name .. (if f.description then " (" .. f.description .. ")" else ""), function()
		it("fixture is valid", function()
			fail(MigrationCheck.validate(f), "invalid fixture")
		end)
		if type(f.old) ~= "table" or type(f.expect) ~= "table" then
			return
		end

		it("1-2. nothing lost field by field; importing twice is safe", function()
			local world, server, store = boot()
			local spec = importOf(server, fixture, fixture.module)
			seed(store, spec, uid, f.old, world:now() - OLD_AGE)
			local p, loaded, kick = join(world, server, uid)
			assert(
				loaded,
				"the import failed: " .. tostring(kick) .. "\n" .. table.concat(world:errors(), "\n")
			)
			leave(world, server, p)
			local first = saved(world, server, uid)
			fail(MigrationCheck.compare(f.old, first, f), "fields lost or changed")
			local marker = first._framework.imports and first._framework.imports[spec.id]
			assert(marker and marker.found == true, "no import marker written")
			local p2, loaded2 = join(world, server, uid)
			assert(loaded2, "the rejoin failed")
			leave(world, server, p2)
			same(first, saved(world, server, uid), "a rejoin changed the save")
		end)

		it("3. a read failure kicks without changing data; the next join imports", function()
			local world, server, store = boot()
			local spec = importOf(server, fixture, fixture.module)
			seed(store, spec, uid, f.old, world:now() - OLD_AGE)
			store.failNext(Legacy.READ_ATTEMPTS)
			local p, loaded, kick = join(world, server, uid)
			assert(not loaded, "loaded although every read failed")
			assert(kick == KICK_LEGACY, "expected the legacy kick, got " .. tostring(kick))
			assert(noSections(saved(world, server, uid)), "a failed import wrote data")
			leave(world, server, p)
			local _, loaded2, kick2 = join(world, server, uid)
			assert(loaded2, "the next join didn't import: " .. tostring(kick2))
		end)

		it("4. a partial old save imports or fails closed, never a half import", function()
			local world, server, store = boot()
			local spec = importOf(server, fixture, fixture.module)
			local errs = {}
			local keys = {}
			for k in f.old do
				table.insert(keys, k)
			end
			table.sort(keys, function(a, b)
				return tostring(a) < tostring(b)
			end)
			for i, key in keys do
				local id = uid + 100 + i
				local partial = MigrationCheck.withoutField(f.old, key)
				seed(store, spec, id, partial, world:now() - OLD_AGE)
				local p, loaded, kick = join(world, server, id)
				if MigrationCheck.seedsNothing(spec.source, partial) then
					-- no source left at all: the "nothing found" outcome (a found = false marker)
					if not loaded then
						table.insert(
							errs,
							`without '{tostring(key)}' (no old save left): expected a fresh start, got kick '{tostring(
								kick
							)}'`
						)
						server:leave(p)
					else
						leave(world, server, p)
						local s = saved(world, server, id)
						local m = s and s._framework.imports and s._framework.imports[spec.id]
						if not (m and m.found == false) then
							table.insert(
								errs,
								`without '{tostring(key)}' (no old save left): expected a found = false marker, got {MigrationCheck.show(
									m
								)}`
							)
						end
					end
				elseif loaded then
					leave(world, server, p)
					local s = saved(world, server, id)
					local m = s and s._framework.imports and s._framework.imports[spec.id]
					if not (m and m.found == true) then
						table.insert(errs, `without '{tostring(key)}': loaded but no import marker`)
					end
				else
					if kick ~= KICK_LEGACY then
						table.insert(errs, `without '{tostring(key)}': kicked with '{tostring(kick)}'`)
					end
					if not noSections(saved(world, server, id)) then
						table.insert(
							errs,
							`without '{tostring(key)}': a failed import wrote data (half import)`
						)
					end
					server:leave(p)
				end
			end
			fail(errs, "partial saves")
		end)

		if f.changed ~= nil then
			it(
				"5. changed after import: merge runs once and is idempotent (or fails closed without merge)",
				function()
					local world, server, store = boot()
					local spec = importOf(server, fixture, fixture.module)
					seed(store, spec, uid, f.old, world:now() - OLD_AGE)
					local p, loaded = join(world, server, uid)
					assert(loaded, "the first import failed")
					leave(world, server, p)
					local before = saved(world, server, uid)
					world:advance(Legacy.QUIET_SECONDS + 60)
					seed(store, spec, uid, f.changed, world:now() - Legacy.QUIET_SECONDS - 1)
					local p2, loaded2, kick2 = join(world, server, uid)
					if not spec.hasMerge then
						assert(not loaded2, "no merge declared, but a changed old save loaded")
						assert(kick2 == KICK_LEGACY, "expected the legacy kick, got " .. tostring(kick2))
						same(before, saved(world, server, uid), "a failed merge changed the save")
						return
					end
					assert(loaded2, "the merge failed: " .. tostring(kick2))
					leave(world, server, p2)
					local merged = saved(world, server, uid)
					fail(MigrationCheck.afterMerge(merged, f), "afterMerge")
					local p3, loaded3 = join(world, server, uid)
					assert(loaded3, "the rejoin after the merge failed")
					leave(world, server, p3)
					same(
						merged,
						saved(world, server, uid),
						"merge is not idempotent (a second rejoin changed the save)"
					)
				end
			)
		end

		if f.overCap ~= nil then
			it("6. over the limits: every item above the Inventory cap arrives", function()
				local world, server, store = boot()
				local spec = importOf(server, fixture, fixture.module)
				local big, err = MigrationCheck.inflate(f.old, f.overCap.path, f.overCap.count)
				assert(err == nil, err)
				local target = MigrationCheck.itemsTarget(f)
				assert(target, "overCap.path needs an { items } entry in expect")
				seed(store, spec, uid, big, world:now() - OLD_AGE)
				local p, loaded, kick = join(world, server, uid)
				assert(loaded, "the over-cap import failed: " .. tostring(kick))
				leave(world, server, p)
				local n = MigrationCheck.itemCount(saved(world, server, uid), target)
				assert(n == f.overCap.count, `expected {f.overCap.count} items at {target}, got {n}`)
			end)
		end

		if f.sold ~= nil then
			it("7. sold fields stay paid", function()
				local _world, server = boot()
				local spec = importOf(server, fixture, fixture.module)
				local paid = server.runtime.compliance.forModule(spec.owner).paidCurrencies()
				for _, note in MigrationCheck.soldUnchecked(f) do
					print("        note: " .. note)
				end
				fail(MigrationCheck.checkSold(f, paid, spec.itemTag), "sold fields")
			end)
		end
	end)
end
