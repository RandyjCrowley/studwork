local Receipt = require(script.Parent.Receipt)

-- In-memory fake of one server + one profile.
local function world(opts: any?)
	opts = opts or {}
	local w = {
		inFlight = {},
		present = if opts.present == nil then true else opts.present,
		loaded = if opts.loaded == nil then true else opts.loaded,
		purchases = {},
		handlerRuns = 0,
		saveResults = opts.saveResults or { true },
		saves = 0,
		handlerResult = if opts.handlerResult == nil then true else opts.handlerResult,
		handlerErrors = opts.handlerErrors == true,
		noHandler = opts.noHandler == true,
	}
	local player = { UserId = 1 }
	function w.deps()
		return {
			inFlight = w.inFlight,
			findPlayer = function(id: number)
				return if w.present and id == 1 then player else nil
			end,
			isLoaded = function()
				return w.loaded
			end,
			isRecorded = function(_, pid: string)
				return w.purchases[pid] ~= nil
			end,
			handler = if w.noHandler
				then nil
				else function()
					w.handlerRuns += 1
					if w.handlerErrors then
						error("boom")
					end
					return w.handlerResult
				end,
			record = function(_, pid: string)
				w.purchases[pid] = 123
				return true
			end,
			save = function()
				w.saves += 1
				local r = w.saveResults[math.min(w.saves, #w.saveResults)]
				return r
			end,
		}
	end
	return w
end

local function receipt(pid: string?)
	return {
		PlayerId = 1,
		PurchaseId = pid or "p1",
		ProductId = 42,
		CurrencySpent = 10,
		PlaceIdWherePurchased = 1,
	}
end

describe("Shop.Receipt.process", function()
	it("grants the first time: handler once, recorded, saved", function()
		local w = world()
		local r = Receipt.process(receipt(), w.deps())
		expect(r.decision).toBe("PurchaseGranted")
		expect(r.reason).toBe("granted")
		expect(r.granted).toBe(true)
		expect(w.handlerRuns).toBe(1)
		expect(w.purchases.p1).toBe(123)
		expect(w.saves).toBe(1)
	end)

	it("duplicate PurchaseId grants without re-running the handler", function()
		local w = world()
		Receipt.process(receipt(), w.deps())
		local r = Receipt.process(receipt(), w.deps())
		expect(r.decision).toBe("PurchaseGranted")
		expect(r.reason).toBe("duplicate")
		expect(r.granted).toBe(false)
		expect(w.handlerRuns).toBe(1)
	end)

	it("failed save -> NotProcessedYet, retry grants without re-running the handler", function()
		local w = world({ saveResults = { false, true } })
		local r1 = Receipt.process(receipt(), w.deps())
		expect(r1.decision).toBe("NotProcessedYet")
		expect(r1.reason).toBe("save_failed")
		expect(r1.granted).toBe(true)
		expect(w.purchases.p1).toBe(123) -- recorded before the save attempt
		local r2 = Receipt.process(receipt(), w.deps())
		expect(r2.decision).toBe("PurchaseGranted")
		expect(r2.reason).toBe("duplicate")
		expect(w.handlerRuns).toBe(1)
	end)

	it("a save that errors counts as failed", function()
		local w = world()
		local deps = w.deps()
		deps.save = function()
			error("datastore down")
		end
		local r = Receipt.process(receipt(), deps)
		expect(r.decision).toBe("NotProcessedYet")
		expect(r.reason).toBe("save_failed")
	end)

	it("unknown product (no handler) -> NotProcessedYet, nothing recorded", function()
		local w = world({ noHandler = true })
		local r = Receipt.process(receipt(), w.deps())
		expect(r.decision).toBe("NotProcessedYet")
		expect(r.reason).toBe("no_handler")
		expect(w.purchases.p1).toBeNil()
	end)

	it("handler returning false -> NotProcessedYet, not recorded, retried later", function()
		local w = world({ handlerResult = false })
		local r = Receipt.process(receipt(), w.deps())
		expect(r.decision).toBe("NotProcessedYet")
		expect(r.reason).toBe("handler_declined")
		expect(w.purchases.p1).toBeNil()
		expect(w.saves).toBe(0)
	end)

	it("handler erroring -> NotProcessedYet", function()
		local w = world({ handlerErrors = true })
		local r = Receipt.process(receipt(), w.deps())
		expect(r.decision).toBe("NotProcessedYet")
		expect(r.reason).toBe("handler_error")
		expect(w.purchases.p1).toBeNil()
	end)

	it("player not in server / data not loaded -> NotProcessedYet without running the handler", function()
		local w1 = world({ present = false })
		expect(Receipt.process(receipt(), w1.deps()).reason).toBe("not_in_server")
		local w2 = world({ loaded = false })
		expect(Receipt.process(receipt(), w2.deps()).reason).toBe("not_loaded")
		expect(w1.handlerRuns + w2.handlerRuns).toBe(0)
	end)

	it("the same PurchaseId being processed concurrently is refused", function()
		local w = world()
		w.inFlight.p1 = true
		local r = Receipt.process(receipt(), w.deps())
		expect(r.reason).toBe("in_flight")
		expect(w.handlerRuns).toBe(0)
		-- the in-flight flag is cleared after a normal run
		local w2 = world()
		Receipt.process(receipt("p2"), w2.deps())
		expect(w2.inFlight.p2).toBeNil()
	end)

	it("rejects malformed receipts", function()
		local w = world()
		expect(Receipt.process({ PlayerId = 1 }, w.deps()).reason).toBe("bad_receipt")
		expect(Receipt.process(nil, w.deps()).reason).toBe("bad_receipt")
	end)
end)
