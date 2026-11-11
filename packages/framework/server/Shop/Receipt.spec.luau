local Receipt = require(script.Parent.Receipt)

local function deepCopy(v: any): any
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, x in v do
		out[k] = deepCopy(x)
	end
	return out
end

-- Minimal all-or-nothing transaction with the framework Data rules that Receipt.commit relies
-- on (work on a copy, commit only on success, an error discards and re-raises, a yield is
-- refused, no nesting). The real one is framework Data.runTx, exercised by test/Shop.spec.luau.
local Transaction = {}
function Transaction.newState()
	return { running = false }
end
function Transaction.run(state, memory, fn)
	if state.running then
		error("nested Data.update", 0)
	end
	state.running = true
	local work = deepCopy(memory)
	local co = coroutine.create(fn)
	local ok, err = coroutine.resume(co, work)
	state.running = false
	if not ok then
		error(err, 0)
	end
	if coroutine.status(co) ~= "dead" then
		error("fn must not yield (change discarded)", 0)
	end
	for k in table.clone(memory) do
		memory[k] = nil
	end
	for k, v in work do
		memory[k] = v
	end
end

local function buildTx(_player, _receipt, _data, queue, control)
	return {
		after = function(fn)
			table.insert(queue, fn)
		end,
		retryLater = function(reason)
			control.retry = true
			control.reason = reason
			error("retry", 0)
		end,
	}
end

--[[
	Fake world: one DataStore (persisted) + one server session (memory) for player 1.
	update = the local Transaction above (all-or-nothing, rejects yields, nested errors).
	The default handler grants 1 coin and queues one effect.
]]
local function world(opts: any?)
	opts = opts or {}
	local w: any = {
		persisted = { currency = { coins = 0 }, purchases = {} },
		inFlight = {},
		pending = {},
		effectsRun = 0,
		handlerRuns = 0,
		saveResults = opts.saveResults or {},
		saves = 0,
		present = true,
		noHandler = opts.noHandler == true,
	}
	local player = { UserId = 1 }
	function w.startSession()
		w.memory = deepCopy(w.persisted)
		w.tx = Transaction.newState()
		w.loaded = true
	end
	function w.crash() -- server dies: memory and parked effects are gone, nothing saved
		w.loaded = false
		w.memory = nil
		w.inFlight = {}
		w.pending = {}
	end
	function w.leave() -- player leaves: ProfileStore's final save writes memory
		w.persisted = deepCopy(w.memory)
		Receipt.forgetPlayer(w.pending, 1)
		w.loaded = false
		w.memory = nil
	end
	w.handler = opts.handler
		or function(data, _receipt, tx)
			w.handlerRuns += 1
			data.currency.coins += 1
			tx.after(function()
				w.effectsRun += 1
			end)
		end
	local function update(_p, fn)
		if not w.loaded then
			return false
		end
		Transaction.run(w.tx, w.memory, fn)
		return true
	end
	w.update = update
	function w.deps()
		return {
			inFlight = w.inFlight,
			pending = w.pending,
			findPlayer = function(id)
				return if w.present and id == 1 then player else nil
			end,
			isLoaded = function()
				return w.loaded == true
			end,
			isRecorded = function(_, pid)
				return w.memory ~= nil and w.memory.purchases[pid] ~= nil
			end,
			hasHandler = not w.noHandler,
			commit = function(p, r)
				return Receipt.commit(update, w.handler, buildTx, p, r, 123)
			end,
			save = function()
				w.saves += 1
				local r = w.saveResults[w.saves]
				if r == nil then
					r = true
				end
				if r == "error" then
					error("datastore down")
				end
				if r == true then
					w.persisted = deepCopy(w.memory)
				end
				return r
			end,
		}
	end
	function w.process(pid: string?)
		local res = Receipt.process(
			{ PlayerId = 1, PurchaseId = pid or "p1", ProductId = 42, CurrencySpent = 10 },
			w.deps()
		)
		if res.effects then
			for _, fn in res.effects do
				fn()
			end
		end
		return res
	end
	w.startSession()
	return w
end

