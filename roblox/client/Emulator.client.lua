--!strict
-- Emulator.client -- runs the Vdm machine on the CLIENT (full frame budget,
-- zero replication), renders into a Windows 3.0-style host window and feeds
-- keyboard/PS/2 input.

const ReplicatedStorage = game:GetService("ReplicatedStorage")
const RunService = game:GetService("RunService")
const UserInputService = game:GetService("UserInputService")
const Players = game:GetService("Players")
const StarterGui = game:GetService("StarterGui")
const GuiService = game:GetService("GuiService")
const Workspace = game:GetService("Workspace")

const Vdm = require(ReplicatedStorage:WaitForChild("Vdm"))
const VdmUi = ReplicatedStorage:WaitForChild("VdmUi")
const Fixtures = ReplicatedStorage:WaitForChild("VdmFixtures")
const BOOT_WINDOWS = ReplicatedStorage:GetAttribute("VdmBootWindows") == true

const Cleaner = require(VdmUi:WaitForChild("Cleaner"))
const Window = require(VdmUi:WaitForChild("Window"))
const Theme = require(VdmUi:WaitForChild("Theme"))
const ScreenSink = require(script.Parent:WaitForChild("ScreenSink"))
const VgaSink = require(script.Parent:WaitForChild("VgaSink"))
const KeyboardMap = require(script.Parent:WaitForChild("KeyboardMap"))

const GUEST_WIDTH = 640
const GUEST_HEIGHT = 480
const TITLE_HEIGHT = Theme.Sizes.TitleBar
const STATUS_HEIGHT = Theme.Sizes.StatusBar
const MIN_WINDOW_SCALE = 1
const MAX_WINDOW_SCALE = 3

const cleaner = Cleaner.new()

-- ---------------------------------------------------------------- host scene
-- The emulator is the experience: cover the default baseplate/skybox with an
-- opaque desktop and remove the character/spawn so the window is all that is
-- visible while the GUI still loads normally.
local function disableCoreGui()
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, false)
	end)
	for _, kind in
		{
			Enum.CoreGuiType.Backpack,
			Enum.CoreGuiType.Chat,
			Enum.CoreGuiType.EmotesMenu,
			Enum.CoreGuiType.Health,
			Enum.CoreGuiType.PlayerList,
		}
	do
		pcall(function()
			StarterGui:SetCoreGuiEnabled(kind, false)
		end)
	end
	pcall(function()
		StarterGui:SetCore("TopbarEnabled", false)
	end)
	pcall(function()
		StarterGui:SetCore("ChatActive", false)
	end)
	pcall(function()
		StarterGui:SetCore("ResetButtonCallback", false)
	end)
	-- CoreGui finishes initialising a few frames after the client script
	-- starts; the topbar can reappear if the call is only made once.
	task.spawn(function()
		for _ = 1, 12 do
			task.wait(0.5)
			pcall(function()
				StarterGui:SetCore("TopbarEnabled", false)
			end)
			pcall(function()
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, false)
			end)
		end
	end)
end

local function clearWorld()
	for _, child in Workspace:GetChildren() do
		if child:IsA("SpawnLocation") or (child:IsA("BasePart") and child.Name == "Baseplate") then
			child:Destroy()
		end
	end
end

disableCoreGui()
clearWorld()
cleaner:Connect(Workspace.ChildAdded, function(child: Instance)
	if child:IsA("SpawnLocation") or (child:IsA("BasePart") and child.Name == "Baseplate") then
		child:Destroy()
	end
end)

const playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
const screenGui = cleaner:Add(Instance.new("ScreenGui"))
screenGui.Name = "VdmGui"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = playerGui

const holder = cleaner:Add(Instance.new("Frame"))
holder.Name = "Desktop"
holder.Size = UDim2.fromScale(1, 1)
holder.BackgroundColor3 = Color3.new(0, 0, 0)
holder.BorderSizePixel = 0
holder.Parent = screenGui

