--!strict
-- Optimistic drafts stay separate from authoritative values and monotonically ordered replies.
local Model = {}
function Model.new(defs: any, opts: any): any
	local self: any = {
		revision = -1,
		confirmed = {},
		drafts = {},
		requests = {},
		nextRequest = 0,
		status = "saved",
		generation = 0,
	}
	local serial = 0
	local function default(id: string): any
		return opts.default(defs[id])
	end
	function self.get(id: string): any
		if defs[id] == nil then
			return nil
		end
		local draft = self.drafts[id]
		if draft then
			return draft.value
		end
		local value = self.confirmed[id]
		return if value ~= nil then value else default(id)
	end
	local function notify(id: string, before: any)
		local value = self.get(id)
		if opts.updated then
			opts.updated()
		end
		if value ~= before then
			opts.changed(id, value)
		end
	end
	function self.edit(id: string, value: any): boolean
		local def = defs[id]
		if def == nil or not opts.validate(def, value) or not opts.enabled() then
			return false
		end
		local before = self.get(id)
		if def.scope == "client" then
			self.confirmed[id] = value
			notify(id, before)
			return true
		end
		if self.nextRequest >= opts.maxRequest then
			return false
		end
		serial += 1
		local draft = { value = value, serial = serial }
		local generation = self.generation
		self.drafts[id] = draft
		self.status = "saving"
		notify(id, before)
		opts.delay(opts.debounce, function()
			if self.drafts[id] ~= draft or generation ~= self.generation then
				return
			end
			if not opts.enabled() then
				self.cancel()
				return
			end
			if self.nextRequest >= opts.maxRequest then
				local old = self.get(id)
				self.drafts[id] = nil
				self.status = "rejected"
				notify(id, old)
				return
			end
			self.nextRequest += 1
			draft.request = self.nextRequest
			self.requests[id] = draft.request
			opts.send(id, value, draft.request)
		end)
		return true
	end
	function self.snapshot(values: any, revision: any)
		if
			type(values) ~= "table"
			or type(revision) ~= "number"
			or revision % 1 ~= 0
			or revision < self.revision
			or revision > opts.maxRequest
		then
			return
		end
		local before = {}
		for id in defs do
			before[id] = self.get(id)
		end
		self.revision = revision
		for id, def in defs do
			if def.scope == "saved" then
				self.confirmed[id] = if opts.validate(def, values[id]) then values[id] else default(id)
			end
		end
		for id in defs do
			notify(id, before[id])
		end
	end
	function self.ack(id: any, value: any, request: any, accepted: any, revision: any)
		local def = defs[id]
		if
			def == nil
			or def.scope ~= "saved"
			or type(request) ~= "number"
			or request ~= self.requests[id]
			or type(accepted) ~= "boolean"
			or type(revision) ~= "number"
			or revision % 1 ~= 0
			or revision < 0
			or revision > opts.maxRequest
			or not opts.validate(def, value)
		then
			return
		end
		local before = self.get(id)
		if revision >= self.revision then
			self.revision = revision
			self.confirmed[id] = value
		end
		local draft = self.drafts[id]
		if draft and draft.request == request then
			self.drafts[id] = nil
			self.status = if accepted then "saved" else "rejected"
		end
		notify(id, before)
	end
	function self.reset(id: string)
		local def = defs[id]
		if def == nil or not opts.enabled() then
			return
		end
		if def.scope == "saved" then
			self.edit(id, default(id))
			return
		end
		local before = self.get(id)
		self.confirmed[id] = nil
		self.drafts[id] = nil
		notify(id, before)
	end
	function self.refreshDefault(id: string)
		if defs[id] and self.confirmed[id] == nil and self.drafts[id] == nil then
			opts.changed(id, self.get(id))
		end
	end
	function self.cancel()
		local before = {}
		for id in self.drafts do
			before[id] = self.get(id)
		end
		self.generation += 1
		self.drafts = {}
		self.requests = {}
		self.status = "saved"
		if opts.cancelled then
			opts.cancelled()
		end
		for id, value in before do
			notify(id, value)
		end
	end
	function self.destroy()
		self.generation += 1
		self.drafts = {}
		self.requests = {}
	end
	return self
end
return Model
