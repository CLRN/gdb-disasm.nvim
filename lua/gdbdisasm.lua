local Job = require("plenary.job")
local async = require("plenary.async")
local ts_utils = require("nvim-treesitter.ts_utils")

local ns_id = vim.api.nvim_create_namespace("disnav")
local last_disasm_lines = {}
local comms = nil
local last_path = ""
local root_path = vim.fn.stdpath("data") .. "/gdb-disasm"

local function get_current_function_range()
	local current_node = ts_utils.get_node_at_cursor()
	local expr = current_node

	while expr do
		if expr:type() == "function_definition" then
			break
		end
		expr = expr:parent()
	end

	if not expr then
		return 0, 0
	end
	local range = vim.treesitter.get_range(expr)
	return range[1], range[4]
end

local function start_gdb()
	local setter, getter = async.control.channel.mpsc()
	local job = Job:new({
		command = "gdb",
		args = { "--interpreter", "mi" },

		on_stdout = function(err, line)
			setter.send(line)
		end,

		on_stderr = function(err, line)
			vim.notify(string.format("GDB error %s", line), vim.log.levels.ERROR)
		end,

		on_exit = function(j, return_val)
			if return_val ~= 0 then
				vim.notify(string.format("GDB terminated with %s", return_val), vim.log.levels.ERROR)
			else
				vim.notify(string.format("GDB terminated cleanly"), vim.log.levels.INFO)
			end
		end,
	})

	job:start()

	vim.notify(string.format("GDB started"), vim.log.levels.INFO)

	local function communicate(command)
		-- vim.print("writing '" .. command .. "'")
		job:send(command .. "\n")

		local lines = {}
		while true do
			local line = getter.recv()
			if string.sub(line, 1, 1) == "^" then
				return lines
			end

			if string.sub(line, 1, 1) == "~" then
				table.insert(lines, vim.json.decode(string.sub(line, 2)))
			end
		end
	end

	return communicate
end

local function make_sure_gdb_is_running()
	local status, cmake = pcall(require, "cmake-tools")
	if not status then
		vim.notify("unable to load cmake-tools", vim.log.levels.ERROR)
		return
	end
	local target = cmake.get_launch_target()
	if not target then
		vim.notify("unable to load cmake target", vim.log.levels.ERROR)
		return
	end

	local path = cmake.get_launch_path(target) .. target

	if not comms then
		comms = start_gdb()

		-- set some settings
		comms("set disassembly-flavor intel")
		comms("set print asm-demangle")
	end

	-- load file
	if path ~= last_path then
		last_path = path
		comms(string.format("file %s", path))
		vim.notify(string.format("Disassembly completed"), vim.log.levels.INFO)
	end
end

---Renders the disasm text
---@param buf_id integer
---@param lines table
local function draw_disasm_lines(buf_id, lines)
	vim.schedule(function()
		vim.api.nvim_buf_clear_namespace(buf_id, ns_id, 0, -1)

		for line_num, text in pairs(lines) do
			local virt_lines = {}
			for _, line in ipairs(text) do
				-- vim.print(string.format("line num: %s, line text: %s", line_num, line))
				table.insert(virt_lines, { { "    " .. line, "Comment" } })
			end

			local col_num = 0
			vim.api.nvim_buf_set_extmark(buf_id, ns_id, line_num - 1, col_num, {
				virt_lines = virt_lines,
			})
		end
		vim.notify(string.format("Disasm text is drawn"), vim.log.levels.INFO)
	end)
end

---Disassembles current function and calls provided callback with a table containing line nums and text
---@param callback function
local function disasm_current_func(callback)
	local cur_file = vim.fn.expand("%:p")
	local line_start, line_end = get_current_function_range()
	---@diagnostic disable-next-line: deprecated
	local cursor_line, _ = unpack(vim.api.nvim_win_get_cursor(0))

	async.run(function()
		make_sure_gdb_is_running()

		-- fetch what's the function address for the given lines
		local info = comms(string.format("info line %s:%s", cur_file, cursor_line))
		local func_addr = string.match(info[1], "0x[0-9a-h]+")

		-- disasm function address
		local response = comms(string.format("disassemble %s", func_addr))

		local disasm = {}
		local last_line = 1

		last_disasm_lines = {}

		for _, str in ipairs(response) do
			local addr, asm = string.match(str, "^%s+(0x[0-9a-h]+)%s+<[^>]+>:([^\n]+)")
			if addr and asm then
				local t = comms(string.format("list *%s", addr))
				local raw = t[1]
				local last = #raw - raw:reverse():find(" ") + 1
				local s = raw:sub(last + 2, -4)
				local delim = s:find(":")

				local file = s:sub(1, delim - 1)
				local line = tonumber(s:sub(delim + 1))
				if line and cur_file == file then
					last_line = line
				else
					asm = string.format("%-90s // %s:%s", asm, file, line)
					-- vim.print(string.format("unmatched file %s against %s", t[1], cur_file))
				end

				if not disasm[last_line] then
					disasm[last_line] = {}
				end

				table.insert(last_disasm_lines, string.format("%-90s // %s:%s", asm, file, last_line))

				if last_line <= line_end + 1 and last_line >= line_start then
					table.insert(disasm[last_line], asm)
				end
			end
		end

		callback(disasm)
	end)
