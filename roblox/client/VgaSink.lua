--!nonstrict
-- VgaSink.lua -- Roblox display sink for core/Vga framebuffers.
--
-- Pixel format: flat RGBA8, four bytes per pixel (R, G, B, A), row-major from
-- the top-left. This is exactly what Vga:snapshotRGBA() returns (and what
-- EditableImage:WritePixelsBuffer expects). Alpha is always 255 in VGA output.
--
-- Cadence: call UpdateRGBA / UpdateRegionRGBA at most once per rendered frame,
-- ideally from RunService.RenderStepped or a 30/60 Hz accumulator. Roblox only
-- applies one EditableImage update per displayed frame, so pushing every
-- emulated instruction would queue work without improving the picture. A full
-- 640x480 upload is 1,228,800 bytes; use UpdateRegionRGBA with the rectangle
-- from Vga:consumeDirty() when only part of the screen changed.
--
-- The sink is fixed-size. Create it with the active VGA mode's dimensions and
-- recreate it when the mode changes (640x480 for mode 12h, 320x200 for 13h,
-- 640x400 for the text fallback).
--
-- API:
--   VgaSink.new(parent, width, height) -> VgaSink
--   sink:UpdateRGBA(buffer)                    -- full frame
--   sink:UpdateRegionRGBA(buffer, x, y, w, h)  -- full-frame buffer + dirty rect
--   sink:UpdatePixels(table)                   -- full frame, flat RGBA8 table
--   sink:Destroy()
--   sink.kind: "editable" | "grid" | "placeholder"
--
-- If EditableImage cannot be created, attached, or written (permission,
-- memory-budget, or client-version problems), the sink builds a coarse Frame
-- grid (32 x ~24 cells) so the emulator still shows a low-resolution picture.
-- If even that is unavailable it leaves a labelled placeholder. Current
-- clients cap EditableImage at 1024x1024; 640x480 fits comfortably.

const AssetService = game:GetService("AssetService")

const VgaSink = {}
VgaSink.__index = VgaSink

const GRID_COLUMNS = 32
const GRID_INTERVAL = 1 / 15

local function toChannel(value: number): number
	return math.clamp(math.floor(tonumber(value) or 0), 0, 255)
end

local function makeRoot(parent: Instance, width: number, height: number): Frame
	local root = Instance.new("Frame")
	root.Name = "VgaSink"
	root.BackgroundColor3 = Color3.new(0, 0, 0)
	root.BorderSizePixel = 0
	root.ClipsDescendants = true
	root.Size = UDim2.fromScale(1, 1)
	-- The aspect constraint may letterbox a 4:3 screen inside a wider host
	-- window; center it so the bars are symmetric instead of one black band.
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.5, 0.5)
	root.Parent = parent

	pcall(function()
		const aspect = Instance.new("UIAspectRatioConstraint")
		aspect.AspectRatio = width / height
		aspect.AspectType = Enum.AspectType.FitWithinMaxSize
		aspect.DominantAxis = Enum.DominantAxis.Width
		aspect.Parent = root
	end)
	return root
end

local function makeEditableImage(width: number, height: number): any?
	const ok, image = pcall(function()
		return AssetService:CreateEditableImage({ Size = Vector2.new(width, height) })
	end)
	if not ok or image == nil then
		return nil
	end
	return image
end

local function attachEditableImage(label: ImageLabel, image: any): boolean
	const ok = pcall(function()
		label.ImageContent = Content.fromObject(image)
	end)
	return ok
end

local function makeImageLabel(root: Frame): ImageLabel
	const label = Instance.new("ImageLabel")
	label.Name = "Screen"
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Size = UDim2.fromScale(1, 1)
	label.ScaleType = Enum.ScaleType.Stretch
	pcall(function()
		label.ResampleMode = Enum.ResamplerMode.Pixelated
	end)
	label.Parent = root
	return label
end

local function makePlaceholder(root: Frame, message: string): TextLabel
	const label = Instance.new("TextLabel")
	label.Name = "Placeholder"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = Color3.fromRGB(16, 16, 16)
	label.BorderSizePixel = 0
	label.TextColor3 = Color3.fromRGB(220, 220, 220)
	label.TextScaled = true
	label.TextWrapped = true
	label.Font = Enum.Font.Code
	label.Text = message
	label.Parent = root
	return label
end

local function buildGrid(root: Frame, width: number, height: number): ({ Frame }, number, number)
	const columns = math.min(GRID_COLUMNS, width)
	const rows = math.max(1, math.floor(columns * height / width + 0.5))
	const cells = table.create(columns * rows)
	local index = 1
	for row = 0, rows - 1 do
		for column = 0, columns - 1 do
			const cell = Instance.new("Frame")
			cell.Name = string.format("Cell_%d_%d", column, row)
			cell.BackgroundColor3 = Color3.new(0, 0, 0)
			cell.BorderSizePixel = 0
			cell.Size = UDim2.fromScale(1 / columns, 1 / rows)
			cell.Position = UDim2.fromScale(column / columns, row / rows)
			cell.Parent = root
			cells[index] = cell
			index += 1
		end
	end
	return cells, columns, rows
