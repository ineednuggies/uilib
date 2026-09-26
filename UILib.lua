--[[
	UILib v2 - tweened UI library for Roblox (client-side, works in Studio).

	local UILib = require(game.ReplicatedStorage.UILib)

	local Window = UILib:CreateWindow({
		Title   = "My Hub",
		Size    = UDim2.fromOffset(540, 380),     -- starting size AND minimum size
		MaxSize = UDim2.fromOffset(920, 640),     -- biggest it can be dragged to
		HideKey = Enum.KeyCode.RightShift,        -- hides/shows the whole menu
		OnClose = function() ... end,             -- runs when the user confirms the X button (your cleanup)
	})

	Window:SetHideKey(key) / Window:GetHideKey()
	Window:SetHidden(bool) / Window:ToggleHidden()
	Window:SetMinimized(bool) / Window:ToggleMinimized()   -- the top-right shrink button
	Window:RequestClose()   -- what the X button does: hides the UI and asks "are you sure?"
	Window:Close()          -- runs OnClose, then destroys everything (no prompt)
	Window:Destroy()

	The title bar also has a search box: type to filter every toggle / slider /
	dropdown / button / label by name (dropdowns also match their option names).
	Tabs with no matches are dimmed, and the window jumps to the first tab that has one.

	local Tab = Window:AddTab("Name")
	Tab:AddToggle({Name, Default, Keybind, Callback})             -> :Set(bool) :Get() :SetKey(key|nil) :GetKey()
	Tab:AddSlider({Name, Min, Max, Default, Increment, Callback}) -> :Set(n) :Get()
	Tab:AddDropdown({Name, Options, Default, Callback})           -> :Set(str) :Get() :SetOptions(list)
	Tab:AddMultiDropdown({Name, Options, Default = {}, Callback}) -> :Set(list) :Get() :SetOptions(list)
	Tab:AddButton({Name, Callback})
	Tab:AddLabel(text)                                            -> :Set(text)

	Toggle-gated items: pass ShowWhen = <toggle object> to ANY Add* call and that
	item only shows (and can only be used) while the toggle is on. It slides
	open/closed and stays in the same column as its toggle:

		local boost = Tab:AddToggle({Name = "Speed Boost"})
		Tab:AddSlider({Name = "Boost Speed", Min = 16, Max = 100, ShowWhen = boost})

	Toggles also have :OnChanged(function(isOn) ... end) for your own logic.

	Rebinding: click the "Hide: <key>" chip in the title bar, or the key box on a
	toggle, then press a key. (Backspace clears a toggle's key / cancels the chip.)
	Resizing: drag the grip in the bottom-right corner. When the window is wide
	enough, each tab's items smoothly re-flow into two columns.
]]

local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local UILib = {}

local Window = {}
Window.__index = Window

local Tab = {}
Tab.__index = Tab

---------------------------------------------------------------------
-- Theme / constants
---------------------------------------------------------------------
local Theme = {
	Background = Color3.fromRGB(22, 22, 28),
	Panel = Color3.fromRGB(30, 30, 38),
	Element = Color3.fromRGB(36, 36, 46),
	ElementHover = Color3.fromRGB(46, 46, 58),
	Accent = Color3.fromRGB(88, 130, 255),
	AccentDim = Color3.fromRGB(52, 74, 150),
	Off = Color3.fromRGB(62, 62, 76),
	Text = Color3.fromRGB(235, 235, 242),
	SubText = Color3.fromRGB(150, 150, 168),
	Stroke = Color3.fromRGB(52, 52, 66),
	Danger = Color3.fromRGB(200, 60, 70),
	DangerHover = Color3.fromRGB(225, 80, 90),
}

local FONT = Enum.Font.Gotham
local FONT_BOLD = Enum.Font.GothamMedium

local TOPBAR_H = 38
local TAB_H = 32
local TAB_GAP = 6
local HEADER_H = 38
local OPT_H = 26
local OPT_GAP = 3
local MAX_LIST_H = 150

-- page layout
local PAD_L, PAD_T, PAD_R, PAD_B = 8, 8, 10, 8 -- room around items so glows never get clipped
local ITEM_GAP = 8
local COL_GAP = 8
local MIN_COL_W = 260 -- a column is never narrower than this
local SPLIT_HYST = 14 -- px of hysteresis so dragging across the split point doesn't flicker
local BLEND_TIME = 0.45 -- seconds for the 1-column <-> 2-column re-flow
local BOTTOM_MARGIN = 22 -- space under the content for the resize grip

-- glow layers: {stroke thickness, transparency when on}
local GLOW_STRONG = { { 2, 0.55 }, { 4, 0.8 }, { 6, 0.92 } }
local GLOW_SOFT = { { 2, 0.72 }, { 4, 0.9 } }

---------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------
local function tween(obj, props, duration, style, direction)
	local t = TweenService:Create(
		obj,
		TweenInfo.new(duration or 0.2, style or Enum.EasingStyle.Quint, direction or Enum.EasingDirection.Out),
		props
	)
	t:Play()
	return t
end

local function new(class, props, children)
	local inst = Instance.new(class)
	for k, v in pairs(props) do
		if k ~= "Parent" then
			inst[k] = v
		end
	end
	if children then
		for _, child in ipairs(children) do
			child.Parent = inst
		end
	end
	inst.Parent = props.Parent
	return inst
end

local function corner(radius)
	return new("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function stroke(color, thickness)
	return new("UIStroke", {
		Color = color,
		Thickness = thickness or 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

local function padding(l, t, r, b)
	return new("UIPadding", {
		PaddingLeft = UDim.new(0, l),
		PaddingTop = UDim.new(0, t),
		PaddingRight = UDim.new(0, r),
		PaddingBottom = UDim.new(0, b),
	})
end

local function label(props)
	props.BackgroundTransparency = 1
	props.Font = props.Font or FONT
	props.TextSize = props.TextSize or 14
	props.TextColor3 = props.TextColor3 or Theme.Text
	props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	return new("TextLabel", props)
end

local function hover(button, target, normal, over)
	button.MouseEnter:Connect(function()
		tween(target, { BackgroundColor3 = over }, 0.15)
	end)
	button.MouseLeave:Connect(function()
		tween(target, { BackgroundColor3 = normal }, 0.15)
	end)
end

local function fire(callback, ...)
	if callback then
		task.spawn(callback, ...)
	end
end

local function decimalsOf(increment)
	local frac = tostring(increment):match("%.(%d+)")
	return frac and #frac or 0
end

local function isPointer(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
end

local function isMove(input)
	return input.UserInputType == Enum.UserInputType.MouseMovement
		or input.UserInputType == Enum.UserInputType.Touch
end

local function ease(t) -- easeInOutCubic
	if t < 0.5 then
		return 4 * t * t * t
	end
	local u = -2 * t + 2
	return 1 - (u * u * u) / 2
end

-- Glow = a few stacked, transparent rounded frames whose UIStrokes fade in.
-- Strokes follow the parent's corner radius, so it stays smooth and never
-- goes square. Only transparency is tweened (cheap, no per-frame code).
local function addGlow(parent, radius, layers)
	layers = layers or GLOW_STRONG
	local strokes = {}
	for i, layer in ipairs(layers) do
		local st = new("UIStroke", {
			Color = Theme.Accent,
			Thickness = layer[1],
			Transparency = 1,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		})
		new("Frame", {
			Name = "Glow" .. i,
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Parent = parent,
		}, { corner(radius), st })
		strokes[i] = st
	end
	local glow = {}
	function glow.Set(on, duration)
		for i, st in ipairs(strokes) do
			tween(st, { Transparency = on and layers[i][2] or 1 }, duration or 0.3)
		end
	end
	return glow
end

---------------------------------------------------------------------
-- Window
---------------------------------------------------------------------
function UILib:CreateWindow(opts)
	opts = opts or {}
	local self = setmetatable({}, Window)
	self.Tabs = {}
	self.Minimized = false
	self.Hidden = false
	self.HideKey = opts.HideKey or opts.MinimizeKey or Enum.KeyCode.RightShift
	self._title = opts.Title or "UI Library"
	self._onClose = opts.OnClose
	self._conns = {}
	self._capturing = false
	self._hideListening = false
	self._confirming = false
	self._destroyed = false
	self._query = ""
	self._dirty = true
	self._token = 0

	local startSize = opts.Size or UDim2.fromOffset(540, 380)
	local maxSize = opts.MaxSize or UDim2.fromOffset(920, 640)
	self._minW, self._minH = startSize.X.Offset, startSize.Y.Offset
	self._maxW = math.max(maxSize.X.Offset, self._minW)
	self._maxH = math.max(maxSize.Y.Offset, self._minH)
	self._w, self._h = self._minW, self._minH -- current (un-minimized) size

	self._gui = new("ScreenGui", {
		Name = "UILib",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 100,
		Parent = Players.LocalPlayer:WaitForChild("PlayerGui"),
	})

	-- Root holds size/position + the outline. Main is a CanvasGroup so the
	-- whole window clips to its rounded corners and can fade as one piece.
	self._rootStroke = stroke(Theme.Stroke)
	local root = new("Frame", {
		Name = "Root",
		Size = UDim2.fromOffset(self._w, TOPBAR_H),
		Position = UDim2.new(0.5, -math.floor(self._w / 2), 0.5, -math.floor(self._h / 2)),
		BackgroundTransparency = 1,
		Parent = self._gui,
	}, { corner(10), self._rootStroke })
	self._root = root

	local main = new("CanvasGroup", {
		Name = "Main",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.Background,
		BorderSizePixel = 0,
		Parent = root,
	}, { corner(10) })
	self._main = main

	-- Top bar -------------------------------------------------------
	local topbar = new("Frame", {
		Name = "Topbar",
		Size = UDim2.new(1, 0, 0, TOPBAR_H),
		BackgroundTransparency = 1,
		Parent = main,
	})
	label({
		Text = self._title,
		Font = FONT_BOLD,
		Position = UDim2.fromOffset(14, 0),
		Size = UDim2.new(1, -350, 1, 0),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = topbar,
	})
	new("Frame", {
		Position = UDim2.new(0, 8, 1, -1),
		Size = UDim2.new(1, -16, 0, 1),
		BackgroundColor3 = Theme.Stroke,
		BorderSizePixel = 0,
		Parent = topbar,
	})

	-- Right-hand cluster (laid out automatically): search, hide chip, shrink, close
	local right = new("Frame", {
		Name = "Right",
		Position = UDim2.fromOffset(8, 0),
		Size = UDim2.new(1, -16, 1, 0),
		BackgroundTransparency = 1,
		Parent = topbar,
	}, {
		new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 6),
		}),
	})

	-- search box
	local search = new("TextBox", {
		Name = "Search",
		LayoutOrder = 1,
		Size = UDim2.fromOffset(130, 22),
		BackgroundColor3 = Theme.Element,
		Text = "",
		PlaceholderText = "Search...",
		PlaceholderColor3 = Theme.SubText,
		TextColor3 = Theme.Text,
		TextSize = 13,
		Font = FONT,
		TextXAlignment = Enum.TextXAlignment.Left,
		ClearTextOnFocus = false,
		ClipsDescendants = true,
		Parent = right,
	}, { corner(6), padding(8, 0, 8, 0) })
	local searchStroke = stroke(Theme.Stroke)
	searchStroke.Parent = search
	self._search = search
	search.Focused:Connect(function()
		tween(searchStroke, { Color = Theme.Accent }, 0.15)
	end)
	search.FocusLost:Connect(function()
		tween(searchStroke, { Color = Theme.Stroke }, 0.15)
	end)
	search:GetPropertyChangedSignal("Text"):Connect(function()
		self:_applySearch(search.Text)
	end)

	-- hide-key chip, click to rebind
	local chip = new("TextButton", {
		LayoutOrder = 2,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 22),
		BackgroundColor3 = Theme.Element,
		Text = "",
		TextSize = 12,
		Font = FONT,
		TextColor3 = Theme.SubText,
		AutoButtonColor = false,
		Parent = right,
	}, { corner(6), padding(8, 0, 8, 0) })
	hover(chip, chip, Theme.Element, Theme.ElementHover)
	self._chip = chip
	self:_refreshChip()

	chip.MouseButton1Click:Connect(function()
		if self._hideListening then
			self._hideListening = false
			self:_refreshChip()
			self:_endCapture()
		else
			self._hideListening = true
			self:_refreshChip()
			self:_beginCapture(function()
				self._hideListening = false
				self:_refreshChip()
			end)
		end
	end)

	-- shrink button (icon is drawn, so it never depends on font glyphs)
	local minBtn = new("TextButton", {
		LayoutOrder = 3,
		Size = UDim2.fromOffset(28, 24),
		BackgroundColor3 = Theme.Element,
		Text = "",
		AutoButtonColor = false,
		Parent = right,
	}, { corner(6) })
	hover(minBtn, minBtn, Theme.Element, Theme.ElementHover)
	new("Frame", {
		Size = UDim2.fromOffset(12, 2),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		BackgroundColor3 = Theme.Text,
		BorderSizePixel = 0,
		Parent = minBtn,
	}, { corner(1) })
	self._vBar = new("Frame", { -- grows in to turn "–" into "+"
		Size = UDim2.fromOffset(2, 0),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		BackgroundColor3 = Theme.Text,
		BorderSizePixel = 0,
		Parent = minBtn,
	}, { corner(1) })
	minBtn.MouseButton1Click:Connect(function()
		self:ToggleMinimized()
	end)

	-- close button (drawn X): hides the UI and asks for confirmation
	local closeBtn = new("TextButton", {
		LayoutOrder = 4,
		Size = UDim2.fromOffset(28, 24),
		BackgroundColor3 = Theme.Element,
		Text = "",
		AutoButtonColor = false,
		Parent = right,
	}, { corner(6) })
	hover(closeBtn, closeBtn, Theme.Element, Theme.Danger)
	for _, rot in ipairs({ 45, -45 }) do
		new("Frame", {
			Size = UDim2.fromOffset(13, 2),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Rotation = rot,
			BackgroundColor3 = Theme.Text,
			BorderSizePixel = 0,
			Parent = closeBtn,
		}, { corner(1) })
	end
	closeBtn.MouseButton1Click:Connect(function()
		self:RequestClose()
	end)

	-- Body ----------------------------------------------------------
	local body = new("Frame", {
		Name = "Body",
		Position = UDim2.fromOffset(0, TOPBAR_H),
		Size = UDim2.new(1, 0, 0, self._h - TOPBAR_H),
		BackgroundTransparency = 1,
		Parent = main,
	})
	self._body = body

	self._sidebar = new("Frame", {
		Position = UDim2.fromOffset(8, 8),
		Size = UDim2.new(0, 116, 1, -(8 + BOTTOM_MARGIN)),
		BackgroundColor3 = Theme.Panel,
		BorderSizePixel = 0,
		Parent = body,
	}, { corner(8), padding(6, 6, 6, 6) })

	self._pages = new("Frame", {
		Position = UDim2.fromOffset(132, 8),
		Size = UDim2.new(1, -140, 1, -(8 + BOTTOM_MARGIN)),
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		Parent = body,
	})

	self._noResults = label({
		Name = "NoResults",
		Text = "No results",
		TextColor3 = Theme.SubText,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.new(1, 0, 0, 40),
		Position = UDim2.fromOffset(0, 24),
		Visible = false,
		ZIndex = 2,
		Parent = self._pages,
	})

	-- Resize grip (bottom-right) -------------------------------------
	local grip = new("TextButton", {
		Name = "Grip",
		Size = UDim2.fromOffset(18, 18),
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -3, 1, -3),
		BackgroundTransparency = 1,
		Text = "",
		ZIndex = 5,
		Parent = main,
	})
	self._grip = grip
	local gripLines = {}
	for _, spec in ipairs({ { 14, 5 }, { 9, 12 } }) do -- {center, length}
		table.insert(
			gripLines,
			new("Frame", {
				Size = UDim2.fromOffset(spec[2], 2),
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromOffset(spec[1], spec[1]),
				Rotation = -45,
				BackgroundColor3 = Theme.SubText,
				BorderSizePixel = 0,
				Parent = grip,
			}, { corner(1) })
		)
	end
	local resizing, rStart, rW, rH = false, nil, 0, 0
	local function gripColor(c)
		for _, l in ipairs(gripLines) do
			tween(l, { BackgroundColor3 = c }, 0.15)
		end
	end
	grip.MouseEnter:Connect(function()
		gripColor(Theme.Text)
	end)
	grip.MouseLeave:Connect(function()
		if not resizing then
			gripColor(Theme.SubText)
		end
	end)
	grip.InputBegan:Connect(function(input)
		if isPointer(input) and not self.Minimized then
			resizing = true
			rStart = input.Position
			rW, rH = self._w, self._h
			gripColor(Theme.Accent)
			local conn
			conn = input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					resizing = false
					conn:Disconnect()
					gripColor(Theme.SubText)
				end
			end)
		end
	end)
	self:_connect(UserInputService.InputChanged, function(input)
		if resizing and isMove(input) then
			local d = input.Position - rStart
			self:_resizeTo(rW + d.X, rH + d.Y)
		end
	end)

	-- Dragging the window by its title bar ----------------------------
	local dragging, dragStart, startPos = false, nil, nil
	topbar.InputBegan:Connect(function(input)
		if isPointer(input) then
			dragging = true
			dragStart = input.Position
			startPos = root.Position
			local conn
			conn = input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
					conn:Disconnect()
				end
			end)
		end
	end)
	self:_connect(UserInputService.InputChanged, function(input)
		if dragging and isMove(input) then
			local delta = input.Position - dragStart
			root.Position = UDim2.new(
				startPos.X.Scale, startPos.X.Offset + delta.X,
				startPos.Y.Scale, startPos.Y.Offset + delta.Y
			)
		end
	end)

	-- Hide shortcut (also handles rebinding the hide key) -------------
	self:_connect(UserInputService.InputBegan, function(input, gameProcessed)
		if input.UserInputType ~= Enum.UserInputType.Keyboard then
			return
		end
		if self._hideListening then
			self._hideListening = false
			if input.KeyCode ~= Enum.KeyCode.Backspace and input.KeyCode ~= Enum.KeyCode.Unknown then
				self.HideKey = input.KeyCode
			end
			self:_refreshChip()
			self:_endCapture()
			return
		end
		if gameProcessed or self._capturing or self._confirming then
			return
		end
		if input.KeyCode == self.HideKey then
			self:ToggleHidden()
		end
	end)

	-- Layout pump: re-flows the active tab whenever something changed
	self:_connect(RunService.Heartbeat, function(dt)
		if self._dirty then
			self._dirty = false
			local tab = self._active
			if tab then
				tab:_layout(math.min(dt, 1 / 20))
			end
		end
	end)

	-- Opening animation
	tween(root, { Size = UDim2.fromOffset(self._w, self._h) }, 0.45, Enum.EasingStyle.Back)

	return self