describe("Shop.Receipt.process", function()
	it("grants the first time: handler once, recorded, saved, effects once", function()
		local w = world()
		local r = w.process()
		expect(r.decision).toBe("PurchaseGranted")
		expect(r.reason).toBe("granted")
		expect(w.handlerRuns).toBe(1)
		expect(w.persisted.purchases.p1).toBe(123)
		expect(w.persisted.currency.coins).toBe(1)
		expect(w.effectsRun).toBe(1)
	end)

	it("duplicate PurchaseId grants without re-running the handler or effects", function()
		local w = world()
		w.process()
		local r = w.process()
		expect(r.decision).toBe("PurchaseGranted")
		expect(r.reason).toBe("duplicate")
		expect(r.effects).toBeNil()
		expect(w.handlerRuns).toBe(1)
		expect(w.effectsRun).toBe(1)
	end)

	it("failed save -> NotProcessedYet; retry is a duplicate that saves and runs effects once", function()
		local w = world({ saveResults = { false } })
		local r1 = w.process()
		expect(r1.decision).toBe("NotProcessedYet")
		expect(r1.reason).toBe("save_failed")
		expect(w.memory.purchases.p1).toBe(123) -- record stays in memory
		expect(w.persisted.purchases.p1).toBeNil()
		expect(w.effectsRun).toBe(0)
		local r2 = w.process()
		expect(r2.decision).toBe("PurchaseGranted")
		expect(r2.reason).toBe("duplicate")
		expect(w.handlerRuns).toBe(1)
		expect(w.effectsRun).toBe(1)
		expect(w.persisted.currency.coins).toBe(1)
		expect(w.process().effects).toBeNil()
		expect(w.effectsRun).toBe(1)
	end)

	it("retry of an unsaved duplicate whose save fails again stays NotProcessedYet", function()
		local w = world({ saveResults = { false, "error", true } })
		expect(w.process().reason).toBe("save_failed")
		expect(w.process().reason).toBe("save_failed")
		expect(w.effectsRun).toBe(0)
		expect(w.process().decision).toBe("PurchaseGranted")
		expect(w.effectsRun).toBe(1)
		expect(w.handlerRuns).toBe(1)
	end)

	it("crash after the in-memory commit but before the save: exactly one grant overall", function()
		local w = world({ saveResults = { false } })
		expect(w.process().reason).toBe("save_failed")
		w.crash()
		expect(w.persisted.purchases.p1).toBeNil()
		expect(w.persisted.currency.coins).toBe(0)
		w.startSession() -- next server
		local r = w.process()
		expect(r.reason).toBe("granted")
		expect(w.handlerRuns).toBe(2) -- the first run never persisted
		expect(w.persisted.currency.coins).toBe(1)
		expect(w.effectsRun).toBe(1)
		expect(w.process().reason).toBe("duplicate")
		expect(w.persisted.currency.coins).toBe(1)
	end)

	it("handler error -> no grant, no record; a later retry works", function()
		local fail = true
		local w
		w = world({
			handler = function(data, _r, tx)
				data.currency.coins += 1
				tx.after(function()
					w.effectsRun += 1
				end)
				if fail then
					error("boom")
				end
			end,
		})
		local r1 = w.process()
		expect(r1.decision).toBe("NotProcessedYet")
		expect(r1.reason).toBe("handler_error")
		expect(r1.detail).toContain("boom")
		expect(w.memory.currency.coins).toBe(0)
		expect(w.memory.purchases.p1).toBeNil()
		expect(w.saves).toBe(0)
		expect(w.effectsRun).toBe(0)
		fail = false
		expect(w.process().reason).toBe("granted")
		expect(w.persisted.currency.coins).toBe(1)
		expect(w.effectsRun).toBe(1)
	end)

	it("handler that yields is rejected, nothing committed", function()
		local w = world({
			handler = function(data)
				data.currency.coins += 1
				coroutine.yield()
			end,
		})
		local r = w.process()
		expect(r.decision).toBe("NotProcessedYet")
		expect(r.reason).toBe("handler_yielded")
		expect(w.memory.currency.coins).toBe(0)
		expect(w.memory.purchases.p1).toBeNil()
		expect(w.tx.running).toBe(false)
	end)

	it("retryLater -> nothing committed, retry_later, even if the handler swallows the raise", function()
		local w = world({
			handler = function(data, _r, tx)
				data.currency.coins += 1
				tx.after(function() end)
				tx.retryLater("policy_unknown")
			end,
		})
		local r = w.process()
		expect(r.reason).toBe("retry_later")
		expect(r.detail).toBe("policy_unknown")
		expect(w.memory.purchases.p1).toBeNil()
		local w2 = world({
			handler = function(data, _r, tx)
				pcall(tx.retryLater)
				data.currency.coins += 1
			end,
		})
		expect(w2.process().reason).toBe("retry_later")
		expect(w2.memory.currency.coins).toBe(0)
		expect(w2.memory.purchases.p1).toBeNil()
	end)

	it("a handler calling Data.update for the same player fails (nested) and commits nothing", function()
		local w
		w = world({
			handler = function(data)
				data.currency.coins += 1
				w.update(nil, function(d)
					d.currency.coins += 100
				end)
			end,
		})
		local r = w.process()
		expect(r.reason).toBe("handler_error")
		expect(r.detail).toContain("nested Data.update")
		expect(w.memory.currency.coins).toBe(0)
	end)

	it("concurrent in-flight receipt with the same id is refused while the first saves", function()
		local w = world()
		local inner
		local deps = w.deps()
		local baseSave = deps.save
		deps.save = function(p)
			inner = Receipt.process({ PlayerId = 1, PurchaseId = "p1", ProductId = 42 }, deps)
			return baseSave(p)
		end
		local r = Receipt.process({ PlayerId = 1, PurchaseId = "p1", ProductId = 42 }, deps)
		expect(inner.reason).toBe("in_flight")
		expect(r.reason).toBe("granted")
		expect(w.handlerRuns).toBe(1)
		expect(w.inFlight.p1).toBeNil()
	end)

	it("unknown product / not in server / not loaded -> NotProcessedYet, handler not run", function()
		local w = world({ noHandler = true })
		expect(w.process().reason).toBe("no_handler")
		local w1 = world()
		w1.present = false
		expect(w1.process().reason).toBe("not_in_server")
		local w2 = world()
		w2.loaded = false
		expect(w2.process().reason).toBe("not_loaded")
		expect(w.handlerRuns + w1.handlerRuns + w2.handlerRuns).toBe(0)
	end)

	it("data unloaded between the checks and the commit -> not_loaded", function()
		local w = world()
		local deps = w.deps()
		deps.isLoaded = function()
			return true
		end
		w.loaded = false
		w.memory = { purchases = {} }
		local r = Receipt.process({ PlayerId = 1, PurchaseId = "p1", ProductId = 42 }, deps)
		expect(r.reason).toBe("not_loaded")
	end)

	it("rejects malformed receipts", function()
		local w = world()
		expect(Receipt.process({ PlayerId = 1 }, w.deps()).reason).toBe("bad_receipt")
		expect(Receipt.process(nil, w.deps()).reason).toBe("bad_receipt")
	end)

	it("property: random process/save-fail/crash/leave sequences never double grant", function()
		local rng = Random and Random.new and Random.new(1) or nil
		local seed = 12345
		local function rand(n: number): number
			if rng then
				return rng:NextInteger(1, n)
			end
			seed = (seed * 1103515245 + 12345) % 2147483648
			return seed % n + 1
		end
		for _ = 1, 300 do
			local results = {}
			local w = world({ saveResults = results })
			for i = 1, 40 do
				results[i] = if rand(3) == 1 then false else (if rand(10) == 1 then "error" else true)
			end
			for _ = 1, 25 do
				local e = rand(10)
				local pid = "p" .. rand(2)
				if not w.loaded then
					w.startSession()
				elseif e <= 7 then
					w.process(pid)
				elseif e == 8 then
					w.crash()
				else
					w.leave()
				end
				-- invariants on the persisted store: each grant has its record and vice versa
				local records = 0
				for _ in w.persisted.purchases do
					records += 1
				end
				expect(w.persisted.currency.coins).toBe(records)
				expect(records <= 2).toBe(true)
				expect(w.effectsRun <= w.handlerRuns).toBe(true)
			end
			-- drain: everything eventually granted exactly once per id
			if not w.loaded then
				w.startSession()
			end
			for i = 1, 40 do
				results[i] = true
			end
			w.saves = 0
			w.process("p1")
			w.process("p2")
			expect(w.persisted.purchases.p1 ~= nil).toBe(true)
			expect(w.persisted.purchases.p2 ~= nil).toBe(true)
			expect(w.persisted.currency.coins).toBe(2)
			expect(w.effectsRun <= 2).toBe(true)
		end
	end)
end)