end

function VgaSink.new(parent: Instance, width: number, height: number): VgaSink
	assert(parent ~= nil, "VgaSink.new needs a parent Instance")
	assert(width > 0 and height > 0, "VgaSink dimensions must be positive")

	const self = setmetatable({}, VgaSink) :: any
	self.width = math.max(1, math.floor(width))
	self.height = math.max(1, math.floor(height))
	self.kind = "placeholder"
	self.updateCount = 0
	self.lastError = nil
	self.warned = false
	self.lastGridUpdate = -GRID_INTERVAL
	self.regionBuffer = nil
	self.root = makeRoot(parent, self.width, self.height)

	const image = makeEditableImage(self.width, self.height)
	if image ~= nil then
		const label = makeImageLabel(self.root)
		if attachEditableImage(label, image) then
			self.kind = "editable"
			self.imageLabel = label
			self.editableImage = image
			return self
		end
		pcall(function()
			image:Destroy()
		end)
		label:Destroy()
		self.lastError = "EditableImage could not be attached to an ImageLabel"
	end

	const gridOk, cells, columns, rows = pcall(buildGrid, self.root, self.width, self.height)
	if gridOk then
		self.cells = cells
		self.gridColumns = columns
		self.gridRows = rows
		self.kind = "grid"
		if self.lastError == nil then
			self.lastError = "EditableImage unavailable; using a coarse Frame grid"
		end
	else
		self.kind = "placeholder"
		self.lastError = "VGA display unavailable: " .. tostring(cells)
		makePlaceholder(self.root, "VGA display unavailable\n" .. tostring(cells))
	end
	if self.lastError ~= nil then
		self:reportError(self.lastError)
	end
	return self
end

function VgaSink.reportError(self: VgaSink, message: string)
	self.lastError = message
	if not self.warned then
		self.warned = true
		warn("[VgaSink] " .. message)
	end
end

function VgaSink.fallbackToGrid(self: VgaSink, reason: string)
	if self.kind == "grid" or self.kind == "placeholder" or self.root == nil then
		return
	end
	if self.imageLabel ~= nil then
		self.imageLabel:Destroy()
		self.imageLabel = nil
	end
	if self.editableImage ~= nil then
		pcall(function()
			self.editableImage:Destroy()
		end)
		self.editableImage = nil
	end
	const gridOk, cells, columns, rows = pcall(buildGrid, self.root, self.width, self.height)
	if gridOk then
		self.cells = cells
		self.gridColumns = columns
		self.gridRows = rows
		self.kind = "grid"
	else
		self.kind = "placeholder"
		makePlaceholder(self.root, "VGA display unavailable\n" .. tostring(cells))
	end
	self:reportError(reason)
end

function VgaSink.updateGridFromBuffer(self: VgaSink, pixels: buffer): boolean
	const needed = self.width * self.height * 4
	if buffer.len(pixels) < needed then
		self:reportError("UpdateRGBA buffer is too small")
		return false
	end
	const now = os.clock()
	if now - self.lastGridUpdate < GRID_INTERVAL then
		return true
	end
	self.lastGridUpdate = now

	local index = 1
	for row = 0, self.gridRows - 1 do
		const y = math.min(self.height - 1, math.floor((row + 0.5) * self.height / self.gridRows))
		for column = 0, self.gridColumns - 1 do
			const x =
				math.min(self.width - 1, math.floor((column + 0.5) * self.width / self.gridColumns))
			const offset = (y * self.width + x) * 4
			const cell = self.cells[index]
			cell.BackgroundColor3 = Color3.fromRGB(
				buffer.readu8(pixels, offset),
				buffer.readu8(pixels, offset + 1),
				buffer.readu8(pixels, offset + 2)
			)
			index += 1
		end
	end
	return true
end

function VgaSink.updateGridFromTable(self: VgaSink, pixels: { number }): boolean
	const needed = self.width * self.height * 4
	if #pixels < needed then
		self:reportError("UpdatePixels table is too small")
		return false
	end
	const now = os.clock()
	if now - self.lastGridUpdate < GRID_INTERVAL then
		return true
	end
	self.lastGridUpdate = now

	local index = 1
	for row = 0, self.gridRows - 1 do
		const y = math.min(self.height - 1, math.floor((row + 0.5) * self.height / self.gridRows))
		for column = 0, self.gridColumns - 1 do
			const x =
				math.min(self.width - 1, math.floor((column + 0.5) * self.width / self.gridColumns))
			const offset = (y * self.width + x) * 4 + 1
			const cell = self.cells[index]
			cell.BackgroundColor3 = Color3.fromRGB(
				toChannel(pixels[offset]),
				toChannel(pixels[offset + 1]),
				toChannel(pixels[offset + 2])
			)
			index += 1
		end
	end
	return true