end

function Window:_connect(signal, fn)
	local conn = signal:Connect(fn)
	table.insert(self._conns, conn)
	return conn
end

function Window:_refreshChip()
	local name = self._hideListening and "..." or self.HideKey.Name
	self._chip.Text = "Hide: " .. name
	tween(self._chip, { TextColor3 = self._hideListening and Theme.Accent or Theme.SubText }, 0.15)
end

-- Only one keybind box may wait for a key at a time.
function Window:_beginCapture(cancel)
	if self._cancelCapture then
		self._cancelCapture()
	end
	self._cancelCapture = cancel
	self._capturing = true
end

function Window:_endCapture()
	self._cancelCapture = nil
	task.defer(function() -- defer so the key that ended capture doesn't also trigger a bind
		if not self._cancelCapture then
			self._capturing = false
		end
	end)
end

function Window:_resizeTo(w, h)
	if self.Minimized then
		return
	end
	local gui = self._gui.AbsoluteSize
	local pos = self._root.Position
	local left = pos.X.Scale * gui.X + pos.X.Offset
	local top = pos.Y.Scale * gui.Y + pos.Y.Offset
	-- never grow past the max size or off the edge of the screen
	local maxW = math.max(self._minW, math.min(self._maxW, gui.X - left - 8))
	local maxH = math.max(self._minH, math.min(self._maxH, gui.Y - top - 8))
	w = math.floor(math.clamp(w, self._minW, maxW) + 0.5)
	h = math.floor(math.clamp(h, self._minH, maxH) + 0.5)
	if w == self._w and h == self._h then
		return
	end
	self._w, self._h = w, h
	self._root.Size = UDim2.fromOffset(w, h)
	self._body.Size = UDim2.new(1, 0, 0, h - TOPBAR_H)
	self._dirty = true
