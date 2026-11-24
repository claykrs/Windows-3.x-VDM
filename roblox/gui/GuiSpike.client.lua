--!nonstrict
-- GuiSpike.client.lua -- visual prototype for the native-ScreenGui question.
--
-- MOCK ONLY. No USER.EXE, no GDI.EXE, no guest state. This builds a Win3-style
-- window, menu bar, popup menu and a handful of standard controls through the
-- mock adapter in MockHost.lua. The point is to show what a declarative
-- mapping looks like, and to make the missing WM_PAINT / HDC surface obvious.
--
-- Run with `rojo serve roblox/gui/gui-spike.project.json`, or copy this folder
-- into StarterPlayerScripts. See FEASIBILITY.md for what this cannot do.

const Players = game:GetService("Players")
const MockHost = require(script.Parent.MockHost)

const player = Players.LocalPlayer
if player == nil then
	return
end
const playerGui = player:WaitForChild("PlayerGui")

const screen = Instance.new("ScreenGui")
screen.Name = "VdmGuiSpike"
screen.IgnoreGuiInset = true
screen.ResetOnSpawn = false
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.DisplayOrder = 100
screen.Parent = playerGui

const host = MockHost.new(screen)

local about = nil

local function showClosedNote()
	const note = Instance.new("TextLabel")
	note.Name = "ClosedNote"
	note.Size = UDim2.fromOffset(520, 28)
	note.Position = UDim2.fromScale(0.5, 0.55)
	note.AnchorPoint = Vector2.new(0.5, 0.5)
	note.BackgroundTransparency = 1
	note.Font = Enum.Font.ArialBold
	note.TextSize = 20
	note.TextColor3 = Color3.fromRGB(255, 255, 255)
	note.Text = "GUI spike closed. Stop and play again to relaunch."
	note.Parent = screen
end

local function openAbout()
	if about then
		about:raise()
		return
	end
	about = host:createWindow({
		title = "About GUI Spike",
		rect = { x = 326, y = 96, width = 256, height = 132 },
		onClose = function()
			about = nil
		end,
	})
	about:createControl({
		class = "STATIC",
		rect = { x = 14, y = 10, width = 228, height = 40 },
		text = "A ScreenGui prototype of the Windows 3.0 look.\nNo guest code, no USER/GDI.",
		wrap = true,
	})
	about:createControl({
		class = "STATIC",
		rect = { x = 14, y = 54, width = 228, height = 16 },
		text = "Rendered natively: 6 control classes.",
	})
	about:createControl({
		class = "BUTTON",
		rect = { x = 178, y = 86, width = 64, height = 22 },
		text = "OK",
		onClick = function()
			about:close()
		end,
	})
end

local main

main = host:createWindow({
	title = "GUI Spike - MOCK (not Windows)",
	rect = { x = 92, y = 52, width = 456, height = 292 },
	menu = {
		{
			title = "File",
			items = {
				{
					text = "New",
					action = function()
						main:setText("GUI Spike - MOCK (New)")
					end,
				},
				{
					text = "Open...",
					action = function()
						print("[GuiSpike] mock File/Open")
					end,
				},
				{ separator = true },
				{ text = "Save", accel = "Ctrl+S", disabled = true },
				{ text = "Save As...", disabled = true },
				{ separator = true },
				{
					text = "Exit",
					accel = "Alt+F4",
					action = function()
						if about then
							about:close()
						end
						main:close()
					end,
				},
			},
		},
		{
			title = "Edit",
			items = {
				{ text = "Undo", accel = "Ctrl+Z", disabled = true },
				{ separator = true },
				{ text = "Cut", accel = "Ctrl+X", disabled = true },
				{ text = "Copy", accel = "Ctrl+C", disabled = true },
				{ text = "Paste", accel = "Ctrl+V", disabled = true },
				{
					text = "Select All",
					accel = "Ctrl+A",
					action = function()
						print("[GuiSpike] mock Edit/Select All")
					end,
				},
			},
		},
		{
			title = "Help",
			items = {
				{ text = "About GUI Spike...", action = openAbout },
			},
		},
	},
	onClose = function()
		showClosedNote()
	end,
})

main:createControl({
	class = "STATIC",
	rect = { x = 16, y = 8, width = 422, height = 16 },
	text = "MOCK: this is a ScreenGui window, not a guest WM_PAINT.",
})

main:createControl({
	class = "GROUPBOX",
	rect = { x = 16, y = 30, width = 422, height = 184 },
	text = "Declarative state a native mapper can own",
})

main:createControl({
	class = "STATIC",
	rect = { x = 28, y = 48, width = 398, height = 16 },
	text = "Window rects, z-order, captions, menu lists, standard control kinds.",
})

main:createControl({
	class = "STATIC",
	rect = { x = 28, y = 66, width = 398, height = 16 },
	text = "Missing by design: WM_PAINT, HDC, clip regions, fonts, BitBlt.",
})

const nativeMapping = main:createControl({
	class = "CHECKBOX",
	rect = { x = 28, y = 90, width = 240, height = 16 },
	text = "Native mapping enabled (mock)",
	checked = true,
	onChange = function(value: boolean)
		print("[GuiSpike] checkbox =", value)
	end,
})

main:createControl({
	class = "EDIT",
	rect = { x = 28, y = 112, width = 220, height = 20 },
	text = "C:\\WINDOWS\\WIN.COM",
})

main:createControl({
	class = "BUTTON",
	rect = { x = 256, y = 111, width = 80, height = 21 },
	text = "Browse...",
	onClick = function()
		print("[GuiSpike] mock Browse (no guest file dialog)")
	end,
})

main:createControl({
	class = "LISTBOX",
	rect = { x = 28, y = 142, width = 398, height = 66 },
	items = {
		"Geometry / z-order ........ maps",
		"Caption + menu list ....... maps",
		"Owner-draw / custom class . no",
		"GDI paths / bitmaps ....... no",
	},
	selected = 1,
})

main:createControl({
	class = "STATIC",
	rect = { x = 16, y = 228, width = 220, height = 16 },
	text = "VGA sink stays the real renderer.",
})

main:createControl({
	class = "BUTTON",
	rect = { x = 250, y = 224, width = 80, height = 22 },
	text = "OK",
	onClick = function()
		print("[GuiSpike] mock OK")
	end,
})

main:createControl({
	class = "BUTTON",
	rect = { x = 338, y = 224, width = 80, height = 22 },
	text = "Cancel",
	onClick = function()
		print("[GuiSpike] mock Cancel")
	end,
})

print("[GuiSpike] mock Win3 window built; native mapping checkbox =", nativeMapping:getValue())
