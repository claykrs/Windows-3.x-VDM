--!strict
-- Emulator.client -- runs the Vdm machine on the CLIENT (full frame budget,
-- zero replication), renders into a Windows 3.0-style host window and feeds
-- keyboard/PS/2 input.

const ReplicatedStorage = game:GetService("ReplicatedStorage")
const RunService = game:GetService("RunService")
const UserInputService = game:GetService("UserInputService")
const Players = game:GetService("Players")
const StarterGui = game:GetService("StarterGui")

const SoundService = game:GetService("SoundService")
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

-- PC speaker host bridge: the guest beep is a state change on PIT channel 2
-- gated by port 0x61. Roblox has no raw audio synthesis, so each guest
-- on-edge/frequency change retriggers one short stock beep. This is optional:
-- if the asset cannot play, the emulator still runs silently.
const speakerBeep = cleaner:Add(Instance.new("Sound"))
speakerBeep.Name = "PcSpeaker"
speakerBeep.SoundId = "rbxasset://sounds/electronicpingshort.wav"
speakerBeep.Volume = 0.35
speakerBeep.RollOffMode = Enum.RollOffMode.Inverse
speakerBeep.Parent = SoundService
local lastSpeakerSequence = 0
local lastBeepAt = 0

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
screenGui.IgnoreGuiInset = true
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

local function fitWindow(): UDim2
	const viewport = viewportSize()
	-- the ScreenGui covers the full viewport (IgnoreGuiInset), so the only
	-- reservation is a small margin
	const availableWidth = math.max(320, viewport.X - 32)
	const availableHeight = math.max(240, viewport.Y - 32)
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
	Xms = Vdm.Xms,
	logger = function(message: string)
		print("[Vdm] " .. message)
	end,
})
-- Automation/debug surface (Studio MCP probes): never used by the UI.
-- _G is per script context in Studio, so the machine is shared through a
-- BindableFunction: Invoke("mouse", x, y), Invoke("sync"), Invoke("state").
const machineBridge = cleaner:Add(Instance.new("BindableFunction"))
machineBridge.Name = "VdmMachineBridge"
machineBridge.OnInvoke = function(command: string, a: number?, b: number?)
	if command == "mouse" then
		machine:setMouse(a or 0, b or 0, machine.mouseButtons)
		return true
	elseif command == "sync" then
		return machine:syncMouse()
	elseif command == "click" then
		machine:setMouse(machine.mouseX, machine.mouseY, 1)
		task.wait(0.1)
		machine:setMouse(machine.mouseX, machine.mouseY, 0)
		return true
	end
	return {
		mouseX = machine.mouseX,
		mouseY = machine.mouseY,
		buttons = machine.mouseButtons,
		ps2 = machine.mousePs2Enabled,
		packets = #machine.mousePackets,
		mickeyX = machine.mouseMickeyX,
		mickeyY = machine.mouseMickeyY,
		minX = machine.mouseMinX,
		minY = machine.mouseMinY,
		maxX = machine.mouseMaxX,
		maxY = machine.mouseMaxY,
	}
end
machineBridge.Parent = playerGui
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

local pointerOverWindow = false
local guestPointerAvailable = false
local pointerCapture = false
local captureArmed = true
local captureStartedAt = 0
local pointerOverSince = 0
local mouseButtons = 0
local mouseSynced = false
local lastPointer = Vector2.zero
local lastSinkPosition = Vector2.zero
local lastSinkSize = Vector2.zero
local vgaSink: any = nil
local vgaWidth, vgaHeight = 0, 0
-- The entry anchor sends the cursor to (0,0) followed by the real target.
-- Hold the next frame so the intermediate position is never displayed.
local suppressVideoUntil = 0

local function hasGuestPointer(): boolean
	return machine.mousePs2Enabled and machine.mouseDeviceHandler ~= nil
end

