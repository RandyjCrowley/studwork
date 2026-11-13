--!strict
--[[
	Admin staff panel (React-lua). This code lives in the Admin SERVER part and reaches a client
	only by being cloned into a staff player's PlayerGui (Admin/server/init.luau placePanel), so a
	non-staff client never receives it. The Admin client part requires it from there:

	  Panel.mount(bridge) -> { open(), close(), toggle(), destroy() }
	  bridge = { holder: ScreenGui, staff: () -> extra.staff?, onStaff(fn) -> disconnect,
	             run(Run), fetch(tabId, page), panelOpen(),
	             onRows(fn(tabId, page, json)) -> disconnect, onResult(fn(ok, key)) -> disconnect }

	Layout: mobile first at 667x375 (landscape phone), inside UI.ScaledRoot; every touch target is
	at least Theme.touchTarget; colours, fonts and sizes from the theme; every label a strings key
	(Admin.* with English defaults in the module's `strings`). No tweens and no animations at all,
	so the panel respects reduced motion by construction. The view state is the pure ./State.
	Tabs: Players (this server's players + quick actions), the registered tabs (Reports, Audit,
	...), Announce, Data. Row cells are server-checked numbers, booleans and strings keys/names.
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage:WaitForChild("Packages")
local React = require(Packages:WaitForChild("React")) :: any
local ReactRoblox = require(Packages:WaitForChild("ReactRoblox")) :: any
local UI = require(ReplicatedStorage:WaitForChild("UI")) :: any

local State = require(script.State)

local e = React.createElement
local Theme = UI.Theme

local PANEL_WIDTH = 667
local PANEL_HEIGHT = 375
local TAB_WIDTH = 132
local GAP = 6

local function text(key: string, args: any?): string
	return UI.text(key, args)
end

-- a flat themed button: no press tween (reduced motion), at least the touch target tall
local function FlatButton(props: any)
	local target = Theme.touchTarget
	return e("TextButton", {
		Text = props.label,
		AutoLocalize = props.autoLocalize ~= false,
		FontFace = Theme.font("bold"),
		TextSize = Theme.text.body,
		TextColor3 = Theme.color("text"),
		TextWrapped = true,
		BackgroundColor3 = Theme.color(if props.selected then "accent" else (props.color or "surfaceAlt")),
		AutoButtonColor = true,
		Active = props.disabled ~= true,
		Size = props.size or UDim2.new(1, 0, 0, target),
		LayoutOrder = props.layoutOrder,
		[React.Event.Activated] = function()
			if props.disabled ~= true and props.onActivated then
				props.onActivated()
			end
		end,
	}, {
		Corner = UI.Primitives.corner(),
		Size = e("UISizeConstraint", { MinSize = Vector2.new(target, target) }),
		Padding = UI.Primitives.padding(GAP),
	})
end

local function Label(props: any)
	return e("TextLabel", {
		Text = props.text,
		AutoLocalize = props.autoLocalize ~= false,
		FontFace = Theme.font(if props.bold then "bold" else "body"),
		TextSize = props.size or Theme.text.body,
		TextColor3 = Theme.color(props.color or "text"),
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
		LayoutOrder = props.layoutOrder,
	})
end

local function TextInput(props: any)
	return e("TextBox", {
		Text = props.value or "",
		PlaceholderText = props.placeholder,
		ClearTextOnFocus = false,
		FontFace = Theme.font("body"),
		TextSize = Theme.text.body,
		TextColor3 = Theme.color("text"),
		PlaceholderColor3 = Theme.color("textMuted"),
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundColor3 = Theme.color("background"),
		Size = UDim2.new(1, 0, 0, Theme.touchTarget),
		LayoutOrder = props.layoutOrder,
		[React.Change.Text] = function(rbx: any)
			props.onChange(rbx.Text)
		end,
	}, {
		Corner = UI.Primitives.corner(),
		Padding = UI.Primitives.padding(GAP),
	})
end

local function Scroll(props: any)
	return e("ScrollingFrame", {
		Size = props.size or UDim2.fromScale(1, 1),
		Position = props.position,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = GAP,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		LayoutOrder = props.layoutOrder,
	}, props.children)
end

local function listLayout(): any
	return UI.Primitives.list(Enum.FillDirection.Vertical, GAP)
end

-- a picker: one button that cycles through the choices (no dropdown animation)
local function Picker(props: any)
	local label = if props.value ~= nil then props.show(props.value) else text(props.emptyKey)
	return e(FlatButton, {
		label = label,
		layoutOrder = props.layoutOrder,
		selected = props.value ~= nil,
		onActivated = function()
			props.onPick(State.cycle(props.choices, props.value))
		end,
	})
end

local function durationText(seconds: number): string
	local key, args = State.durationLabel(seconds)
	return text(key, args)
end

local function resultLine(state: any): any
	if state.resultKey == nil then
		return nil
	end
	return e(Label, {
		text = text(state.resultKey),
		color = if state.resultOk then "success" else "danger",
		layoutOrder = 99,
	})
end

-- the choices of one action (presets, durations, amount, free text) and the two-step confirm
local function ActionForm(props: any)
	local a, state, dispatch = props.action, props.state, props.dispatch
	local children: { [string]: any } = { Layout = listLayout() }
	local order = 0
	local function add(name: string, element: any)
		order += 1
		children[name] = if element ~= nil then React.cloneElement(element, { layoutOrder = order }) else nil
	end
	add("Title", e(Label, { text = text(a.labelKey), bold = true }))
	if type(a.presets) == "table" and #a.presets > 0 then
		local isCurrency = type(a.amount) == "table"
		add(
			"Preset",
			e(Picker, {
				choices = a.presets,
				value = state.preset,
				emptyKey = if isCurrency then "Admin.panel.currency" else "Admin.panel.reason",
				show = function(v: string): string
					return if isCurrency then v else text(v)
				end,
				onPick = function(v: any)
					dispatch({ type = "preset", value = v })
				end,
			})
		)
	end
	if type(a.durations) == "table" and #a.durations > 0 then
		add(
			"Duration",
			e(Picker, {
				choices = a.durations,
				value = state.duration,
				emptyKey = "Admin.panel.duration",
				show = durationText,
				onPick = function(v: any)
					dispatch({ type = "duration", value = v })
				end,
			})
		)
	end
	if type(a.amount) == "table" then
		add(
			"Amount",
			e(TextInput, {
				value = if state.amount ~= nil then tostring(state.amount) else "",
				placeholder = text("Admin.panel.amount"),
				onChange = function(v: string)
					dispatch({ type = "amount", value = v })
				end,
			})
		)
	end
	if a.freeText == true then
		add(
			"Text",
			e(TextInput, {
				value = state.text,
				placeholder = text("Admin.panel.text"),
				onChange = function(v: string)
					dispatch({ type = "text", value = v })
				end,
			})
		)
	end
	local run, why = props.request()
	add(
		"Confirm",
		e(FlatButton, {
			label = text(
				if run == nil
					then why or "Admin.panel.confirm"
					elseif state.confirming then "Admin.panel.confirmAgain"
					else "Admin.panel.confirm"
			),
			color = if state.confirming then "danger" else "surfaceAlt",
			disabled = run == nil,
			onActivated = function()
				if run == nil then
					return
				end
				if not state.confirming then
					dispatch({ type = "confirm", value = true })
					return
				end
				dispatch({ type = "confirm", value = false })
				props.send(run)
			end,
		})
	)
	children.Result = resultLine(state)
	return e(Scroll, { size = props.size, position = props.position }, children)
end

local function PlayerList(props: any)
	local rows = props.rows
	local children: { [string]: any } = { Layout = listLayout() }
	for i, row in rows do
		local userId = row.userId
		children["P" .. i] = e(FlatButton, {
			label = State.cellText(row.name, nil, tostring),
			autoLocalize = false,
			selected = userId ~= nil and userId == props.selected,
			layoutOrder = i,
			onActivated = function()
				props.dispatch({ type = "select", userId = userId })
			end,
		})
	end
	if #rows == 0 then
		children.Empty = e(Label, { text = text("Admin.panel.empty"), color = "textMuted" })
	end
	return e(Scroll, { size = props.size, position = props.position }, children)
end

local function rowsOf(state: any, tabId: string): { any }
	local entry = state.rows[tabId]
	return if entry ~= nil then entry.data.rows else {}
end

local function PlayersTab(props: any)
	local state, staff, dispatch = props.state, props.staff, props.dispatch
	local actions = State.playerActions(staff)
	local half = UDim2.new(0.5, -GAP // 2, 1, 0)
	local right: { [string]: any } = { Layout = listLayout() }
	for i, a in actions do
		right["A" .. i] = e(FlatButton, {
			label = text(a.labelKey),
			selected = state.actionId == a.id,
			layoutOrder = i,
			onActivated = function()
				dispatch({ type = "action", id = a.id })
			end,
		})
	end
	local chosen = if state.actionId ~= nil then State.action(staff, state.actionId) else nil
	return e("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 }, {
		List = e(PlayerList, {
			rows = rowsOf(state, "players"),
			selected = state.selected,
			dispatch = dispatch,
			size = half,
		}),
		Actions = if chosen == nil
			then e(Scroll, { size = half, position = UDim2.new(0.5, GAP // 2, 0, 0) }, right)
			else e(ActionForm, {
				action = chosen,
				state = state,
				dispatch = dispatch,
				size = half,
				position = UDim2.new(0.5, GAP // 2, 0, 0),
				request = function()
					return State.request(state, staff)
				end,
				send = props.send,
			}),
	})
end

-- the picked row action's choices (presets such as a resolution, an optional note) and confirm;
-- shown at the top of the tab
local function RowChoice(props: any)
	local state, tab, dispatch = props.state, props.tab, props.dispatch
	local picked = state.rowAction
	if picked == nil or picked.tabId ~= tab.id then
		return nil
	end
	local ra = nil
	for _, candidate in tab.rowActions or {} do
		if candidate.id == picked.id then
			ra = candidate
		end
	end
	if ra == nil then
		return nil
	end
	local children: { [string]: any } = {
		Layout = listLayout(),
		Title = e(Label, { text = text(ra.labelKey), bold = true, layoutOrder = 1 }),
	}
	if type(ra.presets) == "table" and #ra.presets > 0 then
		children.Preset = e(Picker, {
			choices = ra.presets,
			value = state.preset,
			emptyKey = "Admin.panel.reason",
			show = text,
			layoutOrder = 2,
			onPick = function(v: any)
				dispatch({ type = "preset", value = v })
			end,
		})
	end
	if type(ra.notes) == "table" and #ra.notes > 0 then
		children.Note = e(Picker, {
			choices = ra.notes,
			value = state.note,
			emptyKey = "Admin.panel.note",
			show = text,
			layoutOrder = 3,
			onPick = function(v: any)
				dispatch({ type = "note", value = v })
			end,
		})
	end
	local run, why = State.rowRun(state, props.staff)
	children.Confirm = e(FlatButton, {
		label = text(
			if run == nil
				then why or "Admin.panel.confirm"
				elseif state.confirming then "Admin.panel.confirmAgain"
				else "Admin.panel.confirm"
		),
		color = if state.confirming then "danger" else "surfaceAlt",
		disabled = run == nil,
		layoutOrder = 4,
		onActivated = function()
			if run == nil then
				return
			end
			if not state.confirming then
				dispatch({ type = "confirm", value = true })
				return
			end
			dispatch({ type = "rowAction" })
			props.send(run)
		end,
	})
	children.Cancel = e(FlatButton, {
		label = text("Admin.panel.cancel"),
		color = "surface",
		layoutOrder = 5,
		onActivated = function()
			dispatch({ type = "rowAction" })
		end,
	})
	return e("Frame", {
		BackgroundColor3 = Theme.color("background"),
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
		LayoutOrder = 0,
	}, children)
end

local function RowsTab(props: any)
	local state, tab, dispatch = props.state, props.tab, props.dispatch
	local entry = state.rows[tab.id]
	local data = if entry ~= nil then entry.data else { columns = {}, rows = {} }
	local children: { [string]: any } = { Layout = listLayout() }
	for i, row in data.rows do
		local cells = {}
		for _, column in data.columns do
			if row[column] ~= nil then
				table.insert(cells, State.cellText(row[column], nil, text))
			end
		end
		local rowChildren: { [string]: any } = {
			Layout = UI.Primitives.list(Enum.FillDirection.Vertical, GAP // 2),
			Cells = e(Label, { text = table.concat(cells, "  ·  "), layoutOrder = 1, autoLocalize = false }),
		}
		if type(row.id) == "string" then
			for j, ra in tab.rowActions or {} do
				local picked = state.rowAction
				rowChildren["R" .. j] = e(FlatButton, {
					label = text(ra.labelKey),
					layoutOrder = 1 + j,
					selected = picked ~= nil and picked.id == ra.id and picked.rowId == row.id,
					onActivated = function()
						dispatch({ type = "rowAction", tabId = tab.id, id = ra.id, rowId = row.id })
					end,
				})
			end
		end
		children["Row" .. i] = e("Frame", {
			BackgroundColor3 = Theme.color("surfaceAlt"),
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 0),
			LayoutOrder = i,
		}, rowChildren)
	end
	if #data.rows == 0 then
		children.Empty = e(Label, { text = text("Admin.panel.empty"), color = "textMuted", layoutOrder = 1 })
	end
	children.Choice = e(
		RowChoice,
		{ state = state, staff = props.staff, tab = tab, dispatch = dispatch, send = props.send }
	)
	local bar = Theme.touchTarget
	return e("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 }, {
		Rows = e(Scroll, { size = UDim2.new(1, 0, 1, -(bar + GAP)) }, children),
		Bar = e("Frame", {
			Size = UDim2.new(1, 0, 0, bar),
			Position = UDim2.new(0, 0, 1, -bar),
			BackgroundTransparency = 1,
		}, {
			Layout = UI.Primitives.list(Enum.FillDirection.Horizontal, GAP),
			Prev = e(FlatButton, {
				label = text("Admin.panel.previous"),
				size = UDim2.new(0.3, 0, 1, 0),
				disabled = state.page <= 1,
				layoutOrder = 1,
				onActivated = function()
					dispatch({ type = "page", delta = -1 })
				end,
			}),
			Page = e("TextLabel", {
				Text = text("Admin.panel.page", { page = state.page }),
				FontFace = Theme.font("body"),
				TextSize = Theme.text.body,
				TextColor3 = Theme.color("textMuted"),
				BackgroundTransparency = 1,
				Size = UDim2.new(0.3, 0, 1, 0),
				LayoutOrder = 2,
			}),
			Next = e(FlatButton, {
				label = text("Admin.panel.next"),
				size = UDim2.new(0.3, 0, 1, 0),
				layoutOrder = 3,
				onActivated = function()
					dispatch({ type = "page", delta = 1 })
				end,
			}),
		}),
		Result = resultLine(state),
	})
end

local function AnnounceTab(props: any)
	local staff, state = props.staff, props.state
	local a = State.action(staff, "announce")
	if a == nil then
		return nil
	end
	return e(ActionForm, {
		action = a,
		state = state,
		dispatch = props.dispatch,
		request = function()
			return State.announceRequest(state, staff)
		end,
		send = props.send,
	})
end

local function DataTab(props: any)
	local state, staff = props.state, props.staff
	local half = UDim2.new(0.5, -GAP // 2, 1, 0)
	local entry = state.rows.data
	local children: { [string]: any } = { Layout = listLayout() }
	local view = State.action(staff, "dataView")
	children.View = e(FlatButton, {
		label = text(if view ~= nil then view.labelKey else "Admin.action.dataView"),
		disabled = state.selected == nil,
		layoutOrder = 0,
		onActivated = function()
			if state.selected ~= nil then
				props.send({ actionId = "dataView", targetUserId = state.selected })
			end
		end,
	})
	if entry ~= nil and entry.data.target == state.selected then
		for i, row in entry.data.rows do
			children["D" .. i] = e(Label, {
				text = `{text(tostring(row.section))} / {text(tostring(row.label))}: {State.cellText(
					row.value,
					row.kind,
					text
				)}`,
				autoLocalize = false,
				layoutOrder = i,
			})
		end
	end
	children.Result = resultLine(state)
	return e("Frame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 }, {
		List = e(PlayerList, {
			rows = rowsOf(state, "players"),
			selected = state.selected,
			dispatch = props.dispatch,
			size = half,
		}),
		Values = e(Scroll, { size = half, position = UDim2.new(0.5, GAP // 2, 0, 0) }, children),
	})
end

local function App(props: any)
	local bridge = props.bridge
	local staff, setStaff = React.useState(bridge.staff())
	local state, setState = React.useState(State.new(staff))
	local stateRef = React.useRef(state)
	stateRef.current = state

	local function dispatch(event: any)
		setState(function(current: any): any
			return State.reduce(current, event)
		end)
	end

	React.useEffect(function()
		local offStaff = bridge.onStaff(function()
			setStaff(bridge.staff())
		end)
		local offRows = bridge.onRows(function(tabId: string, page: number, json: string)
			local ok, decoded = pcall(function(): any
				return HttpService:JSONDecode(json)
			end)
			if ok then
				dispatch({ type = "rows", tabId = tabId, page = page, data = decoded })
			end
		end)
		local offResult = bridge.onResult(function(ok: boolean, key: string)
			dispatch({ type = "result", ok = ok, key = key })
			-- a finished row action or quick action changes what the tab shows
			local current = stateRef.current
			bridge.fetch(if current.tab == "data" then "players" else current.tab, current.page)
		end)
		return function()
			offStaff()
			offRows()
			offResult()
		end
	end, {})

	local tabs = State.tabs(staff)
	local current = tabs[1]
	for _, t in tabs do
		if t.id == state.tab then
			current = t
		end
	end

	React.useEffect(function()
		if current == nil then
			return
		end
		if current.kind == "players" or current.kind == "data" then
			bridge.fetch("players", if current.kind == "players" then state.page else 1)
		elseif current.kind == "rows" then
			bridge.fetch(current.id, state.page)
		end
	end, { if current then current.id else "", state.page })

	if staff == nil or current == nil then
		return nil
	end

	local tabButtons: { [string]: any } = { Layout = listLayout() }
	for i, t in tabs do
		tabButtons["T" .. i] = e(FlatButton, {
			label = text(t.labelKey),
			selected = t.id == current.id,
			layoutOrder = i,
			onActivated = function()
				dispatch({ type = "tab", id = t.id })
			end,
		})
	end
	tabButtons.Close = e(FlatButton, {
		label = text("Admin.close"),
		color = "surface",
		layoutOrder = #tabs + 1,
		onActivated = props.onClose,
	})

	local function send(run: any)
		bridge.run(run)
	end
	local body
	local common = { state = state, staff = staff, dispatch = dispatch, send = send }
	if current.kind == "players" then
		body = e(PlayersTab, common)
	elseif current.kind == "announce" then
		body = e(AnnounceTab, common)
	elseif current.kind == "data" then
		body = e(DataTab, common)
	else
		local def = State.tabDef(staff, current.id) or { id = current.id, rowActions = {} }
		local p = table.clone(common) :: any
		p.tab = def
		body = e(RowsTab, p)
	end

	return e("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -2 * GAP, 1, -2 * GAP),
		BackgroundColor3 = Theme.color("surface"),
	}, {
		Max = e("UISizeConstraint", { MaxSize = Vector2.new(PANEL_WIDTH, PANEL_HEIGHT) }),
		Corner = UI.Primitives.corner(),
		Padding = UI.Primitives.padding(GAP),
		Tabs = e(Scroll, { size = UDim2.new(0, TAB_WIDTH, 1, 0) }, tabButtons),
		Body = e("Frame", {
			Position = UDim2.new(0, TAB_WIDTH + GAP, 0, 0),
			Size = UDim2.new(1, -(TAB_WIDTH + GAP), 1, 0),
			BackgroundTransparency = 1,
		}, { Content = body }),
	})
end

-- the closed state: one small "Staff" button on the left edge
local function Toggle(props: any)
	local target = Theme.touchTarget
	return e(FlatButton, {
		label = text("Admin.open"),
		size = UDim2.fromOffset(target * 2, target),
		onActivated = props.onOpen,
	})
end

local Panel = {}

function Panel.mount(bridge: any): any
	local root = ReactRoblox.createRoot(bridge.holder)
	local isOpen = false
	local controller: any = {}

	local function render()
		local content = if isOpen
			then e(App, {
				bridge = bridge,
				onClose = function()
					controller.close()
				end,
			})
			else e("Frame", {
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, GAP, 0.5, 0),
				Size = UDim2.fromOffset(Theme.touchTarget * 2, Theme.touchTarget),
				BackgroundTransparency = 1,
			}, {
				Toggle = e(Toggle, {
					onOpen = function()
						controller.open()
					end,
				}),
			})
		root:render(e(UI.ScaledRoot, nil, { Admin = content }))
	end

	function controller.open()
		if not isOpen then
			isOpen = true
			bridge.panelOpen()
			render()
		end
	end

	function controller.close()
		if isOpen then
			isOpen = false
			render()
		end
	end

	function controller.toggle()
		if isOpen then
			controller.close()
		else
			controller.open()
		end
	end

	function controller.destroy()
		root:unmount()
	end

	render()
	return controller
end

return Panel