-- Remove the local character as soon as it appears too. A server-side
-- CharacterAutoLoads=false would also work, but the client must keep working
-- when the place does not ship a server script.
const localPlayer = Players.LocalPlayer
local function removeCharacter(character: Model)
	character:Destroy()
end
if localPlayer.Character then
	removeCharacter(localPlayer.Character)
end
cleaner:Connect(localPlayer.CharacterAdded, removeCharacter)

const camera = Workspace.CurrentCamera
if camera then
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = CFrame.new(0, 8, 20) * CFrame.Angles(math.rad(-8), 0, 0)
end

-- --------------------------------------------------------------- host window
local function viewportSize(): Vector2
	const current = Workspace.CurrentCamera
	if current then
		return current.ViewportSize
	end
	return Vector2.new(1280, 720)
end

local function guiInsets(): (Vector2, Vector2)
	local ok, topLeft, bottomRight = pcall(function()
		return GuiService:GetGuiInset()
	end)
	if ok and typeof(topLeft) == "Vector2" and typeof(bottomRight) == "Vector2" then
		return topLeft, bottomRight
	end
	return Vector2.zero, Vector2.zero
end

local function fitWindow(): UDim2
	const viewport = viewportSize()
	const insetTopLeft, insetBottomRight = guiInsets()
	const availableWidth = math.max(320, viewport.X - insetTopLeft.X - insetBottomRight.X - 32)
	const availableHeight = math.max(240, viewport.Y - insetTopLeft.Y - insetBottomRight.Y - 32)
	local best = 0
	for scale = MIN_WINDOW_SCALE, MAX_WINDOW_SCALE do
		const width = GUEST_WIDTH * scale
		const height = GUEST_HEIGHT * scale + TITLE_HEIGHT + STATUS_HEIGHT
		if width <= availableWidth and height <= availableHeight then
			best = scale
		end
	end
	if best > 0 then
		return UDim2.fromOffset(
			GUEST_WIDTH * best,
			GUEST_HEIGHT * best + TITLE_HEIGHT + STATUS_HEIGHT
		)
	end
	const scale = math.max(
		0.1,
		math.min(
			availableWidth / GUEST_WIDTH,
			(availableHeight - TITLE_HEIGHT - STATUS_HEIGHT) / GUEST_HEIGHT
		)
	)
	return UDim2.fromOffset(
		math.max(320, math.floor(GUEST_WIDTH * scale)),
		math.max(240, math.floor(GUEST_HEIGHT * scale) + TITLE_HEIGHT + STATUS_HEIGHT)
	)
end

const window = Window.new("Windows 3.0a", fitWindow())
window.Gui.ZIndex = 2
window.Gui.Parent = holder

const display = cleaner:Add(Instance.new("Frame"))
display.Name = "Display"
display.Size = UDim2.new(1, 0, 1, -STATUS_HEIGHT)
display.BackgroundColor3 = Theme.Colors.Screen
display.BorderSizePixel = 0
display.ClipsDescendants = true
display.Parent = window.Content

const sink = ScreenSink.new(cleaner, display)

const videoHost = cleaner:Add(Instance.new("Frame"))
videoHost.Name = "Video"
videoHost.Size = UDim2.fromScale(1, 1)
videoHost.BackgroundColor3 = Color3.new(0, 0, 0)
videoHost.BorderSizePixel = 0
videoHost.Visible = false
videoHost.ZIndex = 2
videoHost.Parent = display

const statusBar = cleaner:Add(Instance.new("Frame"))
statusBar.Name = "StatusBar"
statusBar.Size = UDim2.new(1, 0, 0, STATUS_HEIGHT)
statusBar.Position = UDim2.new(0, 0, 1, -STATUS_HEIGHT)
statusBar.BackgroundColor3 = Theme.Colors.Surface
statusBar.BorderSizePixel = 0
statusBar.ZIndex = 3
statusBar.Parent = window.Content