end

function Window:SetHideKey(keyCode)
	self.HideKey = keyCode
	self:_refreshChip()
end

function Window:GetHideKey()
	return self.HideKey
end

function Window:SetHidden(state)
	state = state and true or false
	if self.Hidden == state then
		return
	end
	self.Hidden = state
	self._token += 1
	local token = self._token
	local root = self._root

	if state then
		self._home = root.Position
		tween(self._main, { GroupTransparency = 1 }, 0.22, Enum.EasingStyle.Quad)
		tween(self._rootStroke, { Transparency = 1 }, 0.22, Enum.EasingStyle.Quad)
		tween(root, { Position = self._home + UDim2.fromOffset(0, 16) }, 0.25)
		task.delay(0.28, function()
			if self.Hidden and self._token == token and not self._destroyed then
				self._gui.Enabled = false
				root.Position = self._home
			end
		end)
	else
		if not self._gui.Enabled then
			self._gui.Enabled = true
			root.Position = self._home + UDim2.fromOffset(0, 16)
		end
		self._dirty = true
		tween(self._main, { GroupTransparency = 0 }, 0.3, Enum.EasingStyle.Quad)
		tween(self._rootStroke, { Transparency = 0 }, 0.3, Enum.EasingStyle.Quad)
		tween(root, { Position = self._home }, 0.35)
	end
