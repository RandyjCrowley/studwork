--!strict
-- A deferred hook is installed after owner values reconcile, then initialized exactly once.
local Registration = {}
function Registration.attach(hooks: any, id: string, hook: any, model: any)
	hooks[id] = hook
	if hook then
		pcall(hook, model.get(id))
	end
end
function Registration.receive(opts: any, extra: any)
	local ready: { [string]: any } = {}
	if type(extra.schema) == "table" then
		for id, def in extra.schema do
			if opts.validate(def) and id == def.id and def.scope == "saved" then
				local old = opts.defs[id]
				if old == nil or opts.same(old, def) then
					opts.defs[id] = table.clone(def)
					local waiting = opts.deferred[id]
					if waiting and opts.same(waiting, def) then
						ready[id] = waiting
					end
					opts.deferred[id] = nil
				end
			end
		end
	end
	opts.model.snapshot(extra.values, extra.revision)
	for id, waiting in ready do
		Registration.attach(opts.hooks, id, waiting.apply, opts.model)
	end
end
return Registration
