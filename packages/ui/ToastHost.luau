--!strict
--[[
	ToastHost: a vertical stack of Toasts driven by the pure ToastQueue (auto-dismiss, queue,
	duplicate merge). Feed it through `subscribe`, which receives a `push(text, rarity?)` function
	and returns an unsubscribe function, e.g. wrapping Core.Client.onFeedbackEvent.

	props:
		subscribe: (push: (text: string, rarity: string?) -> ()) -> (() -> ())
		maxVisible: number? (3), duration: number? seconds (3)
		position: UDim2?, anchorPoint: Vector2?, size: UDim2? (default top-centre, 90% x auto)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React"))
local Primitives = require(script.Parent.Primitives)
local Toast = require(script.Parent.Toast)
local ToastQueue = require(script.Parent.ToastQueue)

local e = React.createElement

export type Props = {
	subscribe: (push: (text: string, rarity: string?) -> ()) -> () -> (),
	maxVisible: number?,
	duration: number?,
	position: UDim2?,
	anchorPoint: Vector2?,
	size: UDim2?,
}

local function ToastHost(props: Props)
	local queueRef = React.useRef(nil :: ToastQueue.Queue?)
	if queueRef.current == nil then
		queueRef.current = ToastQueue.new({ maxVisible = props.maxVisible, duration = props.duration })
	end
	local queue = queueRef.current :: ToastQueue.Queue
	local version, setVersion = React.useState(0)

	local function refresh()
		setVersion(function(v: number)
			return v + 1
		end)
	end

	-- schedule one timer for the earliest expiry; re-run after every change
	React.useEffect(function(): (() -> ())?
		local deadline = ToastQueue.nextDeadline(queue)
		if deadline == nil then
			return nil
		end
		local thread = task.delay(math.max(0, deadline - os.clock()), function()
			if ToastQueue.tick(queue, os.clock()) then
				refresh()
			end
		end)
		return function()
			task.cancel(thread)
		end
	end, { version })

	React.useEffect(function()
		return props.subscribe(function(text: string, rarity: string?)
			ToastQueue.push(queue, text, os.clock(), rarity)
			refresh()
		end)
	end, { props.subscribe })

	local children: { [string]: any } = {
		Layout = Primitives.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Center),
	}
	for i, t in queue.visible do
		children["Toast" .. t.id] = e(Toast, {
			text = t.text,
			rarity = t.rarity,
			count = t.count,
			layoutOrder = i,
			onDismiss = function()
				if ToastQueue.dismiss(queue, t.id, os.clock()) then
					refresh()
				end
			end,
		})
	end

	return e("Frame", {
		BackgroundTransparency = 1,
		Size = props.size or UDim2.new(0.9, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Position = props.position or UDim2.new(0.5, 0, 0, 72),
		AnchorPoint = props.anchorPoint or Vector2.new(0.5, 0),
	}, {
		Limit = e("UISizeConstraint", { MaxSize = Vector2.new(420, math.huge) }),
		Stack = e(React.Fragment, nil, children),
	})
end

return ToastHost