end

function Window:ToggleHidden()
	self:SetHidden(not self.Hidden)
end

function Window:SetMinimized(state)
	state = state and true or false
	if self.Minimized == state then
		return
	end
	self.Minimized = state
	tween(self._vBar, { Size = UDim2.fromOffset(2, state and 12 or 0) }, 0.25)
	self._grip.Visible = not state

	if state then
		local t = tween(self._root, { Size = UDim2.fromOffset(self._w, TOPBAR_H) }, 0.3)
		t.Completed:Connect(function()
			if self.Minimized then
				self._body.Visible = false
			end
		end)
	else
		self._body.Visible = true
		self._dirty = true
		tween(self._root, { Size = UDim2.fromOffset(self._w, self._h) }, 0.4, Enum.EasingStyle.Back)
	end
end

function Window:ToggleMinimized()
	self:SetMinimized(not self.Minimized)
end

---------------------------------------------------------------------
-- Close: X button -> UI slides away -> small "are you sure?" window
---------------------------------------------------------------------
function Window:RequestClose()
	if self._confirming or self._destroyed then
		return
	end
	self._confirming = true
	self:SetHidden(true)

	local gui = new("ScreenGui", {
		Name = "UILibConfirm",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 200,
		IgnoreGuiInset = true,
		Parent = self._gui.Parent,
	})
	self._confirmGui = gui

	local outline = stroke(Theme.Stroke)
	outline.Transparency = 1
	local dialog = new("Frame", {
		Size = UDim2.fromOffset(320, 138),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 14),
		BackgroundTransparency = 1,
		Parent = gui,
	}, { corner(10), outline })
	local box = new("CanvasGroup", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.Background,
		BorderSizePixel = 0,
		GroupTransparency = 1,
		Parent = dialog,
	}, { corner(10) })

	label({
		Text = "Close " .. self._title .. "?",
		Font = FONT_BOLD,
		TextSize = 17,
		Position = UDim2.fromOffset(16, 14),
		Size = UDim2.new(1, -32, 0, 24),
		Parent = box,
	})
	label({
		Text = "This stops the script and removes the UI completely.",
		TextColor3 = Theme.SubText,
		TextSize = 13,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(16, 42),
		Size = UDim2.new(1, -32, 0, 36),
		Parent = box,
	})

	local function makeButton(text, color, overColor, position)
		local b = new("TextButton", {
			Text = text,
			Font = FONT_BOLD,
			TextSize = 14,
			TextColor3 = Color3.new(1, 1, 1),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Position = position,
			Size = UDim2.new(0.5, -21, 0, 34),
			Parent = box,
		}, { corner(6) })
		hover(b, b, color, overColor)
		return b
	end
	local closeBtn = makeButton("Close", Theme.Danger, Theme.DangerHover, UDim2.new(0, 16, 1, -50))
	local backBtn = makeButton("Go Back", Theme.Element, Theme.ElementHover, UDim2.new(0.5, 5, 1, -50))

	tween(box, { GroupTransparency = 0 }, 0.25, Enum.EasingStyle.Quad)
	tween(outline, { Transparency = 0 }, 0.25, Enum.EasingStyle.Quad)
	tween(dialog, { Position = UDim2.fromScale(0.5, 0.5) }, 0.3)

	closeBtn.MouseButton1Click:Connect(function()
		self:Close()
	end)
	backBtn.MouseButton1Click:Connect(function()
		self._confirming = false
		self._confirmGui = nil
		tween(box, { GroupTransparency = 1 }, 0.2, Enum.EasingStyle.Quad)
		tween(outline, { Transparency = 1 }, 0.2, Enum.EasingStyle.Quad)
		tween(dialog, { Position = UDim2.new(0.5, 0, 0.5, 14) }, 0.2)
		task.delay(0.25, function()
			if gui.Parent then
				gui:Destroy()
			end
		end)
		self:SetHidden(false)
	end)
