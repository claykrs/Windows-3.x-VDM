--!nonstrict
-- MockHost.lua -- **MOCK** Win3 window/control adapter for the ScreenGui spike.
--
-- This is NOT a Windows 3.0 adapter. It never touches USER.EXE, GDI.EXE or
-- the guest. It exists to price the native-ScreenGui option: it accepts the
-- declarative state a native mapper could own (rectangles, styles, captions,
-- standard control kinds, menu item lists) and turns that into Roblox
-- instances.
--
-- Note what is missing on purpose: there is no paint callback, no HDC, no
-- pen/brush/font object, no clip region and no BitBlt. Those are the parts of
-- the Win16 API that cannot be projected onto a retained ScreenGui tree.
-- The hole in this API *is* the feasibility result; see FEASIBILITY.md.
--
-- API (mock; the guest call each method stands in for is in brackets):
--   MockHost.new(parent)                  -- desktop + 640x400 guest stage
--   host:createWindow(spec) -> MockWindow -- CreateWindowEx / WM_CREATE
--   host:openMenu(win, index)             -- TrackPopupMenu
--   host:closeMenu()                      -- menu-mode exit
--   win:setText(text)                     -- WM_SETTEXT / DefWindowProc
--   win:createControl(spec) -> MockControl -- CreateWindow("BUTTON", ...)
--   win:raise()                           -- WM_ACTIVATE / z-order
--   win:close()                           -- WM_CLOSE / DestroyWindow
--   control:setValue(value)               -- BM_SETCHECK / WM_SETTEXT / LB_SETCURSEL
--   control:getValue()
--
-- Coordinates are guest pixels relative to the stage (host), the window's
-- outer rect (win.rect) or the client area (control rects).

const UserInputService = game:GetService("UserInputService")

const Skin = require(script.Parent.Win3Skin)
const Colors = Skin.Colors
const Fonts = Skin.Fonts
const Metrics = Skin.Metrics

const MockHost = {}
MockHost.__index = MockHost

const MockWindow = {}
MockWindow.__index = MockWindow

const MockControl = {}
MockControl.__index = MockControl

export type Rect = { x: number, y: number, width: number, height: number }

export type MenuItem = {
	text: string?,
	accel: string?,
	separator: boolean?,
	disabled: boolean?,
	checked: boolean?,
	action: (() -> ())?,
}

export type MenuSpec = {
	title: string,
	items: { MenuItem },
}

export type WindowSpec = {
	title: string,
	rect: Rect,
	menu: { MenuSpec }?,
	clientColor: Color3?,
	onClose: (() -> ())?,
}

export type ControlSpec = {
	class: string, -- BUTTON | CHECKBOX | EDIT | STATIC | GROUPBOX | LISTBOX
	rect: Rect,
	text: string?,
	items: { string }?,
	selected: number?,
	checked: boolean?,
	wrap: boolean?,
	onClick: (() -> ())?,
	onChange: ((value: any) -> ())?,
}

type Bag = {
	connections: { RBXScriptConnection },
	instances: { Instance },
}

type Popup = {
	owner: MockWindow,
	index: number,
	frame: Frame,
	bag: Bag,
}

local function newBag(): Bag
	return { connections = {}, instances = {} }
end

