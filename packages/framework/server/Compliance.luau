--!strict
--[[
	Framework Compliance (module-api.md §14): the odds-disclosure registry and the paid-roll rules,
	in the framework so EVERY random source is covered, built-in or third-party. Framework internal;
	modules see the scoped ctx.compliance.

	ctx.compliance
	  registerRandomSource(id, { odds = fn(player) -> OddsDetail, sample = fn(player, luck, tx) ->
	                       outcome?, luckDisclosed = boolean })
	      The source's owner is the registering module. `sample` is the actual randomness (the
	      weighted pick, pity included; it may write the OWNER's section through the tx it gets).
	      Nothing else may produce an outcome for a registered source (C2).
	  roll(tx, sourceId, luck?) -> (ok, outcome?, reason?)
	      Paid when tx is a purchase transaction (Shop), free otherwise. Paid: a restricted player
	      gets (false, nil, "restricted"); an unknown policy retries the purchase later
	      (tx.retryLater) and outside a purchase returns (false, nil, "policy_unknown").
	  spendForRoll(tx, currency, amount, sourceId, luck?) -> (ok, outcome?, reason?)
	      The ONLY way to spend a currency listed in GameConfig.compliance.paidCurrencies (C3): the
	      currency's owner registered a spender; the spend and the roll happen in the same tx, so
	      they commit together or not at all. Always paid. Insufficient funds -> (false, nil,
	      "insufficient"); an empty sample after the spend errors (the tx is discarded).
	  spendPaid(tx, currency, amount, reason) -> (ok, reason?)   (added in v1.3.0)
	      Spends a paid currency on a NON-random good (an upgrade level, a rebirth, any module's
	      shop item) through the registered spender. Any module may call it. Insufficient funds ->
	      (false, "insufficient"). Marks the tx: a later roll in the same tx is a PAID roll
	      (policy, disclosure and luck rules; "paidcur:<sourceId>" tag), and tagPaid(tx) returns
	      "paidcur:<currency>" until then. If that roll is refused, error to discard the spend.
	  registerCurrencySpender(currency, fn(tx, amount, reason) -> boolean)  (added in v1.3.0)
	      The currency module (Economy) hands Compliance its spend for a paid currency. One owner per
	      currency. Only Compliance calls it.
	  isPaidCurrency(currency) -> boolean, paidCurrencies() -> { string }   (added in v1.3.0)
	Boot rule (module-api.md §19.10, added in v1.3.1: R20): once every module has run init and
	start, every currency in GameConfig.compliance.paidCurrencies must have a registered spender;
	the runtime calls c.assertSpenders() and boot fails (closed) naming the first one that has none.
	  tagPaid(tx, reason?) -> string                                       (v1.3.0: takes the tx)
	  tagPaid(sourceId) -> "paidcur:<sourceId>"   §14's frozen form, for a registered source
	      "paid:<product>" inside a purchase, "paidcur:<sourceId>" after a spendForRoll in this tx,
	      otherwise `reason` (or "free") with any "paid:" / "paidcur:" prefix stripped — callers
	      can't choose the prefix.
	  disclose(player, sourceId?)   (re)send the player's odds (framework field `odds`)
	  disclosed(player, sourceId) -> OddsDetail?   what the client was last sent
	Item disclosures (added in v1.6.0, adopting.md §6.2): odds for ONE item (an egg) at its own luck.
	  registerRandomSource's optional `oddsAt = fn(player, luck) -> OddsDetail` (the source's odds at
	      exactly that luck, pure; its `luck` field is the luck the source's sanitizer produced).
	      A source without it can't use item disclosures (discloseItem errors).
	  discloseItem(player, sourceId, itemKey, luck) -> boolean   builds the detail from oddsAt and
	      sends it (framework field `itemOdds` = { [sourceId]: { [itemKey]: OddsDetail } }). At most
	      Compliance.MAX_ITEM_DISCLOSURES per player across sources: past that it returns false and
	      sends nothing (never evicts: a pending paid roll keeps its disclosure). Cleared when the
	      player leaves (the replication entry goes with them).
	  disclosedItem(player, sourceId, itemKey) -> OddsDetail?   what the client was last SENT
	  clearItem(player, sourceId, itemKey)                      drops it (the egg hatched)
	  roll(tx, sourceId, luck?, opts?) / spendForRoll(..., luck?, opts?), opts.item = itemKey:
	      free roll: a label only (any luck). Paid roll: the usual policy gate, then the item's
	      disclosure must have been sent (else "odds_not_disclosed", tx.retryLater in a purchase),
	      luck ~= 1 needs luckDisclosed (hard rule 11 error), and the disclosed `luck` must EQUAL the
	      roll's luck (else "odds_not_disclosed"). Luck rule: Compliance doesn't sanitize; the
	      calling module passes the luck already through the SAME sanitizer its oddsAt uses (Rarity:
	      RollMath.sanitizeLuck), so the comparison is exact.
	Legacy import (v1.6.0, contract 4): inside an import tx (txMeta.legacyImport = "paid" | "free",
	set only by Data) roll / spendForRoll / spendPaid error, and tagPaid(tx) returns "paid:legacy" /
	"legacy".
	Disclosure rule: a PAID roll on a source whose odds were never sent to the
	player's client is refused: "odds_not_disclosed" (inside a purchase also tx.retryLater).
	Luck rule (hard rule 11): a PAID roll with luck ~= 1 errors unless the source is luckDisclosed
	AND the odds last sent to this player's client carry exactly that luck.
	There is no opts.free (C3): a genuinely free reward is roll(tx, ...) outside a purchase with no
	paid currency involved.

	Compliance.new(opts): opts.data (framework Data: isTxHandle, txMeta), opts.policy,
	opts.replication (setFramework, sentFramework), opts.paidCurrencies { string },
	opts.canUse(caller, owner) -> boolean, opts.isPlayer, opts.log.
]]