end

-- Runs your OnClose cleanup, then destroys the window (no prompt).
function Window:Close()
	if self._destroyed then
		return
	end
	local fn = self._onClose
	self._onClose = nil
	if fn then
		local ok, err = pcall(fn)
		if not ok then
			warn("UILib OnClose error: " .. tostring(err))
		end
	end
	self:Destroy()
end

function Window:Destroy()
	if self._destroyed then
		return
	end
	self._destroyed = true
	for _, c in ipairs(self._conns) do
		c:Disconnect()
	end
	table.clear(self._conns)
	if self._confirmGui then
		self._confirmGui:Destroy()
		self._confirmGui = nil
	end
	self._gui:Destroy()
end

---------------------------------------------------------------------
-- Search: dims non-matching items (they collapse away) across all tabs
---------------------------------------------------------------------
function Window:_applySearch(text)
	local q = string.lower(text or ""):match("^%s*(.-)%s*$")
	self._query = q
	local searching = q ~= ""

	local total, firstTab, activeHas = 0, nil, false
	for _, tab in ipairs(self.Tabs) do
		local count = 0
		for _, item in ipairs(tab._items) do
			local match = not searching or string.find(item.Search or "", q, 1, true) ~= nil
			tween(item.Filter, { Value = match and 1 or 0 }, 0.25)
			if match then
				count += 1
			end
		end
		total += count
		if count > 0 and not firstTab then
			firstTab = tab
		end
		if tab == self._active and count > 0 then
			activeHas = true
		end
		tween(tab.Button, { TextTransparency = (searching and count == 0) and 0.65 or 0 }, 0.2)
	end

	self._noResults.Text = searching and ('No results for "' .. q .. '"') or "No results"
	self._noResults.Visible = searching and total == 0

	if searching and not activeHas and firstTab then
		self:SelectTab(firstTab)
	end
	self._dirty = true
end

function Window:SelectTab(tab)
	if self._active == tab then
		return
	end
	self._active = tab

	for _, t in ipairs(self.Tabs) do
		local on = (t == tab)
		tween(t.Button, {
			BackgroundTransparency = on and 0.5 or 1,
			TextColor3 = on and Theme.Text or Theme.SubText,
		}, 0.2)
		t.Glow.Set(on)
		if not on then
			t.Page.Visible = false
		end
	end

	tab._needsSnap = true -- lay out instantly (no re-flow animation) when a tab is shown
	tab.Page.Position = UDim2.fromOffset(0, 16)
	tab.Page.Visible = true
	tween(tab.Page, { Position = UDim2.fromOffset(0, 0) }, 0.3)
	self._dirty = true
end

function Window:AddTab(name)
	local tab = setmetatable({
		Window = self,
		Name = name,
		Index = #self.Tabs + 1,
		_items = {},
		_needsSnap = true,
	}, Tab)

	tab.Button = new("TextButton", {
		Name = name,
		Size = UDim2.new(1, 0, 0, TAB_H),
		Position = UDim2.fromOffset(0, (tab.Index - 1) * (TAB_H + TAB_GAP)),
		BackgroundColor3 = Theme.Element,
		BackgroundTransparency = 1,
		Text = name,
		Font = FONT,
		TextSize = 14,
		TextColor3 = Theme.SubText,
		AutoButtonColor = false,
		Parent = self._sidebar,
	}, { corner(6) })
	tab.Glow = addGlow(tab.Button, 6, GLOW_SOFT)

	tab.Page = new("ScrollingFrame", {
		Name = name,
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = Theme.Accent,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		CanvasSize = UDim2.new(),
		Visible = false,
		Parent = self._pages,
	})

	tab.Button.MouseEnter:Connect(function()
		if self._active ~= tab then
			tween(tab.Button, { BackgroundTransparency = 0.75 }, 0.15)
		end
	end)
	tab.Button.MouseLeave:Connect(function()
		if self._active ~= tab then
			tween(tab.Button, { BackgroundTransparency = 1 }, 0.15)
		end
	end)
	tab.Button.MouseButton1Click:Connect(function()
		self:SelectTab(tab)
	end)

	table.insert(self.Tabs, tab)
	if #self.Tabs == 1 then
		self:SelectTab(tab)
	end
	return tab
end

---------------------------------------------------------------------
-- Tab: items + layout engine
--
-- Items are absolutely positioned by :_layout(), not a UIListLayout, so the
-- 1-column <-> 2-column switch can be animated. When the column count
-- changes we snapshot every item's current rect and blend from it to the
-- live target rect (which keeps updating), so it stays smooth even if you
-- keep dragging or a dropdown is opening mid-transition.
---------------------------------------------------------------------
function Tab:_element(height, showWhen, name)
	local frame = new("Frame", {
		Size = UDim2.fromOffset(200, height),
		BackgroundColor3 = Theme.Element,
		BorderSizePixel = 0,
		Visible = false, -- shown by the first layout pass (avoids a 1-frame flash at 0,0)
		Parent = self.Page,
	}, { corner(6) })

	local item = {
		Frame = frame,
		Base = height, -- nominal height, used for stable column assignment
		Height = new("NumberValue", { Value = height, Parent = frame }), -- tweenable live height
		Search = string.lower(name or ""), -- text the search box matches against
	}
	item.Height.Changed:Connect(function()
		self.Window._dirty = true
	end)

	-- Filter (0..1) is driven by the search box: 0 collapses the item away.
	item.Filter = new("NumberValue", { Value = 1, Parent = frame })
	item.Filter.Changed:Connect(function()
		self.Window._dirty = true
	end)

	-- Reveal (0..1) scales the item's height and gap. Items created with
	-- ShowWhen = <toggle> animate it as the toggle flips, so they slide
	-- open/closed and stay in their toggle's column.
	local shown = true
	if showWhen then
		shown = showWhen:Get()
		item.Follow = showWhen._item
	end
	item.Reveal = new("NumberValue", { Value = shown and 1 or 0, Parent = frame })
	item.Reveal.Changed:Connect(function()
		self.Window._dirty = true
	end)
	if showWhen then
		showWhen:OnChanged(function(on)
			tween(item.Reveal, { Value = on and 1 or 0 }, 0.35)
		end)
	end
	table.insert(self._items, item)
	self.Window._dirty = true
	return frame, item
