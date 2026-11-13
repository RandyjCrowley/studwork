--!strict
-- Bounded-rate sends are tied to the model generation so a flag cycle cannot revive a draft.
local SendQueue = {}
function SendQueue.new(opts: any): any
	local nextSendAt = opts.now()
	local model = opts.model
	local queue: any = {}
	function queue.reset()
		nextSendAt = opts.now()
	end
	function queue.cancel()
		model.cancel()
		queue.reset()
	end
	function queue.send(id: string, value: any, request: number)
		local generation = model.generation
		local waitFor = math.max(0, nextSendAt - opts.now())
		nextSendAt = math.max(nextSendAt, opts.now()) + opts.interval
		opts.delay(waitFor, function()
			if generation ~= model.generation then
				return
			end
			local draft = model.drafts[id]
			if draft == nil or draft.request ~= request then
				return
			end
			if not opts.enabled() then
				queue.cancel()
				return
			end
			opts.fire(id, value, request)
			opts.delay(opts.timeout, function()
				if generation ~= model.generation then
					return
				end
				local current = model.drafts[id]
				if current and current.request == request then
					local fallback = model.confirmed[id]
					if fallback == nil then
						fallback = opts.default(id)
					end
					model.ack(id, fallback, request, false, math.max(0, model.revision))
				end
			end)
		end)
	end
	return queue
end
return SendQueue