describe("Receipt.forgetPlayer (N9)", function()
	it("returns the dropped entries of that player only, with the amount spent", function()
		local pending = {
			a = { userId = 1, effects = {}, currencySpent = 49 },
			b = { userId = 2, effects = {} },
			c = { userId = 1, effects = {} },
		}
		local dropped = Receipt.forgetPlayer(pending, 1)
		expect(#dropped).toBe(2)
		local spent = 0
		for _, p in dropped do
			spent += p.currencySpent or 0
		end
		expect(spent).toBe(49)
		expect(pending.a).toBe(nil)
		expect(pending.c).toBe(nil)
		expect(pending.b ~= nil).toBe(true)
		expect(#Receipt.forgetPlayer(pending, 1)).toBe(0)
	end)

	it("a save failure parks the amount spent with the effects", function()
		local pending: { [string]: any } = {}
		local res = Receipt.process({ PurchaseId = "p", PlayerId = 1, ProductId = 5, CurrencySpent = 25 }, {
			inFlight = {},
			pending = pending,
			findPlayer = function()
				return {}
			end,
			isLoaded = function()
				return true
			end,
			isRecorded = function()
				return false
			end,
			hasHandler = true,
			commit = function()
				return "committed", {}, nil
			end,
			save = function()
				return false
			end,
		})
		expect(res.reason).toBe("save_failed")
		expect(pending.p.currencySpent).toBe(25)
	end)
end)

-- v1.6.0 purchase bridge (adopting.md §4.2, §4.3): the pure flow with the legacy deps.
local function legacyWorld(opts: any?)
	opts = opts or {}
	local w = world(opts)
	w.checks = 0
	w.oldStore = opts.oldStore or {}
	w.checkResult = nil -- forced result ("error") or nil = look in oldStore
	local base = w.deps
	function w.deps()
		local d = base()
		d.isRecorded = function(_, pid)
			return w.memory ~= nil
				and (w.memory.purchases[pid] ~= nil or (w.memory.legacyPurchases or {})[pid] ~= nil)
		end
		d.legacyCheck = function(_, pid)
			w.checks += 1
			if w.checkResult == "raise" then
				error("old store down")
			end
			if w.checkResult then
				return w.checkResult, "injected"
			end
			return if w.oldStore[pid] ~= nil then "found" else "none"
		end
		d.recordLegacy = function(p, pid)
			return w.update(p, function(data)
				data.legacyPurchases = data.legacyPurchases or {}
				data.legacyPurchases[pid] = 77
			end)
		end
		if opts.oldHandler then
			d.commit = function(p, r)
				return Receipt.legacyCommit(w.update, opts.oldHandler, p, r, 123)
			end
		end
		return d
	end
	return w
end

describe("Shop.Receipt.process: legacy history check (v1.6.0)", function()
	it("an id the old store has -> legacy_duplicate, handler never runs, record saved", function()
		local w = legacyWorld({ oldStore = { p1 = true } })
		local r = w.process()
		expect(r.decision).toBe("PurchaseGranted")
		expect(r.reason).toBe("legacy_duplicate")
		expect(r.effects).toBeNil()
		expect(w.handlerRuns).toBe(0)
		expect(w.persisted.legacyPurchases.p1).toBe(77)
		expect(w.persisted.currency.coins).toBe(0)
		local again = w.process()
		expect(again.reason).toBe("duplicate")
		expect(w.checks).toBe(1)
	end)

	it("legacy record whose save fails -> NotProcessedYet, retry saves, no effects, no grant", function()
		local w = legacyWorld({ oldStore = { p1 = true }, saveResults = { false } })
		local r1 = w.process()
		expect(r1.decision).toBe("NotProcessedYet")
		expect(r1.reason).toBe("save_failed")
		expect(w.pending.p1.kind).toBe("legacy_duplicate")
		local r2 = w.process()
		expect(r2.decision).toBe("PurchaseGranted")
		expect(r2.reason).toBe("legacy_duplicate")
		expect(r2.effects).toBeNil()
		expect(w.checks).toBe(1)
		expect(w.handlerRuns).toBe(0)
		expect(w.effectsRun).toBe(0)
		expect(w.persisted.legacyPurchases.p1).toBe(77)
	end)

	it(
		"a failed old-store read -> NotProcessedYet legacy_check_failed, nothing written; then a normal grant",
		function()
			local w = legacyWorld()
			w.checkResult = "error"
			local r = w.process()
			expect(r.decision).toBe("NotProcessedYet")
			expect(r.reason).toBe("legacy_check_failed")
			w.checkResult = "raise"
			expect(w.process().reason).toBe("legacy_check_failed")
			expect(w.handlerRuns).toBe(0)
			expect(w.saves).toBe(0)
			w.checkResult = nil
			expect(w.process().reason).toBe("granted")
			expect(w.process().reason).toBe("duplicate")
			expect(w.handlerRuns).toBe(1)
			expect(w.effectsRun).toBe(1)
		end
	)

	it("skip and none run the normal flow; an unknown check result refuses", function()
		local w = legacyWorld()
		w.checkResult = "skip"
		expect(w.process("s1").reason).toBe("granted")
		w.checkResult = "maybe"
		expect(w.process("s2").reason).toBe("legacy_check_failed")
		expect(w.handlerRuns).toBe(1)
	end)

	it("data unloaded during the check -> not_loaded, nothing recorded", function()
		local w = legacyWorld({ oldStore = { p1 = true } })
		local d = w.deps()
		local check = d.legacyCheck
		d.legacyCheck = function(...)
			w.loaded = false
			return check(...)
		end
		local r = Receipt.process({ PlayerId = 1, PurchaseId = "p1", ProductId = 42 }, d)
		expect(r.decision).toBe("NotProcessedYet")
		expect(r.reason).toBe("not_loaded")
		expect(w.memory.legacyPurchases).toBeNil()
	end)
end)

describe("Receipt.legacyCommit (v1.6.0 onLegacyProduct)", function()
	it("old handler runs once across a failed save + redelivery; only PurchaseGranted records", function()
		local runs = 0
		local w = legacyWorld({
			saveResults = { false },
			oldHandler = function(receipt, player)
				runs += 1
				expect(receipt.PurchaseId).toBe("p1")
				expect(player.UserId).toBe(1)
				return "PurchaseGranted"
			end,
		})
		expect(w.process().reason).toBe("save_failed")
		expect(w.memory.purchases.p1).toBe(123)
		local r = w.process()
		expect(r.decision).toBe("PurchaseGranted")
		expect(r.reason).toBe("duplicate")
		expect(runs).toBe(1)
		expect(w.persisted.purchases.p1).toBe(123)
	end)

	it("NotProcessedYet / error / non-string -> legacy_not_granted, nothing written", function()
		for _, answer in { "NotProcessedYet", 1, "raise" } do
			local w = legacyWorld({
				oldHandler = function()
					if answer == "raise" then
						error("old boom")
					end
					return answer
				end,
			})
			local r = w.process()
			expect(r.decision).toBe("NotProcessedYet")
			expect(r.reason).toBe("legacy_not_granted")
			expect(w.memory.purchases.p1).toBeNil()
			expect(w.saves).toBe(0)
		end
	end)

	it("the old handler may yield (it runs outside the transaction)", function()
		local w = legacyWorld()
		local co = coroutine.create(function()
			return Receipt.legacyCommit(w.update, function()
				coroutine.yield("waiting on the old DataStore")
				return "PurchaseGranted"
			end, { UserId = 1 }, { PurchaseId = "y1" }, 5)
		end)
		local ok1, first = coroutine.resume(co)
		expect(ok1).toBe(true)
		expect(first).toBe("waiting on the old DataStore")
		expect(w.memory.purchases.y1).toBeNil()
		local ok2, status = coroutine.resume(co)
		expect(ok2).toBe(true)
		expect(status).toBe("committed")
		expect(w.memory.purchases.y1).toBe(5)
		expect(w.tx.running).toBe(false)
	end)
end)