end

function Tab:_layout(dt)
	local page = self.Page
	local availW = page.AbsoluteSize.X - PAD_L - PAD_R
	if availW <= 0 then
		self.Window._dirty = true -- not laid out by the engine yet, try next frame
		return
	end

	local items = self._items
	local threshold = MIN_COL_W * 2 + COL_GAP
	local cols = self._cols

	if cols == nil or self._needsSnap then
		cols = availW >= threshold and 2 or 1
		self._cols = cols
		self._needsSnap = false
		self._blend, self._from, self._fromCanvas = nil, nil, nil
	else
		local newCols = cols
		if cols == 1 and availW >= threshold + SPLIT_HYST then
			newCols = 2
		elseif cols == 2 and availW < threshold - SPLIT_HYST then
			newCols = 1
		end
		if newCols ~= cols then
			self._from = {}
			for _, item in ipairs(items) do
				local f = item.Frame
				self._from[item] = {
					x = f.Position.X.Offset,
					y = f.Position.Y.Offset,
					w = f.Size.X.Offset,
					h = f.Size.Y.Offset,
				}
			end
			self._fromCanvas = page.CanvasSize.Y.Offset
			self._blend = 0
			cols = newCols
			self._cols = cols
		end
	end

	-- stable column assignment from nominal heights (balanced, reading order)
	local assign, baseH, colOf = {}, { 0, 0 }, {}
	for i, item in ipairs(items) do
		local c = 1
		if cols == 2 then
			if item.Follow and colOf[item.Follow] then
				c = colOf[item.Follow] -- gated items stay under their toggle
			elseif baseH[2] < baseH[1] then
				c = 2
			end
		end
		assign[i] = c
		colOf[item] = c
		baseH[c] += item.Base + ITEM_GAP
	end

	-- live target rects
	local colW = (availW - COL_GAP * (cols - 1)) / cols
	local y = { PAD_T, PAD_T }
	local targets = {}
	for i, item in ipairs(items) do
		local c = assign[i]
		local r = item.Reveal.Value * item.Filter.Value -- gate x search
		local h = item.Height.Value * r
		targets[i] = { x = PAD_L + (c - 1) * (colW + COL_GAP), y = y[c], w = colW, h = h, r = r }
		y[c] += h + ITEM_GAP * r
	end
	local canvasH = math.max(y[1], y[2]) - ITEM_GAP + PAD_B

	-- blend
	local a = 1
	if self._blend then
		self._blend = math.min(self._blend + dt / BLEND_TIME, 1)
		a = ease(self._blend)
	end

	for i, item in ipairs(items) do
		local t = targets[i]
		local x, yy, w, h = t.x, t.y, t.w, t.h
		local f = self._from and self._from[item]
		if f and a < 1 then
			x = f.x + (x - f.x) * a
			yy = f.y + (yy - f.y) * a
			w = f.w + (w - f.w) * a
			h = f.h + (h - f.h) * a
		end
		local fr = item.Frame
		fr.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(yy + 0.5))
		fr.Size = UDim2.fromOffset(math.floor(w + 0.5), math.floor(h + 0.5))
		local visible = t.r > 0.001 -- fully collapsed items are hidden, so they can't be clicked
		if fr.Visible ~= visible then
			fr.Visible = visible
		end
		local clip = item.KeepClip or t.r < 0.999 -- clip only while sliding, so glows aren't cut off
		if fr.ClipsDescendants ~= clip then
			fr.ClipsDescendants = clip
		end
	end

	if self._blend and a < 1 and self._fromCanvas then
		canvasH = self._fromCanvas + (canvasH - self._fromCanvas) * a
	end
	page.CanvasSize = UDim2.fromOffset(0, math.floor(canvasH + 0.5))

	if self._blend then
		if self._blend >= 1 then
			self._blend, self._from, self._fromCanvas = nil, nil, nil
		else
			self.Window._dirty = true -- keep animating next frame
		end
	end
end

---------------------------------------------------------------------
-- Label
---------------------------------------------------------------------
function Tab:AddLabel(text, opts)
	local frame, item = self:_element(28, opts and opts.ShowWhen, text)
	local lbl = label({
		Text = text or "",
		TextColor3 = Theme.SubText,
		TextSize = 13,
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -24, 1, 0),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = frame,
	})
	local obj = { Frame = frame }
	function obj:Set(t)
		lbl.Text = t
		item.Search = string.lower(t or "")
	end
	return obj
end

---------------------------------------------------------------------
-- Button
---------------------------------------------------------------------
function Tab:AddButton(opts)
	opts = opts or {}
	local frame = self:_element(36, opts.ShowWhen, opts.Name)
	local btn = new("TextButton", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = opts.Name or "Button",
		Font = FONT,
		TextSize = 14,
		TextColor3 = Theme.Text,
		Parent = frame,
	})
	hover(btn, frame, Theme.Element, Theme.ElementHover)
	btn.MouseButton1Click:Connect(function()
		frame.BackgroundColor3 = Theme.Accent
		tween(frame, { BackgroundColor3 = Theme.ElementHover }, 0.35)
		fire(opts.Callback)
	end)
	return { Frame = frame }
end

