--!strict
--[[
	Pure developer-product receipt decision (no Roblox globals). Owned by agent E.

	Implements the pinned receipt flow from the Phase 1 brief, with every side effect injected
	so it is testable and safe to run twice for the same PurchaseId:

	  1. PurchaseId already being processed in this server (inFlight) -> NotProcessedYet ("in_flight")
	  2. player not in server                      -> NotProcessedYet ("not_in_server")
	  3. data not loaded                           -> NotProcessedYet ("not_loaded")
	  4. receipt already recorded in profile data  -> PurchaseGranted ("duplicate"; handler NOT run)
	  5. no handler for the product                -> NotProcessedYet ("no_handler")
	  6. run handler (pcall): error -> NotProcessedYet ("handler_error"); ~= true -> ("handler_declined")
	  7. record purchases[PurchaseId] = now (Data.update) fails -> NotProcessedYet ("record_failed")
	  8. saveAsync() ~= true -> NotProcessedYet ("save_failed") -- the id stays recorded, so the
	     Roblox retry hits step 4 and is granted without running the handler again
	  9. -> PurchaseGranted ("granted")

	`granted` in the result is true when the handler ran successfully in THIS call (steps 8/9),
	so the caller sends feedback/signals exactly once per real grant.
]]

local Receipt = {}

export type Decision = "PurchaseGranted" | "NotProcessedYet"

export type Deps<P> = {
	inFlight: { [string]: boolean },
	findPlayer: (userId: number) -> P?,
	isLoaded: (player: P) -> boolean,
	isRecorded: (player: P, purchaseId: string) -> boolean,
	handler: ((player: P, receipt: any) -> boolean)?,
	record: (player: P, purchaseId: string) -> boolean,
	save: (player: P) -> boolean,
}

export type Result = { decision: Decision, reason: string, granted: boolean }

local function result(decision: Decision, reason: string, granted: boolean?): Result
	return { decision = decision, reason = reason, granted = granted == true }
end

local function run<P>(receipt: any, deps: Deps<P>): Result
	local player = deps.findPlayer(receipt.PlayerId)
	if player == nil then
		return result("NotProcessedYet", "not_in_server")
	end
	if not deps.isLoaded(player) then
		return result("NotProcessedYet", "not_loaded")
	end
	if deps.isRecorded(player, receipt.PurchaseId) then
		return result("PurchaseGranted", "duplicate")
	end
	local handler = deps.handler
	if handler == nil then
		return result("NotProcessedYet", "no_handler")
	end
	local ok, granted = pcall(handler, player, receipt)
	if not ok then
		return result("NotProcessedYet", "handler_error")
	end
	if granted ~= true then
		return result("NotProcessedYet", "handler_declined")
	end
	if not deps.record(player, receipt.PurchaseId) then
		return result("NotProcessedYet", "record_failed")
	end
	local saveOk, saved = pcall(deps.save, player)
	if not saveOk or saved ~= true then
		return result("NotProcessedYet", "save_failed", true)
	end
	return result("PurchaseGranted", "granted", true)
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

return Receipt