local function refreshPointerVisibility()
	-- Hide the host arrow while the pointer is anywhere over the host window
	-- (video, title or status bar): Windows draws its own cursor in the video
	-- area, and Studio still paints the OS arrow over the viewport. Keeping the
	-- host arrow hidden for the whole window leaves exactly one cursor.
	guestPointerAvailable = hasGuestPointer()
	const shouldCapture = RunService:IsStudio()
		and pointerOverWindow
		and guestPointerAvailable
		and captureArmed
		and os.clock() - pointerOverSince >= 0.2
	if shouldCapture and not pointerCapture then
		-- Seed the virtual pointer before the host cursor is locked. lastPointer
		-- is the real absolute sample from this frame, so the guest does not
		-- jump to the lock point.
		captureStartedAt = os.clock()
	end
	if not shouldCapture then
		-- Moving the virtual pointer out of the window releases the host cursor
		-- so Studio remains usable; it re-arms after the real pointer leaves.
		if pointerCapture and not pointerOverWindow then
			captureArmed = false
		end
		pointerCapture = false
	end
	pointerCapture = shouldCapture
	const hide = pointerOverWindow and guestPointerAvailable and pointerCapture
	UserInputService.MouseIconEnabled = not hide
	if RunService:IsStudio() then
		const behavior = pointerCapture and Enum.MouseBehavior.LockCurrentPosition
			or Enum.MouseBehavior.Default
		if UserInputService.MouseBehavior ~= behavior then
			UserInputService.MouseBehavior = behavior
		end
	end
end