---------------------------------------------------------------------
-- Toggle (with settable keybind + glow when on)
---------------------------------------------------------------------
function Tab:AddToggle(opts)
	opts = opts or {}
	local win = self.Window
	local state = opts.Default == true
	local key = opts.Keybind

	local frame, item = self:_element(38, opts.ShowWhen, opts.Name)
	local hit = new("TextButton", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "",
		Parent = frame,
	})
	hover(hit, frame, Theme.Element, Theme.ElementHover)

	label({
		Text = opts.Name or "Toggle",
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -150, 1, 0),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = frame,
	})

	local switch = new("Frame", {
		Size = UDim2.fromOffset(38, 20),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		BackgroundColor3 = Theme.Off,
		BorderSizePixel = 0,
		Parent = frame,
	}, { corner(10) })
	local glow = addGlow(switch, 10, GLOW_STRONG)
	local knob = new("Frame", {
		Size = UDim2.fromOffset(14, 14),
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 3, 0.5, 0),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Parent = switch,
	}, { corner(7) })

	local keyBtn = new("TextButton", {
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 22),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -58, 0.5, 0),
		BackgroundColor3 = Theme.Background,
		Text = key and key.Name or "None",
		TextSize = 12,
		Font = FONT,
		TextColor3 = Theme.SubText,
		AutoButtonColor = false,
		Parent = frame,
	}, { corner(5), padding(8, 0, 8, 0) })

	local subs = {}
	local obj = { Frame = frame, _item = item }
	function obj:OnChanged(fn)
		table.insert(subs, fn)
	end

	local function render(animate)
		local d = animate and 0.2 or 0
		tween(switch, { BackgroundColor3 = state and Theme.Accent or Theme.Off }, d)
		tween(knob, {
			Position = state and UDim2.new(1, -17, 0.5, 0) or UDim2.new(0, 3, 0.5, 0),
		}, d, Enum.EasingStyle.Back)
		glow.Set(state, animate and 0.3 or 0)
	end
	render(false)

	function obj:Set(v, silent)
		v = v and true or false
		if v == state then
			return
		end
		state = v
		render(true)
		for _, fn in ipairs(subs) do
			task.spawn(fn, state)
		end
		if not silent then
			fire(opts.Callback, state)
		end
	end
	function obj:Get()
		return state
	end
	function obj:SetKey(k)
		key = k
		keyBtn.Text = k and k.Name or "None"
	end
	function obj:GetKey()
		return key
	end

	hit.MouseButton1Click:Connect(function()
		obj:Set(not state)
	end)

	-- keybind capture
	local listening = false
	local function refreshKey()
		keyBtn.Text = listening and "..." or (key and key.Name or "None")
		tween(keyBtn, { TextColor3 = listening and Theme.Accent or Theme.SubText }, 0.15)
	end

	keyBtn.MouseButton1Click:Connect(function()
		if listening then
			listening = false
			refreshKey()
			win:_endCapture()
		else
			listening = true
			refreshKey()
			win:_beginCapture(function()
				listening = false
				refreshKey()
			end)
		end
	end)

	win:_connect(UserInputService.InputBegan, function(input, gameProcessed)
		if input.UserInputType ~= Enum.UserInputType.Keyboard then
			return
		end
		if listening then
			listening = false
			if input.KeyCode == Enum.KeyCode.Backspace then
				obj:SetKey(nil)
			elseif input.KeyCode ~= Enum.KeyCode.Unknown then
				obj:SetKey(input.KeyCode)
			end
			refreshKey()
			win:_endCapture()
			return
		end
		if gameProcessed or win._capturing then
			return
		end
		if key and input.KeyCode == key then
			obj:Set(not state)
		end
	end)

	return obj
end