end

local function resolve_calls_under_the_cursor()
	local cur_file = vim.fn.expand("%:p")
	---@diagnostic disable-next-line: deprecated
	local cursor_line, _ = unpack(vim.api.nvim_win_get_cursor(0))

	async.run(function()
		make_sure_gdb_is_running()

		-- fetch what's the function address for the given lines
		local info = comms(string.format("info line %s:%s", cur_file, cursor_line))

		local match = string.gmatch(info[1], "0x[0-9a-h]+")
		local addresses = {}
		for i in match do
			table.insert(addresses, i)
		end

		-- disasm function address
		local response = comms(string.format("disassemble %s,%s", addresses[1], addresses[2]))
		local names = {}
		local jumps = {}
		for _, str in ipairs(response) do
			local _, asm = string.match(str, "^%s+(0x[0-9a-h]+)%s+<[^>]+>:([^\n]+)")
			-- vim.print(asm)
			if asm and asm:find("call ") then
				local addr, name = string.match(asm, "^[^0]+(0x[0-9a-h]+)%s+([^\n]+)")
				if name then
					table.insert(names, name)
					table.insert(jumps, addr)
				end
			end
		end

		if #names == 0 then
			return
		end

		local tx, rx = async.control.channel.oneshot()
		local addr = nil

		if #names == 1 then
			addr = jumps[1]
		else
			vim.schedule(function()
				vim.ui.select(names, {
					prompt = "Pick function to jump to",
				}, function(choice, idx)
					tx(jumps[idx])
				end)
			end)

			addr = rx()
		end

		info = comms(string.format("info line *%s", addr))
		local line, file = string.match(info[1], 'Line%s(%d+)[^"]+["]([^"]+)["]')

		vim.schedule(function()
			vim.cmd(string.format(":edit %s", file))
			vim.cmd(string.format(":%d", line))
		end)
	end)
end

M = {}

M.setup = function(cfg)
	vim.keymap.set("n", "<leader>daf", function()
		disasm_current_func(function(disasm)
			draw_disasm_lines(0, disasm)
		end)
	end, { remap = true, desc = "Disassemble current function" })

	vim.keymap.set("n", "<leader>das", function()
		vim.ui.input({ prompt = "Enter name for the saved session: " }, function(input)
      if not input then
        return
      end

			local src = vim.api.nvim_buf_get_lines(0, 0, -1, false)
			local sessions_path = root_path .. "/sessions/"

			vim.fn.mkdir(sessions_path, "p")

			local file_path = sessions_path .. input

			disasm_current_func(function(disasm)
				local data = { src = src, disasm = {} }
				for line_num, text in pairs(disasm) do
					table.insert(data.disasm, { line_num = line_num, disasm = text })
				end

				vim.schedule(function()
					vim.fn.writefile({ vim.json.encode(data) }, file_path)
					vim.notify(string.format("Saved session to %s", file_path), vim.log.levels.INFO)
				end)
			end)
		end)
	end, { remap = true, desc = "Disassemble current function and save to history" })

	vim.keymap.set("n", "<leader>daq", function()
		vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)
		if comms then
			local c = comms

			async.run(function()
				c(string.format("quit"))
			end)

			comms = nil
			last_path = ""
		end
	end, { remap = true, desc = "Clean disassembly and quit GDB" })

	vim.keymap.set("n", "<leader>dad", function()
		vim.api.nvim_buf_set_lines(0, 0, -1, false, last_disasm_lines)
	end, { remap = true, desc = "Set disassembly text to current buffer for debugging" })

	vim.keymap.set("n", "<leader>dac", function()
		resolve_calls_under_the_cursor()
	end, { remap = true, desc = "Jump to a call" })
end

return M
