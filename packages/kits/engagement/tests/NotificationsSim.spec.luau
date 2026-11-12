--!nocheck
--[[
	Notifications across servers (the multi-server sim, mocked: the in-memory sorted maps and the Open
	Cloud fake are shared by every simulated server, on the World's clock). Real Notifications module,
	real framework: no duplicate send, a crashed claim holder, a retry carried to another server, a stuck
	head entry, the poll rate with many servers, and the memory-full degrade.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local F = require("packages/framework/test/sim/Fixtures.luau")

local SECRET = "OpenCloudNotifications"
local ALLOW = {
	[SECRET] = { modules = { "Notifications" }, methods = { "POST" }, paths = { "users/*/notifications" } },
}

local function world()
	return F.world({
		epoch = 19000 * 86400 + 12 * 3600,
		config = {
			modules = { "Items", "Economy", "Notifications" },
			config = {
				Notifications = {
					templates = { egg = { messageId = "1001", cooldownHours = 0 } },
					quiet = { startHour = 0, endHour = 0 },
					schedule = { shards = 1, pollSeconds = 1, leaseSeconds = 45, batch = 20 },
					limits = { perPlayerPerDay = 5, minGapHours = 0 },
				},
			},
		},
	})
end

-- opts.hold: seconds each request of THIS server takes (a request is in flight for that long)
local function boot(w, oc, opts)
	opts = opts or {}
	local transport = oc
	if opts.hold then
		transport = {
			hasSecret = oc.hasSecret,
			request = function(req)
				w.scheduler:wait(opts.hold)
				return oc.request(req)
			end,
		}
	end
	return F.server(w, {
		openCloud = transport,
		serverConfig = { openCloud = { secrets = ALLOW } },
		census = opts.census,
	})
end

local function fakeOc()
	return StudWork.test.fakes.openCloud({ secrets = { [SECRET] = true } })
end

local function ledger(w, userId)
	for _, e in w.memoryStores.sortedMap("SW/Notifications/ledger/0").entries() do
		if e.key == tostring(userId) then
			return e.value
		end
	end
	return nil
end

local function due(w)
	return w.memoryStores.sortedMap("SW/Notifications/due/0").entries()
end

local function ranges(w)
	local n = 0
	for _, c in w.memoryStores.sortedMap("SW/Notifications/due/0").calls do
		if c.op == "range" then
			n += 1
		end
	end
	return n
end

local function sentTo(oc, userId)
	local n = 0
	for _, r in oc.requests do
		if r.path == `users/{userId}/notifications` then
			n += 1
		end
	end
	return n
end

describe("Notifications across servers", function()
	it("two servers poll one due entry: exactly one send, counted once", function()
		local w = world()
		local oc = fakeOc()
		local a = boot(w, oc, { hold = 0.5 }) -- a request is in flight for half a second
		boot(w, oc, { hold = 0.5 })
		local now = w:now()
		expect(a:use("Notifications").schedule(7, "egg", now + 10)).toBe(true)
		w:advance(5)
		expect(#oc.requests).toBe(0)
		w:advance(60)
		expect(sentTo(oc, 7)).toBe(1)
		expect(#due(w)).toBe(0)
		local entry = ledger(w, 7)
		expect(entry.c).toBe(1)
		expect(entry.r).toBe(nil)
		expect(next(entry.q)).toBe(nil)
		w:advance(120)
		expect(sentTo(oc, 7)).toBe(1)
		expect(#w:errors()).toBe(0)
	end)

	it("a server that dies after its claim: the other sends once the lease has run out", function()
		local w = world()
		local oc = fakeOc()
		local a = boot(w, oc, { hold = 600 }) -- its request never finishes
		expect(a:use("Notifications").schedule(7, "egg", w:now() + 5)).toBe(true)
		w:advance(10)
		local claimed = due(w)[1]
		expect(claimed).never.toBe(nil)
		expect(claimed.sortKey > w:now()).toBe(true) -- claimed: out of the due window
		expect(ledger(w, 7).r).never.toBe(nil) -- and reserved
		a:crash()
		boot(w, oc)
		w:advance(30)
		expect(#oc.requests).toBe(0) -- still inside the lease
		w:advance(80)
		expect(sentTo(oc, 7)).toBe(1)
		expect(ledger(w, 7).c).toBe(1)
		expect(#due(w)).toBe(0)
		expect(#w:errors()).toBe(0)
	end)

	it(
		"a 5xx on one server, a 2xx on another: the attempt count is carried, the ledger counts once",
		function()
			local w = world()
			local oc = fakeOc()
			local a = boot(w, oc)
			boot(w, oc)
			oc.respondNext(503)
			a:use("Notifications").schedule(7, "egg", w:now() + 5)
			w:advance(8)
			expect(#oc.requests).toBe(1)
			local entry = due(w)[1]
			expect(entry.value.n).toBe(1)
			expect(ledger(w, 7).c).toBe(0)
			expect(ledger(w, 7).r).toBe(nil)
			w:advance(40) -- backoff 30 s
			expect(#oc.requests).toBe(2)
			expect(sentTo(oc, 7)).toBe(2) -- the failed one and the accepted one
			expect(ledger(w, 7).c).toBe(1)
			expect(#due(w)).toBe(0)
			w:advance(200)
			expect(#oc.requests).toBe(2)
		end
	)

	it("a stuck head entry doesn't block the entries behind it", function()
		local w = world()
		w.config.config.Notifications.schedule.batch = 1
		local oc = fakeOc()
		local a = boot(w, oc, { hold = 300 }) -- takes the head and never finishes
		local api = a:use("Notifications")
		api.schedule(1, "egg", w:now() + 5)
		api.schedule(2, "egg", w:now() + 6)
		w:advance(5.5)
		boot(w, oc)
		w:advance(30)
		expect(sentTo(oc, 1)).toBe(0) -- claimed by A, in flight
		expect(sentTo(oc, 2)).toBe(1) -- B read the entry behind the claimed head
	end)

	it(
		"with many servers each shard is read about pollsPerShardPerMinute, not once a server per interval",
		function()
			local w = world()
			w.config.config.Notifications.schedule =
				{ shards = 1, pollSeconds = 1, pollsPerShardPerMinute = 4 }
			local census = { servers = 8, players = 8 }
			local servers = {}
			for i = 1, 8 do
				servers[i] = boot(w, fakeOc(), { census = census })
			end
			local before = ranges(w)
			w:advance(600)
			local reads = ranges(w) - before
			-- 4 a minute for 10 minutes = 40 (each server polls every 60 x 8 / 4 = 120 s)
			expect(reads >= 32 and reads <= 48).toBe(true)
			local alone = world()
			alone.config.config.Notifications.schedule =
				{ shards = 1, pollSeconds = 1, pollsPerShardPerMinute = 4 }
			boot(alone, fakeOc())
			local beforeAlone = ranges(alone)
			alone:advance(600)
			expect(ranges(alone) - beforeAlone > 300).toBe(true) -- one server polls every pollSeconds
		end
	)

	it(
		"a full MemoryStore quota refuses the schedule with memory_budget; other modules' maps keep working",
		function()
			local w = world()
			local oc = fakeOc()
			local a = boot(w, oc)
			w.memoryStores.sortedMap("SW/Notifications/ledger/0").failNext(1, "TotalMemoryOverLimit")
			local ok, reason = a:use("Notifications").schedule(7, "egg", w:now() + 60)
			expect(ok).toBe(false)
			expect(reason).toBe("memory_budget")
			local other = a.runtime.sortedMapStore.forModule("Probe")("m")
			expect(other.set("k", { n = 1 }, 60, 1)).toBe(true)
			expect(a:use("Notifications").schedule(7, "egg", w:now() + 60)).toBe(true)
		end
	)

	it("a send to a recipient on no server works, and a second server doesn't repeat it", function()
		local w = world()
		local oc = fakeOc()
		local a = boot(w, oc)
		local b = boot(w, oc)
		expect(a:use("Notifications").send(42, "egg")).toBe(true)
		expect(sentTo(oc, 42)).toBe(1)
		-- the other server sees the same ledger: the 24 h limit... egg has no cooldown, but the day count is shared
		w.config.config.Notifications.limits.perPlayerPerDay = 1
		expect(ledger(w, 42).c).toBe(1)
		expect(b:use("Notifications").send(42, "egg")).toBe(true) -- b's config allows 5 a day
		expect(sentTo(oc, 42)).toBe(2)
		expect(ledger(w, 42).c).toBe(2)
	end)
end)

describe("Notifications in the sandbox game", function()
	it(
		"`sandbox egg` schedules eggReady; the placeholder template sends nothing and the entry clears",
		function()
			local w = F.world({ epoch = 19000 * 86400 + 12 * 3600 })
			local oc = fakeOc()
			local s =
				F.gameServer(w, "examples/sandbox/default.project.json", { isStudio = true, openCloud = oc })
			local p = s:join(1)
			assert(
				w:advanceUntil(function()
					return s:isLoaded(p)
				end, 30),
				"loaded"
			)
			local function waiting()
				local n = 0
				for _, name in w.memoryStores.sortedMapNames() do
					if string.find(name, "SW/Notifications/due/", 1, true) then
						n += #w.memoryStores.sortedMap(name).entries()
					end
				end
				return n
			end
			local text = s.console("sandbox", "egg", "30")
			expect(string.find(text, "eggReady scheduled in 30s", 1, true) ~= nil).toBe(true)
			w:advance(1)
			expect(waiting()).toBe(1)
			w:advance(300) -- one shard a poll, a poll every 30 s: all 4 shards are read within 150 s
			expect(waiting()).toBe(0)
			expect(#oc.requests).toBe(0)
			expect(#w:errors()).toBe(0)
		end
	)
end)
