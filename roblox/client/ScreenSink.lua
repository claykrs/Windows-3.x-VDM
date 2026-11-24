--!nonstrict
-- ScreenSink.lua -- client-side renderer for the emulated 80x25 text screen.
-- One monospace TextLabel per row inside the window content.

const ReplicatedStorage = game:GetService("ReplicatedStorage")

const Vdm = require(ReplicatedStorage:WaitForChild("Vdm"))
const VdmUi = require(ReplicatedStorage:WaitForChild("VdmUi"))

const ScreenSink = {}
ScreenSink.__index = ScreenSink

export type ScreenSink = {
	update: (self: ScreenSink, mem: any) -> (),
}

function ScreenSink.new(cleaner: any, parent: Instance): ScreenSink
	const surface = cleaner:Add(Instance.new("Frame"))
	surface.Name = "Screen"
	surface.Size = UDim2.fromScale(1, 1)
	surface.BackgroundColor3 = VdmUi.Theme.Colors.Screen
	surface.BorderSizePixel = 0
	surface.Parent = parent

	const labels = table.create(Vdm.TextScreen.ROWS) :: { TextLabel }
	for row = 1, Vdm.TextScreen.ROWS do
		const label = cleaner:Add(Instance.new("TextLabel"))
		label.Name = "Row" .. row
		label.Size = UDim2.fromScale(1, 1 / Vdm.TextScreen.ROWS)
		label.Position = UDim2.fromScale(0, (row - 1) / Vdm.TextScreen.ROWS)
		label.BackgroundTransparency = 1
		label.Font = VdmUi.Theme.Fonts.Mono
		label.TextSize = VdmUi.Theme.Sizes.ScreenText
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextColor3 = VdmUi.Theme.Colors.ScreenText
		label.Text = ""
		label.Parent = surface
		labels[row] = label
	end

	return setmetatable({ labels = labels }, ScreenSink) :: any
end

function ScreenSink.update(self: ScreenSink, mem: any)
	const rows = Vdm.TextScreen.rows(mem)
	const labels = (self :: any).labels
	for index, row in rows do
		labels[index].Text = row.text
	end
end

return ScreenSink
