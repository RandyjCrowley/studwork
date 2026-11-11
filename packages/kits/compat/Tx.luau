--!strict
--[[
	Data transaction helper. LEAD-OWNED (contract v1.1).

	Tx.run(ctx.services.Data, player, fn) opens ONE Data.update, hands fn a Context.Tx ({ player, data,
	after }) and, only when the update committed, runs the queued `after` effects in order.
	`*Into` functions (Economy.grantInto, Inventory.addInto, Rarity.rollInto) write only into
	tx.data and queue their signals/feedback/analytics with tx.after, so several of them can be
	combined atomically (Shop's receipt wrapper does exactly that, plus the receipt record).

	Returns (committed, result) where result is fn's return value. committed is false when the
	player isn't loaded. Errors in fn propagate (Data discards the writes, nothing runs).
]]

local Tx = {}

export type Tx = {
	player: Player,
	data: any,
	after: (fn: () -> ()) -> (),
}

function Tx.new(player: Player, data: any, queue: { () -> () }): Tx
	return {
		player = player,
		data = data,
		after = function(fn: () -> ())
			table.insert(queue, fn)
		end,
	}
end

-- Runs queued effects; one failing effect never stops the others (they are cosmetic/derived).
function Tx.flush(queue: { () -> () })
	for _, fn in queue do
		local ok, err = pcall(fn :: any)
		if not ok then
			warn("[Core] post-commit effect failed: " .. tostring(err))
		end
	end
end

function Tx.run<R>(dataService: any, player: Player, fn: (tx: Tx) -> R): (boolean, R?)
	local queue: { () -> () } = {}
	local result: R? = nil
	local committed = dataService.update(player, function(d)
		result = fn(Tx.new(player, d, queue))
	end)
	if committed then
		Tx.flush(queue)
	end
	return committed, result
end

return Tx
