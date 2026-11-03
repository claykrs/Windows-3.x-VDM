--!strict
-- Vfs.lua -- in-memory DOS filesystem (C: tree, uppercase paths).

const Vfs = {}
Vfs.__index = Vfs

export type DirNode = {
	type: "dir",
	children: { [string]: Node },
}

export type FileNode = {
	type: "file",
	data: string,
}

export type Node = DirNode | FileNode

export type Vfs = typeof(setmetatable({} :: { root: DirNode, cwd: string }, Vfs))

function Vfs.new(): Vfs
	return setmetatable({
		root = { type = "dir", children = {} },
		cwd = "C:\\",
	}, Vfs)
end

-- normalize: backslashes, uppercase, strip drive, split into parts
local function split(path: string): { string }
	path = string.gsub(string.upper(path), "/", "\\")
	if #path >= 2 and string.sub(path, 2, 2) == ":" then
		path = string.sub(path, 3)
	end
	if string.sub(path, 1, 1) == "\\" then
		path = string.sub(path, 2)
	end
	local parts: { string } = {}
	for part in string.gmatch(path, "[^\\]+") do
		parts[#parts + 1] = part
	end
	return parts
end

function Vfs:lookup(path: string): Node?
	local node: Node = self.root
	for _, name in split(path) do
		if node.type ~= "dir" then
			return nil
		end
		const child = node.children[name]
		if not child then
			return nil
		end
		node = child
	end
	return node
end

-- returns (parentNode, lastName) or nil
function Vfs:parentOf(path: string): (DirNode?, string?)
	local parts = split(path)
	local node: DirNode = self.root
	for index = 1, #parts - 1 do
		const child = node.children[parts[index]]
		if not child or child.type ~= "dir" then
			return nil, nil
		end
		node = child
	end
	return node, parts[#parts]
end

function Vfs:resolve(path: string, cwd: string?): string
	path = string.gsub(path, "/", "\\")
	if #path >= 2 and string.sub(path, 2, 2) == ":" then
		if string.sub(path, 3, 3) ~= "\\" then
			path = string.sub(path, 1, 2) .. "\\" .. string.sub(path, 3)
		end
		return string.upper(path)
	end
	if string.sub(path, 1, 1) == "\\" then
		return "C:" .. string.upper(path)
	end
	return (cwd or "C:\\") .. string.upper(path)
end

-- create all missing directory levels for an absolute path
function Vfs:ensureDir(path: string): boolean
	local node: DirNode = self.root
	for _, name in split(path) do
		local child = node.children[name]
		if not child then
			child = { type = "dir", children = {} }
			node.children[name] = child
		end
		if child.type ~= "dir" then
			return false
		end
		node = child
	end
	return true
end

function Vfs:writeFile(path: string, data: string): boolean
	local parent, name = self:parentOf(path)
	if not parent or not name then
		return false
	end
	local node = parent.children[name]
	if node and node.type ~= "file" then
		return false
	end
	if not node then
		node = { type = "file", data = "" }
		parent.children[name] = node
	end
	if node.type ~= "file" then
		return false
	end
	node.data = data
	return true
end

function Vfs:readFile(path: string): string?
	const node = self:lookup(path)
	if node and node.type == "file" then
		return node.data
	end
	return nil
end

function Vfs:mkdir(path: string): (boolean, number?)
	local parent, name = self:parentOf(path)
	if not parent or not name then
		return false, 3
	end
	if parent.children[name] then
		return false, 5
	end
	parent.children[name] = { type = "dir", children = {} }
	return true, nil
end

function Vfs:delete(path: string): (boolean, number?)
	local parent, name = self:parentOf(path)
	if not parent or not name then
		return false, 2
	end
	const node = parent.children[name]
	if not node then
		return false, 2
	end
	if node.type ~= "file" then
		return false, 5
	end
	parent.children[name] = nil
	return true, nil
end

function Vfs:setCwd(path: string, cur: string?): (boolean, number?)
	const abs = self:resolve(path, cur)
	const node = self:lookup(abs)
	if not node or node.type ~= "dir" then
		return false, 3
	end
	if abs == "C:" or abs == "C:\\" then
		self.cwd = "C:\\"
	else
		self.cwd = abs .. "\\"
	end
	return true, nil
end

function Vfs:exists(path: string): boolean
	return self:lookup(path) ~= nil
end

export type ListEntry = {
	name: string,
	size: number,
	dir: boolean,
}

-- Directory listing for DOS FindFirst/FindNext (AH=11/12 and AH=4E/4F).
function Vfs:list(path: string): { ListEntry }?
	const node = self:lookup(path)
	if not node then
		return nil
	end
	if node.type ~= "dir" then
		return nil
	end
	local out: { ListEntry } = {}
	const children: { [string]: Node } = node.children
	for name, child in children do
		local size = 0
		if child.type == "file" then
			size = #child.data
		end
		out[#out + 1] = {
			name = name,
			size = size,
			dir = child.type == "dir",
		}
	end
	table.sort(out, function(a: ListEntry, b: ListEntry): boolean
		return a.name < b.name
	end)
	return out
end

return Vfs