local function track<T>(bag: Bag, instance: T): T
	bag.instances[#bag.instances + 1] = instance :: any
	return instance
end

local function connect(bag: Bag, signal: RBXScriptSignal, fn: (...any) -> ()): RBXScriptConnection
	const connection = signal:Connect(fn)
	bag.connections[#bag.connections + 1] = connection
	return connection
end

local function clean(bag: Bag)
	for _, connection in bag.connections do
		if connection.Connected then
			connection:Disconnect()
		end
	end
	for _, instance in bag.instances do
		if instance.Parent ~= nil then
			instance:Destroy()
		end
	end
	table.clear(bag.connections)
	table.clear(bag.instances)
end

local function measureMenu(items: { MenuItem }): { width: number, height: number }
	local width = 100
	local height = 4
	for _, item in items do
		if item.separator then
			height += 7
		else
			const accel = if item.accel then #item.accel * 6 + 16 else 0
			width = math.max(width, #(item.text or "") * 6 + 24 + accel)
			height += Metrics.MenuRow
		end
	end
	return { width = width, height = height }
end

function MockHost.new(parent: Instance): MockHost
	const self = setmetatable({}, MockHost) :: any
	self.windows = {}
	self.nextHwnd = 0
	self.nextZ = 10
	self.popup = nil
	self.menuOwner = nil
	self.menuWatcher = nil
	self.bag = newBag()

	self.desktop = track(
		self.bag,
		Skin.frame(parent, {
			Name = "GuiSpikeDesktop",
			BackgroundColor3 = Colors.Desktop,
			Size = UDim2.fromScale(1, 1),
		})
	)

	-- The stage is a fixed 640x400 guest-pixel canvas. Windows and popups are
	-- its children; one UIScale makes the whole thing fit the viewport.
	self.stage = track(
		self.bag,
		Skin.frame(self.desktop, {
			Name = "Stage",
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(Skin.StageWidth, Skin.StageHeight),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
		})
	)
	self.scale = track(self.bag, Instance.new("UIScale"))
	self.scale.Parent = self.stage

	self:updateScale()
	connect(self.bag, self.desktop:GetPropertyChangedSignal("AbsoluteSize"), function()
		self:updateScale()
	end)
	task.defer(function()
		self:updateScale()
	end)
	return self
end

function MockHost.updateScale(self: MockHost)
	if self.desktop == nil then
		return
	end
	const size = self.desktop.AbsoluteSize
	if size.X < 1 or size.Y < 1 then
		return
	end
	self.scale.Scale = Skin.fitScale(size)
end

function MockHost.createWindow(self: MockHost, spec: WindowSpec): MockWindow
	self.nextHwnd += 1
	const win = setmetatable({
		host = self,
		hwnd = "win" .. self.nextHwnd,
		spec = spec,
		rect = {
			x = spec.rect.x,
			y = spec.rect.y,
			width = spec.rect.width,
			height = spec.rect.height,
		},
		bag = newBag(),
		menus = spec.menu or {},
		menuButtons = {},
		menuX = {},
		controls = {},
		closed = false,
	}, MockWindow) :: any

	-- Outer frame is the 1-pixel black Win3 window frame; `inner` is the
	-- face-coloured client/non-client canvas.
	win.frame = track(
		win.bag,
		Skin.frame(self.stage, {
			Name = win.hwnd,
			BackgroundColor3 = Colors.Frame,
			Size = UDim2.fromOffset(win.rect.width, win.rect.height),
			Position = UDim2.fromOffset(win.rect.x, win.rect.y),
			ClipsDescendants = true,
		})
	)
	win.inner = track(
		win.bag,
		Skin.frame(win.frame, {
			Name = "Inner",
			BackgroundColor3 = Colors.Face,
			Size = UDim2.new(1, -2, 1, -2),
			Position = UDim2.fromOffset(1, 1),
			ClipsDescendants = true,
		})
	)

	win:buildChrome()
	win:raise()
	self.windows[#self.windows + 1] = win
	return win
end

function MockWindow.buildChrome(self: MockWindow)
	const win = self
	const caption = track(
		win.bag,
		Skin.frame(win.inner, {
			Name = "Caption",
			BackgroundColor3 = Colors.Caption,
			Size = UDim2.new(1, 0, 0, Metrics.Caption),
		})
	)
	win.caption = caption

	win.titleLabel = track(
		win.bag,
		Skin.label(caption, win.spec.title, {
			Name = "Title",
			Size = UDim2.new(1, -56, 1, 0),
			Position = UDim2.fromOffset(20, 0),
			Font = Fonts.Bold,
			TextColor3 = Colors.CaptionText,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Active = true,
		})
	)

	-- System menu box: a miniature window (title bar + client) like the
	-- spacebar icon in Win3.
	const sysBox = track(
		win.bag,
		Skin.configure(Instance.new("TextButton"), {
			Name = "SystemMenu",
			BackgroundColor3 = Colors.Face,
			BorderSizePixel = 1,
			BorderColor3 = Colors.Frame,
			AutoButtonColor = false,
			Text = "",
			Size = UDim2.fromOffset(14, 14),
			Position = UDim2.fromOffset(2, 2),
		})
	)
	sysBox.Parent = caption
	Skin.bevel(sysBox, "raised")
	track(
		win.bag,
		Skin.frame(sysBox, {
			BackgroundColor3 = Colors.Frame,
			Size = UDim2.fromOffset(8, 2),
			Position = UDim2.fromOffset(2, 2),
		})
	)
	track(
		win.bag,
		Skin.frame(sysBox, {
			BackgroundColor3 = Colors.Face,
			BorderSizePixel = 1,
			BorderColor3 = Colors.FaceShadow,
			Size = UDim2.fromOffset(8, 7),
			Position = UDim2.fromOffset(2, 5),
		})
	)
	connect(win.bag, sysBox.MouseButton1Click, function()
		win.host:openMenu(win, 0)
	end)

	local function captionButton(name: string, xOffset: number, kind: string)
		const button = track(
			win.bag,
			Skin.configure(Instance.new("TextButton"), {
				Name = name,
				BackgroundColor3 = Colors.Face,
				BorderSizePixel = 1,
				BorderColor3 = Colors.Frame,
				AutoButtonColor = false,
				Text = "",
				Size = UDim2.fromOffset(16, 14),
				Position = UDim2.new(1, xOffset, 0, 2),
			})
		)
		button.Parent = caption
		Skin.bevel(button, "raised")
		if kind == "min" then
			track(
				win.bag,
				Skin.frame(button, {
					BackgroundColor3 = Colors.Frame,
					Size = UDim2.fromOffset(6, 2),
					Position = UDim2.new(0.5, -3, 1, -4),
				})
			)
		else
			const glyph = track(
				win.bag,
				Skin.frame(button, {
					BackgroundColor3 = Colors.Frame,
					Size = UDim2.fromOffset(7, 6),
					Position = UDim2.new(0.5, -3, 0.5, -3),
				})
			)
			track(
				win.bag,
				Skin.frame(glyph, {
					BackgroundColor3 = Colors.Face,
					Size = UDim2.fromOffset(5, 4),
					Position = UDim2.fromOffset(1, 1),
				})
			)
		end
	end
	captionButton("Minimize", -36, "min")
	captionButton("Maximize", -18, "max")

	local menuHeight = 0
	if #win.menus > 0 then
		menuHeight = Metrics.Menu
		const bar = track(
			win.bag,
			Skin.frame(win.inner, {
				Name = "MenuBar",
				BackgroundColor3 = Colors.Menu,
				Size = UDim2.new(1, 0, 0, menuHeight),
				Position = UDim2.fromOffset(0, Metrics.Caption),
			})
		)
		track(
			win.bag,
			Skin.frame(bar, {
				BackgroundColor3 = Colors.FaceShadow,
				Size = UDim2.new(1, 0, 0, 1),
				Position = UDim2.new(0, 0, 1, -1),
			})
		)

		local x = 2
		for index, menu in win.menus do
			const width = #menu.title * 6 + 14
			const button = track(
				win.bag,
				Skin.configure(Instance.new("TextButton"), {
					Name = "Menu" .. index,
					BackgroundColor3 = Colors.Highlight,
					BackgroundTransparency = 1,
					AutoButtonColor = false,
					BorderSizePixel = 0,
					Text = menu.title,
					Font = Fonts.Ui,
					TextSize = Skin.TextSize,
					TextColor3 = Colors.MenuText,
					Size = UDim2.fromOffset(width, menuHeight),
					Position = UDim2.fromOffset(x, 0),
				})
			)
			button.Parent = bar
			win.menuButtons[index] = button
			win.menuX[index] = x
			connect(win.bag, button.MouseButton1Click, function()
				if
					win.host.popup
					and win.host.popup.owner == win
					and win.host.popup.index == index
				then
					win.host:closeMenu()
				else
					win.host:openMenu(win, index)
				end
			end)
			connect(win.bag, button.MouseEnter, function()
				if
					win.host.popup
					and win.host.popup.owner == win
					and win.host.popup.index ~= index
				then
					win.host:openMenu(win, index)
				end
			end)
			x += width
		end
	end

	const clientY = Metrics.Caption + menuHeight
	win.client = track(
		win.bag,
		Skin.frame(win.inner, {
			Name = "Client",
			BackgroundColor3 = win.spec.clientColor or Colors.Face,
			Size = UDim2.new(1, 0, 1, -clientY),
			Position = UDim2.fromOffset(0, clientY),
			ClipsDescendants = true,
		})
	)

	-- Drag from the title text only: the caption also holds the system and
	-- min/max boxes, and a caption-wide InputBegan would race their clicks.
	local dragging = false
	local dragStart: Vector3? = nil
	local origin: Vector2? = nil
	connect(win.bag, win.titleLabel.InputBegan, function(input: InputObject)
		if
			input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end
		win:raise()
		dragging = true
		dragStart = input.Position
		origin = Vector2.new(win.rect.x, win.rect.y)
	end)
	connect(win.bag, UserInputService.InputChanged, function(input: InputObject)
		if not dragging or dragStart == nil or origin == nil then
			return
		end
		if
			input.UserInputType ~= Enum.UserInputType.MouseMovement
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end
		const delta = (input.Position - dragStart) / win.host.scale.Scale
		win.rect.x =
			math.clamp(math.floor(origin.X + delta.X + 0.5), 0, Skin.StageWidth - win.rect.width)
		win.rect.y =
			math.clamp(math.floor(origin.Y + delta.Y + 0.5), 0, Skin.StageHeight - win.rect.height)
		win.frame.Position = UDim2.fromOffset(win.rect.x, win.rect.y)
	end)
	connect(win.bag, UserInputService.InputEnded, function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			dragging = false
			dragStart = nil
			origin = nil
		end
	end)
end

function MockWindow.setActiveMenu(self: MockWindow, index: number?)
	for menuIndex, button in self.menuButtons do
		if menuIndex == index then
			button.BackgroundTransparency = 0
			button.TextColor3 = Colors.HighlightText
		else
			button.BackgroundTransparency = 1
			button.TextColor3 = Colors.MenuText
		end
	end
end

function MockWindow.systemMenu(self: MockWindow): { MenuItem }
	return {
		{ text = "Restore", disabled = true },
		{
			text = "Move",
			action = function()
				print("[GuiSpike] mock system menu / Move")
			end,
		},
		{ text = "Size", disabled = true },
		{ separator = true },
		{ text = "Minimize", disabled = true },
		{ text = "Maximize", disabled = true },
		{ separator = true },
		{
			text = "Close",
			accel = "Alt+F4",
			action = function()
				self:close()
			end,
		},
	}
end

function MockWindow.raise(self: MockWindow)
	self.host.nextZ += 1
	self.frame.ZIndex = self.host.nextZ
	self.host:closeMenu()
end

function MockWindow.setText(self: MockWindow, text: string)
	self.titleLabel.Text = text
end

function MockWindow.close(self: MockWindow)
	if self.closed then
		return
	end
	self.closed = true
	if self.host.popup and self.host.popup.owner == self then
		self.host:closeMenu()
	end
	clean(self.bag)
	if self.spec.onClose then
		self.spec.onClose()
	end
end

local function addMenuRow(host: MockHost, popup: Frame, item: MenuItem, y: number)
	const row = Skin.configure(Instance.new("TextButton"), {
		Name = "Item",
		BackgroundColor3 = Colors.Menu,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = "",
		Size = UDim2.new(1, -2, 0, Metrics.MenuRow),
		Position = UDim2.fromOffset(1, y),
	})
	row.Parent = popup

	const disabled = item.disabled == true
	const idleColor = if disabled then Colors.GrayText else Colors.MenuText
	local check: TextLabel? = nil
	local accel: TextLabel? = nil
	const accelWidth = if item.accel then #item.accel * 6 + 10 else 0
	const text = Skin.label(row, item.text or "", {
		Position = UDim2.fromOffset(18, 0),
		Size = UDim2.new(1, -26 - accelWidth, 0, Metrics.MenuRow),
		TextColor3 = idleColor,
	})
	if item.checked then
		check = Skin.label(row, "✓", {
			Position = UDim2.fromOffset(3, 0),
			Size = UDim2.fromOffset(14, Metrics.MenuRow),
			TextXAlignment = Enum.TextXAlignment.Center,
			Font = Fonts.Bold,
			TextColor3 = idleColor,
		})
	end
	if item.accel then
		accel = Skin.label(row, item.accel, {
			Position = UDim2.new(1, -8, 0, 0),
			AnchorPoint = Vector2.new(1, 0),
			Size = UDim2.fromOffset(accelWidth, Metrics.MenuRow),
			TextXAlignment = Enum.TextXAlignment.Right,
			TextColor3 = idleColor,
		})
	end

	const paint = function(highlight: boolean)
		row.BackgroundColor3 = if highlight then Colors.Highlight else Colors.Menu
		const color = if highlight then Colors.HighlightText else idleColor
		text.TextColor3 = color
		if check then
			check.TextColor3 = color
		end
		if accel then
			accel.TextColor3 = color
		end
	end

	if not disabled then
		connect(host.popup.bag, row.MouseEnter, function()
			paint(true)
		end)
		connect(host.popup.bag, row.MouseLeave, function()
			paint(false)
		end)
	end
	connect(host.popup.bag, row.MouseButton1Click, function()
		if disabled then
			return
		end
		host:closeMenu()
		if item.action then
			item.action()
		end
	end)
end

function MockHost.openMenu(self: MockHost, win: MockWindow, index: number)
	self:closeMenu()

	local items: { MenuItem }
	local x: number
	local y: number
	if index == 0 then
		items = win:systemMenu()
		x = win.rect.x + 2
		y = win.rect.y + Metrics.Caption + 2
	else
		const menu = win.menus[index]
		if menu == nil then
			return
		end
		items = menu.items
		x = win.rect.x + 1 + (win.menuX[index] or 0)
		y = win.rect.y + 1 + Metrics.Caption + Metrics.Menu
	end

	const size = measureMenu(items)
	const popupFrame = Skin.frame(self.stage, {
		Name = "PopupMenu",
		BackgroundColor3 = Colors.Menu,
		BorderSizePixel = 1,
		BorderColor3 = Colors.Frame,
		Size = UDim2.fromOffset(size.width, size.height),
		Position = UDim2.fromOffset(
			math.clamp(x, 0, math.max(0, Skin.StageWidth - size.width)),
			math.clamp(y, 0, math.max(0, Skin.StageHeight - size.height))
		),
		ClipsDescendants = true,
		ZIndex = 10000,
	})
	self.popup = {
		owner = win,
		index = index,
		frame = popupFrame,
		bag = newBag(),
	}
	self.menuOwner = win
	win:setActiveMenu(index)

	-- The popup is a sibling of the windows, like a Win16 menu window, so it
	-- draws above every window instead of being clipped by its owner.
	local rowY = 2
	for _, item in items do
		if item.separator then
			Skin.frame(popupFrame, {
				BackgroundColor3 = Colors.FaceShadow,
				Size = UDim2.new(1, -6, 0, 1),
				Position = UDim2.fromOffset(3, rowY + 3),
			})
			rowY += 7
		else
			addMenuRow(self, popupFrame, item, rowY)
			rowY += Metrics.MenuRow
		end
	end

	-- Dismiss on the next click anywhere. Deferred so the click that opened
	-- the menu does not immediately close it.
	task.defer(function()
		if self.popup == nil or self.popup.owner ~= win or self.popup.index ~= index then
			return
		end
		self.menuWatcher = UserInputService.InputBegan:Connect(function(input: InputObject)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1 or self.popup == nil then
				return
			end
			-- Clicks inside the popup belong to the row; only an outside click
			-- dismisses the menu (Win16 menu mode behaves the same way).
			const origin = self.popup.frame.AbsolutePosition
			const size = self.popup.frame.AbsoluteSize
			const position = input.Position
			if
				position.X >= origin.X
				and position.X <= origin.X + size.X
				and position.Y >= origin.Y
				and position.Y <= origin.Y + size.Y
			then
				return
			end
			self:closeMenu()
		end)
	end)
end

function MockHost.closeMenu(self: MockHost)
	if self.menuWatcher then
		self.menuWatcher:Disconnect()
		self.menuWatcher = nil
	end
	if self.popup then
		clean(self.popup.bag)
		self.popup.frame:Destroy()
		self.popup = nil
	end
	if self.menuOwner then
		self.menuOwner:setActiveMenu(nil)
		self.menuOwner = nil
	end
end

function MockHost.destroy(self: MockHost)
	self:closeMenu()
	for _, win in self.windows do
		win:close()
	end
	table.clear(self.windows)
	clean(self.bag)
end

function MockControl.setValue(self: MockControl, value: any)
	if self.applyValue then
		self.value = self.applyValue(value)
	else
		self.value = value
	end
end

function MockControl.getValue(self: MockControl): any
	return self.value
end

function MockWindow.createControl(self: MockWindow, spec: ControlSpec): MockControl
	const control = setmetatable({
		win = self,
		spec = spec,
		value = nil,
	}, MockControl) :: any
	self.controls[#self.controls + 1] = control

	const r = spec.rect
	if spec.class == "BUTTON" then
		const button = track(
			self.bag,
			Skin.configure(Instance.new("TextButton"), {
				Name = "Button",
				BackgroundColor3 = Colors.Face,
				BorderSizePixel = 1,
				BorderColor3 = Colors.Frame,
				AutoButtonColor = false,
				Text = "",
				Size = UDim2.fromOffset(r.width, r.height),
				Position = UDim2.fromOffset(r.x, r.y),
			})
		)
		button.Parent = self.client
		const bevel = Skin.bevel(button, "raised")
		const label = Skin.label(button, spec.text or "", {
			Size = UDim2.fromScale(1, 1),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextColor3 = Colors.WindowText,
		})
		const press = function()
			Skin.setBevel(bevel, "sunken")
			label.Position = UDim2.fromOffset(1, 1)
		end
		const release = function()
			Skin.setBevel(bevel, "raised")
			label.Position = UDim2.fromOffset(0, 0)
		end
		connect(self.bag, button.MouseButton1Down, press)
		connect(self.bag, button.MouseButton1Up, release)
		connect(self.bag, button.MouseLeave, release)
		connect(self.bag, button.MouseButton1Click, function()
			if spec.onClick then
				spec.onClick()
			end
		end)
	elseif spec.class == "CHECKBOX" then
		const hit = track(
			self.bag,
			Skin.configure(Instance.new("TextButton"), {
				Name = "CheckBox",
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				AutoButtonColor = false,
				Text = "",
				Size = UDim2.fromOffset(r.width, r.height),
				Position = UDim2.fromOffset(r.x, r.y),
			})
		)
		hit.Parent = self.client
		const box = Skin.frame(hit, {
			BackgroundColor3 = Colors.Window,
			BorderSizePixel = 1,
			BorderColor3 = Colors.Frame,
			Size = UDim2.fromOffset(Metrics.Check, Metrics.Check),
			Position = UDim2.new(0, 0, 0.5, -Metrics.Check / 2),
		})
		Skin.bevel(box, "sunken")
		const check = Skin.label(box, "✓", {
			Size = UDim2.fromScale(1, 1),
			TextXAlignment = Enum.TextXAlignment.Center,
			Font = Fonts.Bold,
			TextSize = 13,
		})
		Skin.label(hit, spec.text or "", {
			Position = UDim2.fromOffset(Metrics.Check + 5, 0),
			Size = UDim2.new(1, -(Metrics.Check + 5), 1, 0),
		})
		control.value = spec.checked == true
		check.Visible = control.value
		control.applyValue = function(value: any): boolean
			const checked = value == true
			check.Visible = checked
			return checked
		end
		connect(self.bag, hit.MouseButton1Click, function()
			control:setValue(not control.value)
			if spec.onChange then
				spec.onChange(control.value)
			end
		end)
	elseif spec.class == "EDIT" then
		const box = track(
			self.bag,
			Skin.frame(self.client, {
				Name = "Edit",
				BackgroundColor3 = Colors.Window,
				BorderSizePixel = 1,
				BorderColor3 = Colors.Frame,
				Size = UDim2.fromOffset(r.width, r.height),
				Position = UDim2.fromOffset(r.x, r.y),
				ClipsDescendants = true,
			})
		)
		Skin.bevel(box, "sunken")
		const input = track(
			self.bag,
			Skin.configure(Instance.new("TextBox"), {
				Name = "Input",
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				Size = UDim2.new(1, -6, 1, -4),
				Position = UDim2.fromOffset(3, 2),
				Font = Fonts.Ui,
				TextSize = Skin.TextSize,
				TextColor3 = Colors.WindowText,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextYAlignment = Enum.TextYAlignment.Center,
				ClearTextOnFocus = false,
				Text = spec.text or "",
			})
		)
		input.Parent = box
		control.value = spec.text or ""
		control.applyValue = function(value: any): string
			input.Text = tostring(value)
			return input.Text
		end
		connect(self.bag, input.FocusLost, function()
			control.value = input.Text
			if spec.onChange then
				spec.onChange(control.value)
			end
		end)
	elseif spec.class == "STATIC" then
		const label = track(
			self.bag,
			Skin.label(self.client, spec.text or "", {
				Name = "Static",
				Position = UDim2.fromOffset(r.x, r.y),
				Size = UDim2.fromOffset(r.width, r.height),
				TextWrapped = spec.wrap == true,
				TextYAlignment = if spec.wrap
					then Enum.TextYAlignment.Top
					else Enum.TextYAlignment.Center,
			})
		)
		control.value = label.Text
		control.applyValue = function(value: any): string
			label.Text = tostring(value)
			return label.Text
		end
	elseif spec.class == "GROUPBOX" then
		const group = track(
			self.bag,
			Skin.frame(self.client, {
				Name = "GroupBox",
				BackgroundTransparency = 1,
				Size = UDim2.fromOffset(r.width, r.height),
				Position = UDim2.fromOffset(r.x, r.y),
			})
		)
		Skin.bevel(group, "etched", 0)
		Skin.label(group, spec.text or "", {
			Position = UDim2.fromOffset(8, -7),
			Size = UDim2.fromOffset(#(spec.text or "") * 6 + 8, 14),
			BackgroundColor3 = Colors.Face,
			BackgroundTransparency = 0,
			TextColor3 = Colors.WindowText,
		})
		control.value = spec.text or ""
	elseif spec.class == "LISTBOX" then
		const box = track(
			self.bag,
			Skin.frame(self.client, {
				Name = "ListBox",
				BackgroundColor3 = Colors.Window,
				BorderSizePixel = 1,
				BorderColor3 = Colors.Frame,
				Size = UDim2.fromOffset(r.width, r.height),
				Position = UDim2.fromOffset(r.x, r.y),
				ClipsDescendants = true,
			})
		)
		Skin.bevel(box, "sunken")
		const list = track(
			self.bag,
			Skin.frame(box, {
				BackgroundColor3 = Colors.Window,
				Size = UDim2.new(1, -Metrics.Scrollbar, 1, 0),
				ClipsDescendants = true,
			})
		)
		const items = spec.items or {}
		local rows = {}
		for index, text in items do
			const row = track(
				self.bag,
				Skin.configure(Instance.new("TextButton"), {
					Name = "Item" .. index,
					BackgroundColor3 = Colors.Window,
					BorderSizePixel = 0,
					AutoButtonColor = false,
					Text = "",
					Size = UDim2.new(1, 0, 0, Metrics.ListRow),
					Position = UDim2.fromOffset(0, (index - 1) * Metrics.ListRow),
				})
			)
			row.Parent = list
			const rowLabel = Skin.label(row, text, {
				Position = UDim2.fromOffset(3, 0),
				Size = UDim2.new(1, -4, 1, 0),
				TextTruncate = Enum.TextTruncate.AtEnd,
			})
			rows[index] = { button = row, label = rowLabel }
			connect(self.bag, row.MouseButton1Click, function()
				control:setValue(index)
				if spec.onChange then
					spec.onChange(index)
				end
			end)
		end
		control.value = spec.selected or 1
		control.applyValue = function(value: any): number
			const selected = math.clamp(tonumber(value) or 1, 1, math.max(1, #items))
			for index, row in rows do
				const isSelected = index == selected
				row.button.BackgroundColor3 = if isSelected then Colors.Highlight else Colors.Window
				row.label.TextColor3 = if isSelected
					then Colors.HighlightText
					else Colors.WindowText
			end
			return selected
		end
		control:setValue(control.value)

		const bar = track(
			self.bag,
			Skin.frame(box, {
				Name = "Scrollbar",
				BackgroundColor3 = Colors.Face,
				Size = UDim2.fromOffset(Metrics.Scrollbar - 1, r.height - 2),
				Position = UDim2.new(1, -Metrics.Scrollbar, 0, 1),
			})
		)
		const up = track(
			self.bag,
			Skin.frame(bar, {
				BackgroundColor3 = Colors.Face,
				BorderSizePixel = 1,
				BorderColor3 = Colors.Frame,
				Size = UDim2.fromOffset(Metrics.Scrollbar - 1, Metrics.Scrollbar),
			})
		)
		Skin.bevel(up, "raised")
		Skin.arrow(up, "up", Colors.Frame)
		const down = track(
			self.bag,
			Skin.frame(bar, {
				BackgroundColor3 = Colors.Face,
				BorderSizePixel = 1,
				BorderColor3 = Colors.Frame,
				Size = UDim2.fromOffset(Metrics.Scrollbar - 1, Metrics.Scrollbar),
				Position = UDim2.new(0, 0, 1, -Metrics.Scrollbar),
			})
		)
		Skin.bevel(down, "raised")
		Skin.arrow(down, "down", Colors.Frame)
		const thumb = track(
			self.bag,
			Skin.frame(bar, {
				BackgroundColor3 = Colors.Face,
				BorderSizePixel = 1,
				BorderColor3 = Colors.Frame,
				Size = UDim2.new(1, 0, 0, 18),
				Position = UDim2.fromOffset(0, Metrics.Scrollbar + 4),
			})
		)
		Skin.bevel(thumb, "raised")
	else
		error("unknown mock control class: " .. tostring(spec.class))
	end

	return control
end

return MockHost
