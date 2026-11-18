--!strict
-- TextScreen.lua -- reads the 80x25 text screen out of memory.

const TextScreen = {}
TextScreen.COLS = 80
TextScreen.ROWS = 25
TextScreen.BASE = 0xB8000

export type Row = {
	text: string,
	attrs: string,
}

export type ByteReader = {
	read8: (self: any, addr: number) -> number,
}

-- returns one row per line: { text = "80 chars", attrs = "80 attribute bytes" }
function TextScreen.rows(mem: ByteReader): { Row }
	local rows = table.create(TextScreen.ROWS) :: { Row }
	for y = 0, TextScreen.ROWS - 1 do
		local chars = table.create(TextScreen.COLS) :: { string }
		local attrs = table.create(TextScreen.COLS) :: { string }
		for x = 0, TextScreen.COLS - 1 do
			const cell = TextScreen.BASE + (y * TextScreen.COLS + x) * 2
			const byte = mem:read8(cell)
			chars[x + 1] = (byte >= 32 and byte < 127) and string.char(byte) or " "
			attrs[x + 1] = string.char(mem:read8(cell + 1))
		end
		rows[y + 1] = { text = table.concat(chars), attrs = table.concat(attrs) }
	end
	return rows
end

-- plain text (trailing spaces trimmed per row) for tests and logging
function TextScreen.plain(mem: ByteReader): string
	local rows = TextScreen.rows(mem)
	local lines = table.create(#rows) :: { string }
	for index, row in rows do
		lines[index] = row.text:gsub(" +$", "")
	end
	return table.concat(lines, "\n")
end

return TextScreen