---------------------------------------------------------------------
-- Slider (drag bar + typed value box)
---------------------------------------------------------------------
function Tab:AddSlider(opts)
	opts = opts or {}
	local win = self.Window
	local min = opts.Min or 0
	local max = opts.Max or 100
	local inc = opts.Increment or 1
	local dec = decimalsOf(inc)
	local value

	local function snap(v)
		v = math.clamp(v, min, max)
		v = min + math.floor((v - min) / inc + 0.5) * inc
		v = math.clamp(v, min, max)
		return tonumber(string.format("%." .. dec .. "f", v))
	end

	local frame = self:_element(56, opts.ShowWhen, opts.Name)
	label({
		Text = opts.Name or "Slider",
		Position = UDim2.fromOffset(12, 6),
		Size = UDim2.new(1, -90, 0, 22),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = frame,
	})
	local box = new("TextBox", {
		Size = UDim2.fromOffset(60, 22),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 6),
		BackgroundColor3 = Theme.Background,
		Text = "",
		TextSize = 13,
		Font = FONT,
		TextColor3 = Theme.Text,
		ClearTextOnFocus = false,
		Parent = frame,
	}, { corner(5), stroke(Theme.Stroke) })

	local track = new("Frame", {
		Position = UDim2.new(0, 12, 0, 40),
		Size = UDim2.new(1, -24, 0, 6),
		BackgroundColor3 = Theme.Off,
		BorderSizePixel = 0,
		Parent = frame,
	}, { corner(3) })
	local fill = new("Frame", {
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = Theme.Accent,
		BorderSizePixel = 0,
		Parent = track,
	}, { corner(3) })
	local knob = new("Frame", {
		Size = UDim2.fromOffset(14, 14),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		ZIndex = 2,
		Parent = track,
	}, { corner(7) })
	local knobGlow = addGlow(knob, 7, GLOW_SOFT)
	local hit = new("TextButton", {
		Position = UDim2.new(0, 12, 0, 30),
		Size = UDim2.new(1, -24, 0, 26),
		BackgroundTransparency = 1,
		Text = "",
		ZIndex = 3,
		Parent = frame,
	})

	local obj = { Frame = frame }

	local function set(v, silent)
		local nv = snap(v)
		local alpha = max > min and (nv - min) / (max - min) or 0
		tween(fill, { Size = UDim2.fromScale(alpha, 1) }, 0.1, Enum.EasingStyle.Quad)
		tween(knob, { Position = UDim2.fromScale(alpha, 0.5) }, 0.1, Enum.EasingStyle.Quad)
		box.Text = tostring(nv)
		if nv ~= value then
			value = nv
			if not silent then
				fire(opts.Callback, nv)
			end
		end
	end

	function obj:Set(v, silent)
		set(tonumber(v) or min, silent)
	end
	function obj:Get()
		return value
	end

	set(opts.Default or min, true)

	local dragging = false
	local function fromInput(input)
		local a = math.clamp((input.Position.X - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
		set(min + (max - min) * a)
	end
	hit.InputBegan:Connect(function(input)
		if isPointer(input) then
			dragging = true
			tween(knob, { Size = UDim2.fromOffset(18, 18) }, 0.15, Enum.EasingStyle.Back)
			knobGlow.Set(true, 0.2)
			fromInput(input)
		end
	end)
	win:_connect(UserInputService.InputChanged, function(input)
		if dragging and isMove(input) then
			fromInput(input)
		end
	end)
	win:_connect(UserInputService.InputEnded, function(input)
		if dragging and isPointer(input) then
			dragging = false
			tween(knob, { Size = UDim2.fromOffset(14, 14) }, 0.15)
			knobGlow.Set(false, 0.3)
		end
	end)

	-- typed value (clamped to range + snapped to increment)
	box.FocusLost:Connect(function()
		local n = tonumber(box.Text)
		if n then
			set(n)
		else
			box.Text = tostring(value)
		end
	end)

	return obj
end

---------------------------------------------------------------------
-- Dropdowns (single + multi share one implementation)
---------------------------------------------------------------------
local function buildDropdown(tab, opts, multi)
	opts = opts or {}
	local options = {}
	for _, o in ipairs(opts.Options or {}) do
		table.insert(options, tostring(o))
	end

	local selected = {} -- multi: name -> true
	local single = nil -- single: name
	local isOpen = false
	local buttons = {}
	local listH = 0

	local frame, item = tab:_element(HEADER_H, opts.ShowWhen, opts.Name)
	frame.ClipsDescendants = true
	item.KeepClip = true -- the open/close animation always needs clipping

	local header = new("TextButton", {
		Size = UDim2.new(1, 0, 0, HEADER_H),
		BackgroundTransparency = 1,
		Text = "",
		Parent = frame,
	})
	hover(header, frame, Theme.Element, Theme.ElementHover)

	label({
		Text = opts.Name or "Dropdown",
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(0.5, -12, 0, HEADER_H),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = frame,
	})
	local valueLabel = label({
		Position = UDim2.new(0.5, 0, 0, 0),
		Size = UDim2.new(0.5, -32, 0, HEADER_H),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = Theme.SubText,
		TextSize = 13,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = frame,
	})
	local arrow = label({
		Text = "▼",
		TextSize = 10,
		Position = UDim2.new(1, -24, 0, 0),
		Size = UDim2.fromOffset(14, HEADER_H),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = Theme.SubText,
		Parent = frame,
	})

	local list = new("ScrollingFrame", {
		Position = UDim2.fromOffset(8, HEADER_H + 2),
		Size = UDim2.new(1, -16, 0, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = Theme.Accent,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		Parent = frame,
	}, {
		new("UIListLayout", { Padding = UDim.new(0, OPT_GAP), SortOrder = Enum.SortOrder.LayoutOrder }),
	})

	local function getList()
		local out = {}
		for _, name in ipairs(options) do
			if selected[name] then
				table.insert(out, name)
			end
		end
		return out
	end

	local function headerText()
		if multi then
			local l = getList()
			if #l == 0 then
				return "None"
			elseif #l <= 2 then
				return table.concat(l, ", ")
			end
			return #l .. " selected"
		end
		return single or "Select..."
	end

	local function render()
		for name, b in pairs(buttons) do
			local on
			if multi then
				on = selected[name] == true
			else
				on = single == name
			end
			tween(b.btn, {
				BackgroundColor3 = on and Theme.AccentDim or Theme.Background,
				TextColor3 = on and Theme.Text or Theme.SubText,
			}, 0.15)
			if b.check then
				tween(b.check, { BackgroundTransparency = on and 0 or 1 }, 0.15)
				b.glow.Set(on, 0.25)
			end
		end
		valueLabel.Text = headerText()
	end

	local function setOpen(v)
		isOpen = v
		-- the layout engine reads item.Height every frame, so items below follow smoothly
		tween(item.Height, { Value = v and (HEADER_H + 2 + listH + 8) or HEADER_H }, 0.28)
		tween(arrow, { Rotation = v and 180 or 0 }, 0.28)
	end

	local obj = { Frame = frame }

	local function build()
		for _, c in ipairs(list:GetChildren()) do
			if c:IsA("TextButton") then
				c:Destroy()
			end
		end
		table.clear(buttons)

		for i, name in ipairs(options) do
			local children = { corner(5), padding(10, 0, 8, 0) }
			local check, glow
			if multi then
				check = new("Frame", {
					Size = UDim2.fromOffset(14, 14),
					AnchorPoint = Vector2.new(1, 0.5),
					Position = UDim2.new(1, 0, 0.5, 0),
					BackgroundColor3 = Theme.Accent,
					BackgroundTransparency = 1,
					BorderSizePixel = 0,
				}, { corner(4), stroke(Theme.Accent, 1) })
				glow = addGlow(check, 4, GLOW_SOFT)
				table.insert(children, check)
			end
			local btn = new("TextButton", {
				Name = name,
				LayoutOrder = i,
				Size = UDim2.new(1, -8, 0, OPT_H),
				BackgroundColor3 = Theme.Background,
				Text = name,
				Font = FONT,
				TextSize = 13,
				TextColor3 = Theme.SubText,
				TextXAlignment = Enum.TextXAlignment.Left,
				AutoButtonColor = false,
				Parent = list,
			}, children)
			buttons[name] = { btn = btn, check = check, glow = glow }

			btn.MouseButton1Click:Connect(function()
				if multi then
					selected[name] = (not selected[name]) or nil
					render()
					fire(opts.Callback, getList())
				else
					single = name
					render()
					setOpen(false)
					fire(opts.Callback, name)
				end
			end)
		end

		local count = #options
		listH = math.min(count > 0 and (count * (OPT_H + OPT_GAP) - OPT_GAP) or 0, MAX_LIST_H)
		list.Size = UDim2.new(1, -16, 0, listH)
		if isOpen then
			setOpen(true)
		end
		render()

		-- the search box matches the dropdown's name and its option names
		item.Search = string.lower((opts.Name or "") .. " " .. table.concat(options, " "))
		if tab.Window._query ~= "" then
			tab.Window:_applySearch(tab.Window._query)
		end
	end

	-- defaults
	if multi then
		for _, n in ipairs(opts.Default or {}) do
			selected[tostring(n)] = true
		end
	elseif opts.Default ~= nil and opts.Default ~= "" then
		single = tostring(opts.Default)
	end
	build()

	header.MouseButton1Click:Connect(function()
		setOpen(not isOpen)
	end)

	function obj:Get()
		if multi then
			return getList()
		end
		return single
	end
	function obj:Set(v, silent)
		if multi then
			selected = {}
			for _, n in ipairs(v or {}) do
				selected[tostring(n)] = true
			end
		else
			single = v ~= nil and tostring(v) or nil
		end
		render()
		if not silent then
			fire(opts.Callback, obj:Get())
		end
	end
	function obj:SetOptions(newOptions)
		options = {}
		for _, o in ipairs(newOptions or {}) do
			table.insert(options, tostring(o))
		end
		if multi then -- drop selections that no longer exist
			local keep = {}
			for _, n in ipairs(options) do
				if selected[n] then
					keep[n] = true
				end
			end
			selected = keep
		elseif single and not table.find(options, single) then
			single = nil
		end
		build()
	end
	function obj:SetOpen(v)
		setOpen(v and true or false)
	end

	return obj
end

function Tab:AddDropdown(opts)
	return buildDropdown(self, opts, false)
end

function Tab:AddMultiDropdown(opts)
	return buildDropdown(self, opts, true)
end

return UILib