--!strict
--[[
	Pure developer-product receipt decision (no Roblox globals). OWNED BY AGENT A (M4).

	Every side effect is injected so the flow is testable and safe to run twice for one
	PurchaseId (Roblox retries NotProcessedYet receipts, possibly on another server):

	  1. malformed receipt                                 -> NotProcessedYet "bad_receipt"
	  2. PurchaseId being processed in this server        -> NotProcessedYet "in_flight"
	  3. player not in server                             -> NotProcessedYet "not_in_server"
	  4. data not loaded                                  -> NotProcessedYet "not_loaded"
	  5. purchases[PurchaseId] already in the data        -> PurchaseGranted "duplicate", handler
	     NOT run. If THIS server committed it and its save is still unconfirmed (deps.pending),
	     the save is retried first (fail -> NotProcessedYet "save_failed").
	  6. no handler for the product                       -> NotProcessedYet "no_handler"
	  7. deps.commit(player, receipt): the handler AND purchases[PurchaseId] = now in ONE
	     non-yielding Data.update. Status:
	       "committed"      -> continue (effects = the handler's tx.after queue)
	       "handler_error" | "handler_yielded" | "retry_later" | "not_loaded"
	                        -> NotProcessedYet with that reason; nothing was written
	  8. deps.save(player) ~= true (or errors)             -> NotProcessedYet "save_failed". The
	     record stays in memory and the effects are parked in deps.pending[PurchaseId]; the retry
	     hits step 5 and releases them once the save is confirmed.
	  9. -> PurchaseGranted "granted"

	`effects` in the result is non-nil exactly when the grant just became final (saved) in this
	call: the caller runs them plus grant feedback. So effects run once per real (persisted) grant
	and never for a declined/erroring handler. A crash between commit and save loses the
	in-memory commit AND the parked effects; the next server finds no record and runs the handler
	again, so overall there is exactly one persisted grant and one run of its effects.
]]

local Receipt = {}

export type Decision = "PurchaseGranted" | "NotProcessedYet"
export type CommitStatus = "committed" | "handler_error" | "handler_yielded" | "retry_later" | "not_loaded"

export type Pending = { userId: number, effects: { () -> () } }

export type Deps<P> = {
	inFlight: { [string]: boolean },
	pending: { [string]: Pending }, -- committed in memory, save not confirmed yet
	findPlayer: (userId: number) -> P?,
	isLoaded: (player: P) -> boolean,
	isRecorded: (player: P, purchaseId: string) -> boolean,
	hasHandler: boolean,
	commit: (player: P, receipt: any) -> (CommitStatus, { () -> () }?, string?),
	save: (player: P) -> boolean,
}

export type Result = {
	decision: Decision,
	reason: string,
	effects: { () -> () }?, -- run these (+ grant feedback) now: the grant just became final
	detail: string?, -- e.g. the handler's error message (for the warning)
}

local function result(decision: Decision, reason: string, effects: { () -> () }?, detail: string?): Result
	return { decision = decision, reason = reason, effects = effects, detail = detail }
end

local function trySave<P>(deps: Deps<P>, player: P): boolean
	local ok, saved = pcall(deps.save, player)
	return ok and saved == true
end

local function run<P>(receipt: any, deps: Deps<P>): Result
	local purchaseId: string = receipt.PurchaseId
	local player = deps.findPlayer(receipt.PlayerId)
	if player == nil then
		return result("NotProcessedYet", "not_in_server")
	end
	if not deps.isLoaded(player) then
		return result("NotProcessedYet", "not_loaded")
	end
	if deps.isRecorded(player, purchaseId) then
		local parked = deps.pending[purchaseId]
		if parked == nil then
			return result("PurchaseGranted", "duplicate") -- granted (and saved) earlier
		end
		if not trySave(deps, player) then
			return result("NotProcessedYet", "save_failed")
		end
		deps.pending[purchaseId] = nil
		return result("PurchaseGranted", "duplicate", parked.effects)
	end
	-- Not recorded: parked effects (if any) belong to a commit that never persisted.
	deps.pending[purchaseId] = nil
	if not deps.hasHandler then
		return result("NotProcessedYet", "no_handler")
	end
	local ok, status, effects, detail = pcall(deps.commit, player, receipt)
	if not ok then
		return result("NotProcessedYet", "handler_error", nil, tostring(status))
	end
	if status ~= "committed" then
		return result("NotProcessedYet", status, nil, detail)
	end
	local queue = effects or {}
	if not trySave(deps, player) then
		deps.pending[purchaseId] = { userId = receipt.PlayerId, effects = queue }
		return result("NotProcessedYet", "save_failed")
	end
	return result("PurchaseGranted", "granted", queue)
end

function Receipt.process<P>(receipt: any, deps: Deps<P>): Result
	local purchaseId = receipt and receipt.PurchaseId
	if type(purchaseId) ~= "string" or purchaseId == "" or type(receipt.PlayerId) ~= "number" then
		return result("NotProcessedYet", "bad_receipt")
	end
	if deps.inFlight[purchaseId] then
		return result("NotProcessedYet", "in_flight")
	end
	deps.inFlight[purchaseId] = true
	local ok, res = pcall(run, receipt, deps)
	deps.inFlight[purchaseId] = nil
	if not ok then
		return result("NotProcessedYet", "internal_error")
	end
	return res
end

-- Handed to buildTx: PurchaseTx.retryLater sets `retry` (then raises) so the abort survives a
-- handler that pcall-swallows the raise.
export type Control = { retry: boolean, reason: string?, handlerError: any, finished: boolean }

-- The commit step (deps.commit) for the real Shop: runs `handler` and records the PurchaseId in
-- ONE `update` (Data.update: non-yielding, all-or-nothing). Returns (status, effects, detail).
function Receipt.commit<P>(
	update: (player: P, fn: (data: any) -> ()) -> boolean,
	handler: (data: any, receipt: any, tx: any) -> (),
	buildTx: (
		player: P,
		receipt: any,
		data: any,
		queue: { () -> () },
		control: Control
	) -> any,
	player: P,
	receipt: any,
	now: number
): (CommitStatus, { () -> () }?, string?)
	local queue: { () -> () } = {}
	local control: Control = { retry = false, reason = nil, handlerError = nil, finished = false }
	local ok, res = pcall(update, player, function(data: any)
		local hok, herr = pcall(handler :: any, data, receipt, buildTx(player, receipt, data, queue, control))
		if control.retry then
			error("retry_later", 0) -- discard everything, even if the handler swallowed the raise
		end
		if not hok then
			control.handlerError = herr
			error(herr, 0)
		end
		data.purchases = data.purchases or {}
		data.purchases[receipt.PurchaseId] = now
		control.finished = true
	end)
	if control.retry then
		return "retry_later", nil, control.reason
	end
	if control.handlerError ~= nil then
		return "handler_error", nil, tostring(control.handlerError)
	end
	if not ok then
		if string.find(tostring(res), "must not yield", 1, true) then
			return "handler_yielded", nil, nil
		end
		return "handler_error", nil, tostring(res)
	end
	if res ~= true then
		return "not_loaded", nil, nil
	end
	return "committed", queue, nil
end

-- Drops the parked effects of a player who left (their save can't be confirmed here anymore).
function Receipt.forgetPlayer(pending: { [string]: Pending }, userId: number)
	for id, p in pending do
		if p.userId == userId then
			pending[id] = nil
		end
	end
end

return Receipt