local Compliance = {}

export type Source = {
	odds: (player: any) -> any,
	sample: (player: any, luck: number, tx: any) -> any,
	luckDisclosed: boolean,
	oddsAt: ((player: any, luck: number) -> any)?,
}

Compliance.MAX_ID_LENGTH = 64
Compliance.MAX_ITEM_DISCLOSURES = 64 -- per player, across every source (added in v1.6.0)

local LEGACY_ERROR = "ctx.compliance: no rolls or paid spends inside a legacy import"

local function isFinitePositive(n: any): boolean
	return type(n) == "number" and n == n and n > 0 and n < math.huge
end

function Compliance.new(opts: any): any
	local data = opts.data
	local policy = opts.policy
	local replication = opts.replication
	local log: (string) -> () = opts.log
	local paidList: { string } = table.clone(opts.paidCurrencies or {})
	local paidSet: { [string]: boolean } = {}
	for _, c in paidList do
		paidSet[c] = true
	end

	local sources: { [string]: { owner: string, source: Source } } = {}
	local order: { string } = {}
	local spenders: { [string]: { owner: string, fn: (any, number, string) -> boolean } } = {}

	local c: any = {}

	-- R20 (v1.3.1): a paid currency nobody can spend through Compliance is a config error,
	-- not a runtime surprise. Called by the server runtime after every module's init + start.
	function c.assertSpenders()
		for _, currency in paidList do
			if spenders[currency] == nil then
				error(
					`compliance.paidCurrencies lists '{currency}', but no enabled module registered a spender for it (ctx.compliance.registerCurrencySpender); enable the module that owns '{currency}' or remove it from the list`,
					0
				)
			end
		end
	end

	local function meta(tx: any): any
		if not data.isTxHandle(tx) then
			error("ctx.compliance: first argument must be the OPEN tx (ctx.tx / a purchase tx)", 3)
		end
		return data.txMeta(tx)
	end

	local function sourceFor(caller: string, sourceId: any): { owner: string, source: Source }
		local entry = if type(sourceId) == "string" then sources[sourceId] else nil
		if entry == nil then
			error(
				`ctx.compliance: unknown random source '{tostring(sourceId)}' (registerRandomSource first)`,
				3
			)
		end
		if entry.owner ~= caller and not opts.canUse(caller, entry.owner) then
			error(
				`ctx.compliance: {caller} can't roll '{sourceId}' (owned by {entry.owner}); declare {entry.owner} in dependsOn/optional or go through its API`,
				3
			)
		end
		return entry
	end

	function c.oddsFor(player: any, sourceId: string): any
		local entry = sources[sourceId]
		if entry == nil then
			return nil
		end
		local ok, detail = pcall(entry.source.odds, player)
		if not ok then
			log(`[StudWork.Compliance] odds('{sourceId}') failed: {tostring(detail)}`)
			return nil
		end
		return detail
	end

	function c.disclose(player: any, only: string?)
		if not opts.isPlayer(player) then
			return
		end
		local current = replication.peekFramework and replication.peekFramework(player, "odds") or nil
		local out: { [string]: any } = if type(current) == "table" then table.clone(current) else {}
		for _, id in order do
			if only == nil or only == id then
				out[id] = c.oddsFor(player, id)
			end
		end
		replication.setFramework(player, "odds", out)
	end

	function c.disclosed(player: any, sourceId: string): any
		local sent = replication.sentFramework(player, "odds")
		return if type(sent) == "table" then sent[sourceId] else nil
	end

	------------------------------------------------------------------ item disclosures (v1.6.0)

	local function isItemKey(k: any): boolean
		return type(k) == "string" and k ~= "" and #k <= Compliance.MAX_ID_LENGTH
	end

	-- a fresh copy of the itemOdds map queued for the player (two levels cloned) and its size
	local function itemMap(player: any): ({ [string]: any }, number)
		local current = replication.peekFramework and replication.peekFramework(player, "itemOdds") or nil
		local out: { [string]: any } = {}
		local count = 0
		if type(current) == "table" then
			for src, items in current do
				if type(items) == "table" then
					out[src] = table.clone(items)
					for _ in items do
						count += 1
					end
				end
			end
		end
		return out, count
	end

	function c.discloseItem(player: any, sourceId: string, itemKey: string, luck: number): boolean
		local entry = sources[sourceId]
		if entry == nil then
			error(`ctx.compliance.discloseItem: unknown random source '{tostring(sourceId)}'`, 3)
		end
		if type(entry.source.oddsAt) ~= "function" then
			error(
				`ctx.compliance.discloseItem: source '{sourceId}' has no oddsAt(player, luck); it can't use item disclosures`,
				3
			)
		end
		if not isItemKey(itemKey) then
			error("ctx.compliance.discloseItem: itemKey must be a short id string (<= 64 chars)", 3)
		end
		if not isFinitePositive(luck) then
			error("ctx.compliance.discloseItem: luck must be a finite number > 0", 3)
		end
		if not opts.isPlayer(player) then
			return false
		end
		local out, count = itemMap(player)
		local mine = out[sourceId]
		if (mine == nil or mine[itemKey] == nil) and count >= Compliance.MAX_ITEM_DISCLOSURES then
			return false -- bounded, never evicted
		end
		local ok, detail = pcall(entry.source.oddsAt :: any, player, luck)
		if not ok or type(detail) ~= "table" or not isFinitePositive(detail.luck) then
			log(`[StudWork.Compliance] oddsAt('{sourceId}') failed: {tostring(detail)}`)
			return false
		end
		local d = table.clone(detail)
		d.item = itemKey
		if mine == nil then
			mine = {}
			out[sourceId] = mine
		end
		mine[itemKey] = d
		replication.setFramework(player, "itemOdds", out)
		return true
	end

	function c.disclosedItem(player: any, sourceId: string, itemKey: string): any
		local sent = replication.sentFramework(player, "itemOdds")
		local mine = if type(sent) == "table" then sent[sourceId] else nil
		return if type(mine) == "table" then mine[itemKey] else nil
	end

	function c.clearItem(player: any, sourceId: string, itemKey: string)
		if not opts.isPlayer(player) then
			return
		end
		local out = itemMap(player)
		local mine = out[sourceId]
		if mine == nil or mine[itemKey] == nil then
			return
		end
		mine[itemKey] = nil
		if next(mine) == nil then
			out[sourceId] = nil
		end
		replication.setFramework(player, "itemOdds", out)
	end

	-- hard rule 11 + policy for a paid roll. Returns (ok, reason?).
	local function paidGate(
		tx: any,
		m: any,
		sourceId: string,
		entry: any,
		luck: number,
		item: string?
	): (boolean, string?)
		local player = tx.player
		if not policy.isKnown(player) then
			if m.purchase then
				tx.retryLater("policy_unknown")
			end
			return false, "policy_unknown"
		end
		if policy.paidRandomRestricted(player) then
			return false, "restricted"
		end
		if item ~= nil then
			-- a paid roll for ONE item: exactly that item's odds at exactly this luck were sent
			local shown = c.disclosedItem(player, sourceId, item)
			if type(shown) ~= "table" then
				if m.purchase then
					tx.retryLater("odds_not_disclosed")
				end
				return false, "odds_not_disclosed"
			end
			if luck ~= 1 and not entry.source.luckDisclosed then
				error(
					`paid roll on '{sourceId}' (item '{item}') with luck {luck} refused (hard rule 11): the source does not set luckDisclosed = true`,
					0
				)
			end
			if shown.luck ~= luck then
				if m.purchase then
					tx.retryLater("odds_not_disclosed")
				end
				return false, "odds_not_disclosed"
			end
			return true, nil
		end
		-- every paid roll, at any luck, needs the source's odds to have been sent
		-- to this player's client (replicated at join, before the player can buy)
		if type(c.disclosed(player, sourceId)) ~= "table" then
			if m.purchase then
				tx.retryLater("odds_not_disclosed")
			end
			return false, "odds_not_disclosed"
		end
		if luck ~= 1 then
			if not entry.source.luckDisclosed then
				error(
					`paid roll on '{sourceId}' with luck {luck} refused (hard rule 11): the source does not set luckDisclosed = true`,
					0
				)
			end
			local shown = c.disclosed(player, sourceId)
			if type(shown) ~= "table" or shown.luck ~= luck then
				error(
					`paid roll on '{sourceId}' with luck {luck} refused (hard rule 11): the client has not been shown odds with that luck (disclose first)`,
					0
				)
			end
		end
		return true, nil
	end

	local function doSample(tx: any, m: any, sourceId: string, entry: any, luck: number): any
		local outcome = entry.source.sample(tx.player, luck, tx)
		m.compliance = m.compliance or { rolls = {} }
		table.insert(m.compliance.rolls, sourceId)
		return outcome
	end

	local function readLuck(luck: any): number
		if luck == nil then
			return 1
		end
		if not isFinitePositive(luck) then
			error("ctx.compliance: luck must be a finite number > 0", 3)
		end
		return luck
	end

	local function readItem(o: any): string?
		if o == nil then
			return nil
		end
		if type(o) ~= "table" then
			error("ctx.compliance: opts must be a table or nil", 3)
		end
		if o.item ~= nil and not isItemKey(o.item) then
			error("ctx.compliance: opts.item must be a short id string (<= 64 chars)", 3)
		end
		return o.item
	end

	local function noLegacy(m: any)
		if m.legacyImport ~= nil then
			error(LEGACY_ERROR, 3)
		end
	end

	function c.forModule(caller: string): any
		return table.freeze({
			registerRandomSource = function(id: string, source: Source)
				assert(
					type(id) == "string" and id ~= "" and #id <= Compliance.MAX_ID_LENGTH,
					"registerRandomSource: id must be a short string"
				)
				assert(type(source) == "table", "registerRandomSource: source must be a table")
				assert(
					type(source.odds) == "function",
					"registerRandomSource: source.odds must be a function"
				)
				assert(
					type(source.sample) == "function",
					"registerRandomSource: source.sample must be a function"
				)
				assert(
					type(source.luckDisclosed) == "boolean",
					"registerRandomSource: luckDisclosed must be a boolean"
				)
				assert(
					source.oddsAt == nil or type(source.oddsAt) == "function",
					"registerRandomSource: source.oddsAt must be a function or nil"
				)
				local existing = sources[id]
				if existing ~= nil then
					error(`random source '{id}' already registered (by {existing.owner})`, 2)
				end
				sources[id] = { owner = caller, source = table.freeze(table.clone(source)) :: any }
				table.insert(order, id)
			end,
			registerCurrencySpender = function(currency: string, fn: (any, number, string) -> boolean)
				assert(
					type(currency) == "string" and currency ~= "",
					"registerCurrencySpender: currency must be a string"
				)
				assert(
					type(fn) == "function",
					"registerCurrencySpender: spender must be a function(tx, amount)"
				)
				local existing = spenders[currency]
				if existing ~= nil then
					error(`currency '{currency}' already has a spender (owned by {existing.owner})`, 2)
				end
				spenders[currency] = { owner = caller, fn = fn }
			end,
			isPaidCurrency = function(currency: string): boolean
				return paidSet[currency] == true
			end,
			paidCurrencies = function(): { string }
				return table.clone(paidList)
			end,
			roll = function(tx: any, sourceId: string, luck: number?, o: any?): (boolean, any, string?)
				local m = meta(tx)
				noLegacy(m)
				local entry = sourceFor(caller, sourceId)
				local l = readLuck(luck)
				local item = readItem(o)
				-- paid inside a purchase, or after a paid-currency spendPaid in this tx
				local paid = m.purchase or m.paidSpent ~= nil
				if paid then
					local ok, reason = paidGate(tx, m, sourceId, entry, l, item)
					if not ok then
						return false, nil, reason
					end
				end
				local outcome = doSample(tx, m, sourceId, entry, l)
				if outcome == nil then
					return false, nil, "no_outcome"
				end
				if paid and not m.purchase then
					m.paidcur = sourceId
				end
				return true, outcome, nil
			end,
			spendForRoll = function(
				tx: any,
				currency: string,
				amount: number,
				sourceId: string,
				luck: number?,
				o: any?
			): (boolean, any, string?)
				local m = meta(tx)
				noLegacy(m)
				local entry = sourceFor(caller, sourceId)
				local l = readLuck(luck)
				local item = readItem(o)
				if not paidSet[currency] then
					error(
						`ctx.compliance.spendForRoll: '{tostring(currency)}' is not in GameConfig.compliance.paidCurrencies (spend free currencies through their own module)`,
						2
					)
				end
				if not isFinitePositive(amount) then
					error("ctx.compliance.spendForRoll: amount must be a finite number > 0", 2)
				end
				local spender = spenders[currency]
				if spender == nil then
					error(`ctx.compliance.spendForRoll: no module registered a spender for '{currency}'`, 2)
				end
				local ok, reason = paidGate(tx, m, sourceId, entry, l, item)
				if not ok then
					return false, nil, reason
				end
				if spender.fn(tx, amount, "roll") ~= true then
					return false, nil, "insufficient"
				end
				m.paidcur = sourceId
				local outcome = doSample(tx, m, sourceId, entry, l)
				if outcome == nil then
					error(
						`spendForRoll('{sourceId}'): the source returned no outcome; the spend is discarded`,
						0
					)
				end
				return true, outcome, nil
			end,
			-- (added in v1.3.0) a paid currency spent on a NON-random good
			spendPaid = function(
				tx: any,
				currency: string,
				amount: number,
				reason: string
			): (boolean, string?)
				local m = meta(tx)
				noLegacy(m)
				if not paidSet[currency] then
					error(
						`ctx.compliance.spendPaid: '{tostring(currency)}' is not in GameConfig.compliance.paidCurrencies (spend free currencies through their own module)`,
						2
					)
				end
				if not isFinitePositive(amount) then
					error("ctx.compliance.spendPaid: amount must be a finite number > 0", 2)
				end
				if type(reason) ~= "string" or reason == "" then
					error("ctx.compliance.spendPaid: reason must be a non-empty string", 2)
				end
				local spender = spenders[currency]
				if spender == nil then
					error(`ctx.compliance.spendPaid: no module registered a spender for '{currency}'`, 2)
				end
				if spender.fn(tx, amount, reason) ~= true then
					return false, "insufficient"
				end
				m.paidSpent = currency
				return true, nil
			end,
			tagPaid = function(tx: any, reason: string?): string
				-- §14's tagPaid(source) form: a registered random source id -> "paidcur:<id>"
				if type(tx) == "string" and not data.isTxHandle(tx) then
					if sources[tx] == nil then
						error(
							`ctx.compliance.tagPaid('{tx}'): not a registered random source; pass the open tx to derive the tag`,
							2
						)
					end
					return "paidcur:" .. tx
				end
				local m = meta(tx)
				-- contract 4: an imported legacy item keeps its paid / free origin, never forgeable
				if m.legacyImport == "paid" then
					return "paid:legacy"
				elseif m.legacyImport ~= nil then
					return "legacy"
				end
				if m.purchase then
					return "paid:" .. tostring(m.product)
				end
				if m.paidcur then
					return "paidcur:" .. tostring(m.paidcur)
				end
				if m.paidSpent then
					return "paidcur:" .. tostring(m.paidSpent)
				end
				-- a caller can't forge a paid tag outside a paid tx
				local r = reason or "free"
				while true do
					local stripped = string.match(r, "^paid:(.*)$") or string.match(r, "^paidcur:(.*)$")
					if stripped == nil then
						break
					end
					r = stripped
				end
				return if r == "" then "free" else r
			end,
			disclose = function(player: any, sourceId: string?)
				c.disclose(player, sourceId)
			end,
			disclosed = function(player: any, sourceId: string): any
				return c.disclosed(player, sourceId)
			end,
			discloseItem = function(player: any, sourceId: string, itemKey: string, luck: number): boolean
				sourceFor(caller, sourceId)
				return c.discloseItem(player, sourceId, itemKey, luck)
			end,
			disclosedItem = function(player: any, sourceId: string, itemKey: string): any
				return c.disclosedItem(player, sourceId, itemKey)
			end,
			clearItem = function(player: any, sourceId: string, itemKey: string)
				sourceFor(caller, sourceId)
				c.clearItem(player, sourceId, itemKey)
			end,
		})
	end

	function c.onPlayerLoaded(player: any)
		if #order > 0 then
			c.disclose(player)
		end
	end

	function c.sources(): { string }
		return table.clone(order)
	end

	return c
end

return Compliance
