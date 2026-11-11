--!strict
--[[
	Mail client part (module-api.md §9, §13; core-v1.3.1 R19: one folder per module, found by the
	client runtime as ReplicatedStorage.Modules.Mail.client). Moved here from the framework client
	in core-v1.3.1:
	  - the HUD mailbox badge "Social.mailbox" (topCenter, order 3, shown while messages wait):
	    "Mailbox (N)"; tapping calls HudOptions.onMailbox, or opens the "Mailbox" screen (UI.open)
	    whose claim button fires the claimMail action. Registered with UI.registerWidget at start
	    under the same id, so GameConfig.client.hud.widgets["Social.mailbox"] = false and custom
	    layouts keep working; a removal registered before start is kept.
	  - StudWork.use(Mail).onMailbox(handler(count)) -> Connection: fires with the mailbox count
	    whenever it changes (and once on connect when the state is loaded). Was
	    StudWork.Client.onMailbox (v1.2, N1).
	  - StudWork.use(Mail).actions.claimMail(messageId)
	  - StudWork.use(Mail).read.<reader>(StudWork.Client.state())   pure readers (client/State.luau)
	claimMail fires this module's own Blink event ClaimMail (net.blink -> client/Net.luau, bound by
	the client runtime as the part's `net`; core-v1.3.1 R19, was the framework's RequestMailClaim).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local State = require(script.State)

local WIDGET_ID = "Social.mailbox"

local function studWork(): any
	return require(ReplicatedStorage:WaitForChild("Framework")) :: any
end

local function rawState(): any
	return studWork().Client.state()
end

local function openMailbox()
	local UI = require(ReplicatedStorage:WaitForChild("UI")) :: any
	local ref = require(script.Parent:WaitForChild("module")) :: any
	UI.open("Mailbox", {
		bind = function(): any
			return { messages = State.mailbox(rawState()) }
		end,
		onClaim = function(id: any)
			studWork().use(ref).actions.claimMail(id)
		end,
	})
end

local function MailboxWidget(props: any)
	local count = State.count(props.state)
	if count <= 0 then
		return nil
	end
	local React = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("React")) :: any
	local UI = require(ReplicatedStorage:WaitForChild("UI")) :: any
	local opts = props.opts or {}
	return React.createElement(UI.Button, {
		text = `Mailbox ({count})`,
		variant = "secondary",
		layoutOrder = props.layoutOrder,
		onActivated = function()
			if opts.onMailbox then
				task.spawn(opts.onMailbox)
			else
				openMailbox()
			end
		end,
	})
end

local function onMailbox(handler: (count: number) -> ()): any
	assert(type(handler) == "function", "Mail.onMailbox: handler must be a function")
	local Charm = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Charm")) :: any
	local function countOf(): number
		local s = rawState()
		return if type(s) == "table" and s.loaded then State.count(s) else -1
	end
	local last = countOf()
	if last >= 0 then
		task.spawn(handler, last)
	end
	local cleanup = Charm.subscribe(countOf, function(n: number)
		if n >= 0 and n ~= last then
			last = n
			task.spawn(handler, n)
		end
	end)
	local connection = { Connected = true }
	function connection.Disconnect(self: any)
		if self.Connected then
			self.Connected = false
			cleanup()
		end
	end
	return connection
end

local Mail = {}

Mail.WIDGET_ID = WIDGET_ID
Mail.widget = table.freeze({ slot = "topCenter", order = 3, module = "Mail", component = MailboxWidget })
-- `claimMail = true`: fire this part's own Net event of the same (PascalCase) name, ClaimMail. Same
-- as `{ "claimMail" }` for the runtime; the keyed form is what tools/lune/KitModules and
-- KitClients.spec read today (KitModules' array-form pattern uses `^` inside gmatch).
Mail.actions = { claimMail = true }
Mail.api = { onMailbox = onMailbox, read = State }

function Mail.start(_ctx: any)
	local UI = require(ReplicatedStorage:WaitForChild("UI")) :: any
	local _, removals = UI.widgets()
	if removals[WIDGET_ID] == nil then
		UI.registerWidget(WIDGET_ID, Mail.widget)
	end
end

return Mail