end

function VgaSink.UpdateRGBA(self: VgaSink, pixels: buffer): boolean
	if pixels == nil then
		return false
	end
	if self.kind == "grid" then
		return self:updateGridFromBuffer(pixels)
	end
	if self.kind ~= "editable" or self.editableImage == nil then
		return false
	end
	const needed = self.width * self.height * 4
	if buffer.len(pixels) < needed then
		self:reportError("UpdateRGBA buffer is too small")
		return false
	end
	const ok, err = pcall(function()
		self.editableImage:WritePixelsBuffer(
			Vector2.zero,
			Vector2.new(self.width, self.height),
			pixels
		)
	end)
	if not ok then
		self:fallbackToGrid("EditableImage write failed: " .. tostring(err))
		if self.kind == "grid" then
			return self:updateGridFromBuffer(pixels)
		end
		return false
	end
	self.updateCount += 1
	return true
end

function VgaSink.UpdateRegionRGBA(
	self: VgaSink,
	pixels: buffer,
	x: number,
	y: number,
	width: number,
	height: number
): boolean
	if pixels == nil then
		return false
	end
	if self.kind == "grid" then
		return self:updateGridFromBuffer(pixels)
	end
	if self.kind ~= "editable" or self.editableImage == nil then
		return false
	end
	const needed = self.width * self.height * 4
	if buffer.len(pixels) < needed then
		self:reportError("UpdateRegionRGBA buffer must be a full-frame snapshot")
		return false
	end

	const x0 = math.max(0, math.floor(x))
	const y0 = math.max(0, math.floor(y))
	const x1 = math.min(self.width, math.floor(x + width))
	const y1 = math.min(self.height, math.floor(y + height))
	if x1 <= x0 or y1 <= y0 then
		return true
	end
	const regionWidth = x1 - x0
	const regionHeight = y1 - y0
	if regionWidth == self.width and regionHeight == self.height then
		return self:UpdateRGBA(pixels)
	end

	const bytes = regionWidth * regionHeight * 4
	-- EditableImage:WritePixelsBuffer requires the buffer length to equal the
	-- region size exactly. Reusing a buffer from a larger previous dirty
	-- rectangle uploads too many bytes and fails, so resize on any mismatch.
	if self.regionBuffer == nil or buffer.len(self.regionBuffer) ~= bytes then
		self.regionBuffer = buffer.create(bytes)
	end
	for row = 0, regionHeight - 1 do
		buffer.copy(
			self.regionBuffer,
			row * regionWidth * 4,
			pixels,
			((y0 + row) * self.width + x0) * 4,
			regionWidth * 4
		)
	end

	const ok, err = pcall(function()
		self.editableImage:WritePixelsBuffer(
			Vector2.new(x0, y0),
			Vector2.new(regionWidth, regionHeight),
			self.regionBuffer
		)
	end)
	if not ok then
		self:fallbackToGrid("EditableImage region write failed: " .. tostring(err))
		if self.kind == "grid" then
			return self:updateGridFromBuffer(pixels)
		end
		return false
	end
	self.updateCount += 1
	return true
end

function VgaSink.UpdatePixels(self: VgaSink, pixels: { number }): boolean
	if pixels == nil then
		return false
	end
	if self.kind == "grid" then
		return self:updateGridFromTable(pixels)
	end
	if self.kind ~= "editable" or self.editableImage == nil then
		return false
	end
	const needed = self.width * self.height * 4
	if #pixels < needed then
		self:reportError("UpdatePixels table is too small")
		return false
	end

	const ok, err = pcall(function()
		self.editableImage:WritePixels(Vector2.zero, Vector2.new(self.width, self.height), pixels)
	end)
	if ok then
		self.updateCount += 1
		return true
	end

	-- Some clients removed the table API; convert once and use the buffer path.
	const converted = buffer.create(needed)
	for index = 0, self.width * self.height - 1 do
		const source = index * 4 + 1
		const destination = index * 4
		for component = 0, 3 do
			buffer.writeu8(
				converted,
				destination + component,
				toChannel(pixels[source + component])
			)
		end
	end
	self:reportError("WritePixels table API failed; converted to a buffer: " .. tostring(err))
	return self:UpdateRGBA(converted)
end

function VgaSink.Destroy(self: VgaSink)
	if self.editableImage ~= nil then
		pcall(function()
			self.editableImage:Destroy()
		end)
		self.editableImage = nil
	end
	if self.root ~= nil then
		self.root:Destroy()
		self.root = nil
	end
	self.cells = nil
	self.imageLabel = nil
	self.kind = "destroyed"
end

return VgaSink