local function statusRule(y: number, color: Color3)
	const line = cleaner:Add(Instance.new("Frame"))
	line.Name = "StatusRule"
	line.Size = UDim2.new(1, 0, 0, 1)
	line.Position = UDim2.fromOffset(0, y)
	line.BackgroundColor3 = color
	line.BorderSizePixel = 0
	line.ZIndex = 4
	line.Parent = statusBar
end
statusRule(0, Theme.Colors.BevelLight)
statusRule(1, Theme.Colors.BevelDark)

const statusDot = cleaner:Add(Instance.new("Frame"))
statusDot.Name = "State"
statusDot.Size = UDim2.fromOffset(7, 7)
statusDot.Position = UDim2.fromOffset(9, 9)
statusDot.BackgroundColor3 = Color3.fromRGB(220, 160, 64)
statusDot.BorderSizePixel = 0
statusDot.ZIndex = 4
statusDot.Parent = statusBar
const statusDotCorner = cleaner:Add(Instance.new("UICorner"))
statusDotCorner.CornerRadius = UDim.new(1, 0)
statusDotCorner.Parent = statusDot

const statusLabel = cleaner:Add(Instance.new("TextLabel"))
statusLabel.Name = "StateText"
statusLabel.BackgroundTransparency = 1
statusLabel.Position = UDim2.fromOffset(22, 0)
statusLabel.Size = UDim2.new(0.55, -22, 1, 0)
statusLabel.Font = Theme.Fonts.Ui
statusLabel.TextSize = 12
statusLabel.TextColor3 = Theme.Colors.Text
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.Text = "Starting Windows..."
statusLabel.ZIndex = 4
statusLabel.Parent = statusBar

const statusDetail = cleaner:Add(Instance.new("TextLabel"))
statusDetail.Name = "Detail"
statusDetail.BackgroundTransparency = 1
statusDetail.Position = UDim2.fromScale(0.55, 0)
statusDetail.Size = UDim2.new(0.45, -10, 1, 0)
statusDetail.Font = Theme.Fonts.Ui
statusDetail.TextSize = 12
statusDetail.TextColor3 = Theme.Colors.TextDim
statusDetail.TextXAlignment = Enum.TextXAlignment.Right
statusDetail.Text = ""
statusDetail.ZIndex = 4
statusDetail.Parent = statusBar

local function setStatus(text: string, detail: string, color: Color3)
	if statusLabel.Text ~= text then
		statusLabel.Text = text
	end
	if statusDetail.Text ~= detail then
		statusDetail.Text = detail
	end
	statusDot.BackgroundColor3 = color
end

const statusCamera = Workspace.CurrentCamera
if statusCamera then
	cleaner:Connect(statusCamera:GetPropertyChangedSignal("ViewportSize"), function()
		window.Gui.Size = fitWindow()
		window:ClampToViewport()
	end)
end

