--!nonstrict
-- Win3Skin.lua -- Windows 3.0 VGA look for the GUI-spike prototype.
--
-- MOCK ONLY. These are approximations of the Windows 3.0 16-colour scheme,
-- not values read from USER.EXE/GDI.EXE, and nothing here talks to the guest.
-- Every metric is in guest pixels at 640x480; the host applies one UIScale, so
-- a 1-pixel Win3 border stays one guest pixel at any zoom.
--
-- System-colour names follow the Win16 indices where one exists
-- (COLOR_BTNFACE, COLOR_CAPTION, COLOR_HIGHLIGHT, ...).

const Skin = {}

const Colors = table.freeze({
	Desktop = Color3.fromRGB(0, 128, 128), -- Program Manager teal
	Face = Color3.fromRGB(192, 192, 192), -- COLOR_BTNFACE
	FaceLight = Color3.fromRGB(255, 255, 255), -- COLOR_BTNHIGHLIGHT
	FaceShadow = Color3.fromRGB(128, 128, 128), -- COLOR_BTNSHADOW
	Frame = Color3.fromRGB(0, 0, 0), -- window frame / control outline
	Window = Color3.fromRGB(255, 255, 255), -- COLOR_WINDOW
	WindowText = Color3.fromRGB(0, 0, 0), -- COLOR_WINDOWTEXT
	GrayText = Color3.fromRGB(128, 128, 128), -- COLOR_GRAYTEXT
	Caption = Color3.fromRGB(0, 0, 128), -- COLOR_ACTIVECAPTION
	CaptionText = Color3.fromRGB(255, 255, 255), -- COLOR_CAPTIONTEXT
	CaptionInactive = Color3.fromRGB(128, 128, 128), -- COLOR_INACTIVECAPTION
	Highlight = Color3.fromRGB(0, 0, 128), -- COLOR_HIGHLIGHT
	HighlightText = Color3.fromRGB(255, 255, 255), -- COLOR_HIGHLIGHTTEXT
	Menu = Color3.fromRGB(255, 255, 255), -- COLOR_MENU
	MenuText = Color3.fromRGB(0, 0, 0), -- COLOR_MENUTEXT
})

const Metrics = table.freeze({
	Caption = 18, -- SM_CYCAPTION at 96 dpi, approx.
	Menu = 18, -- SM_CYMENU
	MenuRow = 16, -- popup item height
	Button = 21,
	Edit = 20,
	Check = 13,
	ListRow = 16,
	Scrollbar = 16, -- SM_CXVSCROLL
})

const Fonts = table.freeze({
	Ui = Enum.Font.Arial, -- closest vector stand-in for the System bitmap font
	Bold = Enum.Font.ArialBold,
})

const STAGE_WIDTH = 640
const STAGE_HEIGHT = 400
const TEXT_SIZE = 11

Skin.Colors = Colors
Skin.Metrics = Metrics
Skin.Fonts = Fonts
Skin.TextSize = TEXT_SIZE
Skin.StageWidth = STAGE_WIDTH
Skin.StageHeight = STAGE_HEIGHT

export type Bevel = {
	Top: Frame,
	Left: Frame,
	Bottom: Frame,
	Right: Frame,
}

-- Apply defaults first, caller props second: the caller always wins.
function Skin.configure<T>(instance: T, defaults: { [string]: any }, props: { [string]: any }?): T
	const target = instance :: any
	for key, value in defaults do
		target[key] = value
	end
	for key, value in props or {} do
		target[key] = value
	end
	return instance
end

function Skin.frame(parent: Instance, props: { [string]: any }?): Frame
	const frame = Skin.configure(Instance.new("Frame"), {
		BackgroundColor3 = Colors.Face,
		BorderSizePixel = 0,
	}, props)
	frame.Parent = parent
	return frame
end

function Skin.label(parent: Instance, text: string, props: { [string]: any }?): TextLabel
	const label = Skin.configure(Instance.new("TextLabel"), {
		BackgroundTransparency = 1,
		Font = Fonts.Ui,
		TextSize = TEXT_SIZE,
		TextColor3 = Colors.WindowText,
		Text = text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
	}, props)
	label.Parent = parent
	return label
end

local function edge(parent: Instance, color: Color3, position: UDim2, size: UDim2): Frame
	return Skin.frame(parent, {
		BackgroundColor3 = color,
		Position = position,
		Size = size,
	})
end

-- Win3 controls are a 1-pixel black outline plus a 1-pixel light/shadow
-- bevel just inside it. `inset` is 0 for an etched group-box frame (no
-- black outline) and 1 for every outlined control.
function Skin.bevel(parent: Instance, style: string, inset: number?): Bevel
	const i = inset or 1
	const bevel: Bevel = {
		Top = edge(parent, Colors.FaceLight, UDim2.fromOffset(i, i), UDim2.new(1, -2 * i, 0, 1)),
		Left = edge(parent, Colors.FaceLight, UDim2.fromOffset(i, i), UDim2.new(0, 1, 1, -2 * i)),
		Bottom = edge(
			parent,
			Colors.FaceShadow,
			UDim2.new(0, i, 1, -i - 1),
			UDim2.new(1, -2 * i, 0, 1)
		),
		Right = edge(
			parent,
			Colors.FaceShadow,
			UDim2.new(1, -i - 1, 0, i),
			UDim2.new(0, 1, 1, -2 * i)
		),
	}
	Skin.setBevel(bevel, style)
	return bevel
end

function Skin.setBevel(bevel: Bevel, style: string)
	const raised = style == "raised"
	const light = if raised then Colors.FaceLight else Colors.FaceShadow
	const shadow = if raised then Colors.FaceShadow else Colors.FaceLight
	bevel.Top.BackgroundColor3 = light
	bevel.Left.BackgroundColor3 = light
	bevel.Bottom.BackgroundColor3 = shadow
	bevel.Right.BackgroundColor3 = shadow
end

-- Pixel-art triangle for scrollbar arrows. Four 1-pixel rows avoid relying on
-- a font glyph that Roblox may not ship.
function Skin.arrow(parent: Instance, direction: string, color: Color3): Frame
	const holder = Skin.frame(parent, {
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(7, 4),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
	})
	for row = 0, 3 do
		const width = row * 2 + 1
		Skin.frame(holder, {
			BackgroundColor3 = color,
			Size = UDim2.fromOffset(width, 1),
			Position = UDim2.fromOffset(
				math.floor((7 - width) / 2),
				if direction == "up" then row else 3 - row
			),
		})
	end
	return holder
end

-- Fit the 640x400 guest stage into the viewport in quarter steps. Fractional
-- scale is fine for the mock; a real adapter would want an integer scale so
-- USER's integer metrics stay exact.
function Skin.fitScale(viewport: Vector2): number
	if viewport.X < 1 or viewport.Y < 1 then
		return 1
	end
	const raw = math.min(viewport.X * 0.92 / STAGE_WIDTH, viewport.Y * 0.92 / STAGE_HEIGHT, 3)
	return math.max(1, math.floor(raw * 4) / 4)
end

return Skin
