--!nonstrict
-- World.server.lua -- RVDM is drawn entirely in PlayerGui. Keep the 3D world
-- empty so a character, spawn pad or baseplate cannot show behind the desktop.

const Players = game:GetService("Players")
const Workspace = game:GetService("Workspace")

-- No character means no camera follow, no respawns and no reset prompt.
Players.CharacterAutoLoads = false

local function clear(instance: Instance)
	if
		instance:IsA("SpawnLocation")
		or (instance:IsA("BasePart") and instance.Name == "Baseplate")
	then
		instance:Destroy()
	end
end

for _, child in Workspace:GetChildren() do
	clear(child)
end
Workspace.ChildAdded:Connect(clear)

Players.PlayerAdded:Connect(function(player: Player)
	player.CharacterAdded:Connect(function(character: Model)
		character:Destroy()
	end)
	if player.Character then
		player.Character:Destroy()
	end
end)