-- ------------------------------------------------------------------- machine
const machine = Vdm.Machine.new({
	Memory = Vdm.Memory,
	Cpu = Vdm.Cpu,
	Vfs = Vdm.Vfs,
	Bios = Vdm.Bios,
	Dos = Vdm.Dos,
	TextScreen = Vdm.TextScreen,
	Executables = Vdm.Executables,
	Vga = Vdm.Vga,
	logger = function(message: string)
		print("[Vdm] " .. message)
	end,
})
if BOOT_WINDOWS then
	const WinBoot = require(Fixtures:WaitForChild("WinBoot"))
	const DriversA = require(Fixtures:WaitForChild("WinBootDriversA"))
	const DriversB = require(Fixtures:WaitForChild("WinBootDriversB"))
	machine.vfs:ensureDir("C:\\WINDOWS")
	machine.vfs:ensureDir("C:\\WINDOWS\\SYSTEM")
	machine.vfs:writeFile("C:\\WINDOWS\\WIN.COM", WinBoot.winCom)
	machine.vfs:writeFile("C:\\WINDOWS\\KERNEL.EXE", WinBoot.kernel)
	machine.vfs:writeFile("C:\\WINDOWS\\WIN.INI", WinBoot.winIni)
	machine.vfs:writeFile("C:\\WINDOWS\\SYSTEM.INI", WinBoot.systemIni)
	for name, encoded in DriversA do
		const data = WinBoot.decode(encoded)
		machine.vfs:writeFile("C:\\WINDOWS\\" .. name, data)
		machine.vfs:writeFile("C:\\WINDOWS\\SYSTEM\\" .. name, data)
	end
	for name, encoded in DriversB do
		const data = WinBoot.decode(encoded)
		machine.vfs:writeFile("C:\\WINDOWS\\" .. name, data)
		machine.vfs:writeFile("C:\\WINDOWS\\SYSTEM\\" .. name, data)
	end
	const Apps = require(Fixtures:WaitForChild("WinBootApps"))
	for name, encoded in Apps do
		machine.vfs:writeFile("C:\\WINDOWS\\" .. name, WinBoot.decode(encoded))
	end
	const Groups = require(Fixtures:WaitForChild("WinBootGroups"))
	for name, encoded in Groups do
		machine.vfs:writeFile("C:\\WINDOWS\\" .. name, WinBoot.decode(encoded))
	end
	const bigManifest = Fixtures:FindFirstChild("WinBootBig")
	if bigManifest then
		local ok, err = pcall(function()
			for name, chunks in require(bigManifest) do
				local parts = {}
				for _, chunkName in chunks do
					parts[#parts + 1] = require(Fixtures:WaitForChild(chunkName))
				end
				const data = WinBoot.decode(table.concat(parts))
				machine.vfs:writeFile("C:\\WINDOWS\\" .. name, data)
				machine.vfs:writeFile("C:\\WINDOWS\\SYSTEM\\" .. name, data)
			end
		end)
		if not ok then
			warn("[Vdm] WinBoot big files: " .. tostring(err))
		end
	end
	const vga = machine.vfs:readFile("C:\\WINDOWS\\VGA.DRV") or ""
	const vgaSys = machine.vfs:readFile("C:\\WINDOWS\\VGASYS.FON") or ""
	const vgaFix = machine.vfs:readFile("C:\\WINDOWS\\VGAFIX.FON") or ""
	const vgaOem = machine.vfs:readFile("C:\\WINDOWS\\VGAOEM.FON") or ""
	for _, dir in { "C:\\WINDOWS", "C:\\WINDOWS\\SYSTEM" } do
		machine.vfs:writeFile(dir .. "\\DISPLAY.DRV", vga)
		machine.vfs:writeFile(dir .. "\\FONTS.FON", vgaSys)
		machine.vfs:writeFile(dir .. "\\FIXEDFON.FON", vgaFix)
		machine.vfs:writeFile(dir .. "\\OEMFONTS.FON", vgaOem)
	end
	machine.dos.cwd = "C:\\WINDOWS"
	machine.vfs.cwd = "C:\\WINDOWS"
	machine:loadCOM(buffer.fromstring(WinBoot.winCom), nil, "C:\\WINDOWS\\WIN.COM")
else
	require(Fixtures.Kernel16).register(machine)
	require(Fixtures.TestApps).register(machine)
	machine.vfs:writeFile("C:\\TEXT.TXT", "Vdm on Roblox, client-side.\r\n")
	machine:loadNE(buffer.fromstring(require(Fixtures.Apps)["NE4.EXE"]))
end

-- --------------------------------------------------------------------- input
-- keyboard: Windows reads make/break scan codes from the 8042; the DOS test
-- path still uses the BIOS INT 16h ASCII queue.
const heldKeys: { [number]: boolean } = {}
const keyRepeatAt: { [number]: number } = {}
const REPEAT_DELAY = 0.45
const REPEAT_INTERVAL = 0.05
-- Modifiers and lock keys do not repeat on a PC keyboard.
const NO_REPEAT: { [number]: boolean } = {
	[0x1D] = true,
	[0x2A] = true,
	[0x36] = true,
	[0x38] = true,
	[0x3A] = true,
	[0x45] = true,
	[0x46] = true,
}

local pointerInside = false
local mouseButtons = 0
local mouseSynced = false
local lastPointer = Vector2.zero
local vgaSink: any = nil
local vgaWidth, vgaHeight = 0, 0
-- The entry anchor sends the cursor to (0,0) followed by the real target.
-- Hold the next frame so the intermediate position is never displayed.
local suppressVideoUntil = 0

local function hasGuestPointer(): boolean
	return machine.mousePs2Enabled and machine.mouseDeviceHandler ~= nil
end

local function refreshPointerVisibility()
	-- Hide the host arrow while the pointer is over the guest framebuffer:
	-- Windows draws its own cursor there. The guest pointer is anchored once
	-- (see mouseSynced) and then follows relative PS/2 packets, so leaving the
	-- window and coming back does not teleport it.
	UserInputService.MouseIconEnabled = not (pointerInside and hasGuestPointer())
end

local function setPointerInside(inside: boolean)
	if inside == pointerInside then
		return
	end
	pointerInside = inside
	if not inside then
		-- Re-anchor the relative PS/2 pointer on the next entry: host and guest
		-- can drift if Windows moves the cursor while the pointer is outside.
		mouseSynced = false
	end
	refreshPointerVisibility()
end

local function updateVideo()
	const vga = machine.vga
	if not vga then
		return
	end
	const info = vga:modeInfo()
	if info.kind == "text" then
		videoHost.Visible = false
		return
	end
	if not vgaSink or vgaWidth ~= info.width or vgaHeight ~= info.height then
		if vgaSink then
			vgaSink:Destroy()
		end
		vgaSink = VgaSink.new(videoHost, info.width, info.height)
		vgaWidth, vgaHeight = info.width, info.height
		mouseSynced = false
		vga:markAllDirty()
	end
	videoHost.Visible = true
	if os.clock() < suppressVideoUntil then
		return
	end
	const dirty = vga:consumeDirty()
	if dirty then
		-- Convert only the dirty rectangle; the rest of the retained RGBA
		-- buffer is from the previous frame. This is the difference between
		-- repainting a 16x16 cursor and repainting 640x480 every tick.
		vgaSink:UpdateRegionRGBA(
			vga:snapshotRegionRGBA(dirty.x, dirty.y, dirty.width, dirty.height),
			dirty.x,
			dirty.y,
			dirty.width,
			dirty.height
		)
	end
end

local lastMousePump = 0
local lastPointerChange = 0
local mouseSettled = true
local function updateMouse(position: Vector2?, forceSync: boolean?)
	if not vgaSink or not vgaSink.root or not videoHost.Visible then
		setPointerInside(false)
		return
	end
	if position then
		if position ~= lastPointer then
			lastPointerChange = os.clock()
			mouseSettled = false
		end
		lastPointer = position
	end
	const size = vgaSink.root.AbsoluteSize
	const at = vgaSink.root.AbsolutePosition
	if size.X <= 0 or size.Y <= 0 then
		setPointerInside(false)
		return
	end
	-- InputObject.Position is in the same GUI/screen space as
	-- GuiObject.AbsolutePosition. GetMouseLocation in this client carries an
	-- extra topbar inset, so use the event position and only fall back to it
	-- when an event has no position.
	const pos = lastPointer
	const fx = (pos.X - at.X) / size.X
	const fy = (pos.Y - at.Y) / size.Y
	const inside = fx >= 0 and fx <= 1 and fy >= 0 and fy <= 1
	setPointerInside(inside)
	if not inside then
		return
	end
	if hasGuestPointer() and (not mouseSynced or forceSync) then
		-- Re-anchor the guest pointer at (0,0), then apply the absolute target.
		-- Windows sometimes warps its own cursor (dialogs, focus changes), so a
		-- relative-only stream can stay offset forever. Clicks and idle stops
		-- force this correction; normal motion stays purely relative.
		mouseSynced = machine:syncMouse()
		if mouseSynced then
			suppressVideoUntil = os.clock() + 0.05
			if forceSync then
				mouseSettled = true
			end
		end
		refreshPointerVisibility()
	end
	const guestX = math.clamp(math.floor(fx * vgaSink.width), 0, vgaSink.width - 1)
	const guestY = math.clamp(math.floor(fy * vgaSink.height), 0, vgaSink.height - 1)
	machine:setMouse(guestX, guestY, mouseButtons)
	-- Deliver the packet and repaint before the next Heartbeat. Without this
	-- the guest cursor trails the host by a frame or two, which makes slow
	-- window drags slip off the title bar.
	const now = os.clock()
	if now - lastMousePump >= 0.008 then
		lastMousePump = now
		machine:run(1500)
		updateVideo()
	end
end

local function releaseKeys()
	for scan in pairs(heldKeys) do
		machine:keyUp(scan)
	end
	table.clear(heldKeys)
	table.clear(keyRepeatAt)
end

cleaner:Connect(UserInputService.InputBegan, function(input, _processed)
	if input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end
	-- The guest owns the keyboard for the whole experience. CoreGui hotkeys are
	-- disabled above, but Roblox still marks some keys (notably O, the emotes
	-- menu) as processed; the emulator has no competing text field, so forward
	-- every mapped key instead of dropping the reserved ones.
	const key = input.KeyCode
	if BOOT_WINDOWS then
		const scan = KeyboardMap[key]
		if scan and not heldKeys[scan] then
			heldKeys[scan] = true
			keyRepeatAt[scan] = os.clock() + REPEAT_DELAY
			machine:keyDown(scan)
		end
	elseif key == Enum.KeyCode.Return then
		machine:pushKeys("\r")
	elseif key == Enum.KeyCode.Backspace then
		machine:pushKeys("\b")
	else
		const char = UserInputService:GetStringForKeyCode(key.Name)
		if char and #char == 1 then
			machine:pushKeys(string.upper(char))
		end
	end
end)
cleaner:Connect(UserInputService.InputEnded, function(input)
	if not BOOT_WINDOWS or input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end
	const scan = KeyboardMap[input.KeyCode]
	if scan and heldKeys[scan] then
		heldKeys[scan] = nil
		keyRepeatAt[scan] = nil
		machine:keyUp(scan)
	end
end)
cleaner:Connect(UserInputService.WindowFocusReleased, releaseKeys)

cleaner:Connect(UserInputService.InputChanged, function(input)
	if input.UserInputType == Enum.UserInputType.MouseMovement then
		updateMouse(input.Position)
	end
end)
cleaner:Connect(UserInputService.InputBegan, function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		mouseButtons = bit32.bor(mouseButtons, 1)
		-- If the pointer just stopped, the idle anchor already aligned the
		-- guest cursor; send a clean button edge instead of moving and
		-- pressing in the same PS/2 packet (Windows can ignore that click).
		updateMouse(input.Position, not mouseSettled)
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		mouseButtons = bit32.bor(mouseButtons, 2)
		updateMouse(input.Position, not mouseSettled)
	end
end)
cleaner:Connect(UserInputService.InputEnded, function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		mouseButtons = bit32.band(mouseButtons, bit32.bnot(1))
		updateMouse(input.Position)
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		mouseButtons = bit32.band(mouseButtons, bit32.bnot(2))
		updateMouse(input.Position)
	end
end)

-- -------------------------------------------------------------------- render
local function colourLabel(info: any): string
	if info.kind == "text" then
		return "text mode"
	end
	if info.bitsPerPixel == 8 then
		return "256 colours"
	end
	return "16 colours"
end

-- ------------------------------------------------------------------ main loop
const INITIAL_STEPS = 50_000
const MIN_STEPS = 12_000
const MAX_STEPS = 80_000
const TARGET_SECONDS = 0.004
local steps = 0
local stepsPerFrame = INITIAL_STEPS
local haltedLogged = false
local faultMessage: string? = nil
local lastStatusAt = 0

local function refreshStatus()
	const now = os.clock()
	if now - lastStatusAt < 0.25 and not faultMessage then
		return
	end
	lastStatusAt = now
	refreshPointerVisibility()
	-- Small read-only diagnostics for Studio probes. These are local
	-- attributes and cost nothing on the network.
	screenGui:SetAttribute("VdmMouseVisible", machine.mouseVisible)
	screenGui:SetAttribute("VdmMouseX", machine.mouseX)
	screenGui:SetAttribute("VdmMouseY", machine.mouseY)
	if faultMessage then
		setStatus("Fault", faultMessage, Theme.Colors.Danger)
		return
	end
	if machine.exitCode then
		setStatus("Stopped", "exit " .. tostring(machine.exitCode), Theme.Colors.Danger)
		return
	end
	const vga = machine.vga
	if vga and vga:modeInfo().kind ~= "text" then
		const info = vga:modeInfo()
		setStatus(
			"Running",
			("%d × %d · %s"):format(info.width, info.height, colourLabel(info)),
			Color3.fromRGB(84, 200, 120)
		)
	else
		setStatus("Starting Windows...", "DOS / BIOS", Color3.fromRGB(220, 160, 64))
	end
end

refreshStatus()

cleaner:Connect(RunService.Heartbeat, function()
	if BOOT_WINDOWS then
		const now = os.clock()
		for scan in pairs(heldKeys) do
			const repeatAt = keyRepeatAt[scan]
			if not NO_REPEAT[scan] and repeatAt ~= nil and now >= repeatAt then
				keyRepeatAt[scan] = now + REPEAT_INTERVAL
				machine:keyDown(scan)
			end
		end
	end

	-- Keep the guest pointer locked to the host pointer while the pointer is
	-- over the video area. When the host stops moving, re-anchor once so a
	-- guest-side warp (dialog focus, app SetCursorPos) cannot leave a visible
	-- offset; never do this mid-drag.
	if pointerInside then
		if mouseButtons == 0 and not mouseSettled and os.clock() - lastPointerChange > 0.3 then
			mouseSettled = true
			updateMouse(nil, true)
		else
			updateMouse(nil)
		end
	end

	-- Keep calling run() even when the guest HLTs: Machine.run wakes idle
	-- Windows on the next timer tick and dispatches queued PS/2 packets.
	if not faultMessage and not machine.exitCode then
		-- a guest fault must not kill the whole client script
		const started = os.clock()
		const ok, err = pcall(function()
			steps += machine:run(stepsPerFrame)
		end)
		const elapsed = os.clock() - started
		if elapsed > TARGET_SECONDS * 1.25 then
			stepsPerFrame = math.max(MIN_STEPS, math.floor(stepsPerFrame * 0.8))
		elseif elapsed < TARGET_SECONDS * 0.5 then
			stepsPerFrame = math.min(MAX_STEPS, math.floor(stepsPerFrame * 1.06) + 500)
		end
		if not ok then
			faultMessage = tostring(err)
			machine.cpu.halted = true
			warn("[Vdm] guest fault: " .. faultMessage)
		end
		if not faultMessage then
			const vga = machine.vga
			if vga and vga:modeInfo().kind ~= "text" then
				updateVideo()
			else
				videoHost.Visible = false
				sink:update(machine.mem)
			end
		end
	end

	refreshStatus()
	if machine.cpu.halted and not haltedLogged then
		haltedLogged = true
		print(
			("[Vdm] halted exit=%s cs:ip=%04X:%04X steps=%d"):format(
				tostring(machine.exitCode),
				machine.cpu.cs,
				machine.cpu.ip,
				steps
			)
		)
	end
end)

window.Closed:Subscribe(function(closed)
	if closed then
		releaseKeys()
		UserInputService.MouseIconEnabled = true
		cleaner:Clean()
	end
end)