local function setPointerState(overWindow: boolean)
	if overWindow and not pointerOverWindow then
		pointerOverSince = os.clock()
	end
	pointerOverWindow = overWindow
	if not pointerCapture and not overWindow then
		-- The real pointer left the host window: allow a fresh capture on entry.
		captureArmed = true
	end
	-- Called every frame: the 0.2s settle delay and the virtual-pointer exit
	-- both need to be re-evaluated even when the boolean state is unchanged.
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
local function updateMouse(position: Vector2?)
	if not vgaSink or not vgaSink.root or not videoHost.Visible then
		setPointerState(false)
		return
	end
	if position then
		-- InputObject.Position is a Vector3; lastPointer stays a Vector2 in
		-- GUI space, and the Heartbeat poll adds Vector2 deltas to it.
		const guiPos = Vector2.new(position.X, position.Y)
		-- While captured the real pointer is locked; InputChanged still reports
		-- the frozen position. Use the virtual pointer driven by GetMouseDelta.
		if not pointerCapture then
			lastPointer = guiPos
		end
	end
	const size = vgaSink.root.AbsoluteSize
	const at = vgaSink.root.AbsolutePosition
	if size.X <= 0 or size.Y <= 0 then
		setPointerState(false)
		return
	end
	-- AbsolutePosition/AbsoluteSize are read on every sample, including the
	-- Heartbeat poll below, so a window move or clamp cannot leave the cached
	-- rect making a pointer that is visually inside look outside.
	const resized = size ~= lastSinkSize
	const jumped = math.abs(at.X - lastSinkPosition.X) > 32
		or math.abs(at.Y - lastSinkPosition.Y) > 32
	lastSinkPosition = at
	lastSinkSize = size
	if (resized or jumped) and hasGuestPointer() then
		-- Re-anchor after a resize or a clamp jump: a smooth drag is only a few
		-- pixels per frame, while a clamp can move the window far enough that a
		-- missed relative packet would leave the guest cursor offset.
		mouseSynced = false
		suppressVideoUntil = os.clock() + 0.05
	end
	const winAt = window.Gui.AbsolutePosition
	const winSize = window.Gui.AbsoluteSize
	const overWindow = lastPointer.X >= winAt.X
		and lastPointer.X <= winAt.X + winSize.X
		and lastPointer.Y >= winAt.Y
		and lastPointer.Y <= winAt.Y + winSize.Y
	-- InputObject.Position and AbsolutePosition share the same GUI space (both
	-- exclude the topbar inset). GetMouseLocation adds the inset, so the
	-- Heartbeat poll subtracts it before reaching this function.
	const pos = lastPointer
	const fx = (pos.X - at.X) / size.X
	const fy = (pos.Y - at.Y) / size.Y
	const inside = fx >= 0 and fx <= 1 and fy >= 0 and fy <= 1
	setPointerState(overWindow)
	if not inside then
		if window.Gui then
			window.Gui:SetAttribute("VdmPointerInside", false)
			window.Gui:SetAttribute("VdmWindowHover", overWindow)
			window.Gui:SetAttribute("VdmPointerGuest", Vector2.new(-1, -1))
			window.Gui:SetAttribute("VdmSinkPosition", at)
			window.Gui:SetAttribute("VdmSinkSize", size)
		end
		return
	end
	if hasGuestPointer() and not mouseSynced then
		-- Anchor once, when the guest mouse driver first becomes available or
		-- after the host window changed geometry. Never re-clamp on clicks: that
		-- teleports the guest cursor to (0,0) for a frame.
		mouseSynced = machine:syncMouse()
		if mouseSynced then
			suppressVideoUntil = os.clock() + 0.05
		end
		refreshPointerVisibility()
	end
	const guestX = math.clamp(math.floor(fx * vgaSink.width), 0, vgaSink.width - 1)
	const guestY = math.clamp(math.floor(fy * vgaSink.height), 0, vgaSink.height - 1)
	machine:setMouse(guestX, guestY, mouseButtons)
	if window.Gui then
		window.Gui:SetAttribute("VdmPointerInside", true)
		window.Gui:SetAttribute("VdmWindowHover", overWindow)
		window.Gui:SetAttribute("VdmPointerGuest", Vector2.new(guestX, guestY))
		window.Gui:SetAttribute("VdmSinkPosition", at)
		window.Gui:SetAttribute("VdmSinkSize", size)
	end
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
		updateMouse(input.Position)
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		mouseButtons = bit32.bor(mouseButtons, 2)
		updateMouse(input.Position)
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

	-- Poll the pointer every frame instead of trusting the last InputChanged
	-- sample. The host window can move or clamp under a stationary pointer, and
	-- a cached rect must never make a visually-inside pointer look outside (or
	-- leave the OS cursor visible over the guest).
	if pointerCapture then
		if os.clock() - captureStartedAt >= 0.05 then
			const delta = UserInputService:GetMouseDelta()
			if delta.X ~= 0 or delta.Y ~= 0 then
				-- GetMouseDelta returns Vector3 on this client; lastPointer is
				-- a Vector2 in GUI space.
				lastPointer += Vector2.new(delta.X, delta.Y)
			end
		end
		updateMouse(nil)
	else
		const mouse = UserInputService:GetMouseLocation()
		-- IgnoreGuiInset is on, so GUI space and GetMouseLocation share the
		-- same origin (true screen top-left); no inset compensation.
		if mouse.X >= 0 and mouse.Y >= 0 then
			updateMouse(Vector2.new(mouse.X, mouse.Y))
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
	-- Guard against a stale Studio core that predates the 8254 speaker model.
	const speaker = if machine.speakerState then machine:speakerState() else nil
	if speaker and speaker.sequence ~= lastSpeakerSequence then
		lastSpeakerSequence = speaker.sequence
		if speaker.enabled and speaker.frequency > 0 and os.clock() - lastBeepAt >= 0.03 then
			lastBeepAt = os.clock()
			speakerBeep.PlaybackSpeed = math.clamp(speaker.frequency / 880, 0.5, 2)
			speakerBeep.TimePosition = 0
			pcall(function()
				speakerBeep:Play()
			end)
		end
	end
	window.Gui:SetAttribute(
		"VdmSpeaker",
		Vector2.new(speaker.frequency, if speaker.enabled then 1 else 0)
	)
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
		if UserInputService.MouseBehavior ~= Enum.MouseBehavior.Default then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end
		cleaner:Clean()
	end
end)
