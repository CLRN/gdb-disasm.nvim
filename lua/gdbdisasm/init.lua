local Job = require("plenary.job")
local async = require("plenary.async")
local ts_utils = require("nvim-treesitter.ts_utils")
local log = require("gdbdisasm.log")

local ns_id_asm = vim.api.nvim_create_namespace("disnav-asm")
local ns_id_hl = vim.api.nvim_create_namespace("disnav-hl")
local group_id = vim.api.nvim_create_augroup("disnav", { clear = true })

local last_disasm_lines = {}
local last_binary_path = ""
local comms = nil
local last_disasm_target = nil
local root_path = vim.fn.stdpath("data") .. "/gdb-disasm"
local sessions_path = root_path .. "/sessions/"
local is_auto_reload_enabled = false

local function parse_asm(src)
	local tree = vim.treesitter.get_string_parser(src, "asm", {})
	local root = tree:parse(true)[1]:root()

	local asm_lines = {}

	local visit = function(v, obj, lvl)
		if not obj or lvl > 2 then
			return
		end

		if lvl == 2 then
			local text = vim.treesitter.get_node_text(obj, src)
			table.insert(asm_lines, { obj:type(), text })
			log.fmt_trace("lvl %s, type: %s, text: %s", lvl, obj:type(), text or "null")
		end

		for child, _ in obj:iter_children() do
			v(v, child, lvl + 1)
		end
	end

	visit(visit, root, 0)
	return asm_lines
end

local function create_asm_with_highlights(asm_lines)
	local hl_map = {
		["word"] = "@function.builtin.asm",
		["ptr"] = "@variable.builtin.asm",
		["int"] = "@number.asm",
		["ERROR"] = "@variable.builtin.asm",
		[","] = "@operator.asm",
		["tc_infix"] = "@variable.builtin.asm",
	}

	local res = {}
	local last_type = ""
	for idx, data in ipairs(asm_lines) do
		if
			data[2] == ">"
			or data[2] == "<"
			or data[2] == "("
			or data[2] == ")"
			or data[2] == "::"
			or data[2] == "~"
		then
			data[1] = "," -- treat as punctuation
		end
		if data[2] == "PTR" then
			data[1] = "@variable.builtin.asm" -- treat as builtin
		end

		local pattern = "%s"
		if idx == 1 then
			pattern = "\t\t%-10s"
		elseif last_type ~= "," and data[1] ~= "," then
			pattern = " %s"
		end

		local hl = hl_map[data[1]] or "@variable.builtin.asm"
		log.fmt_trace("type %s, text: %s, hl: %s", data[1], data[2], hl)
		table.insert(res, { string.format(pattern, data[2]), { "Comment", hl } })
		last_type = data[1]
	end

	return res
end

local function get_ts_current_node()
	local current_node = ts_utils.get_node_at_cursor()
	local expr = current_node

	while expr do
		if expr:type() == "function_definition" then
			break
		end
		expr = expr:parent()
	end
	return expr
end

local function get_current_function_range()
	local expr = get_ts_current_node()
	if not expr then
		return 0, 0
	end

	local range = vim.treesitter.get_range(expr)
	return range[1], range[4]
end

local function get_current_function_name()
	local expr = get_ts_current_node()
	return ts_utils.get_node_text(expr:child(1))[1]
end

local function start_gdb()
	local setter, getter = async.control.channel.mpsc()
	local job = Job:new({
		command = "gdb",
		args = { "--interpreter", "mi" },

		on_stdout = function(_, line)
			setter.send(line)
		end,

		on_stderr = function(_, line)
			vim.notify(string.format("GDB error %s", line), vim.log.levels.ERROR)
		end,

		on_exit = function(_, return_val)
			if return_val ~= 0 then
				vim.notify(string.format("GDB terminated with %s", return_val), vim.log.levels.ERROR)
			else
				vim.notify(string.format("GDB terminated cleanly"), vim.log.levels.INFO)
			end
		end,
	})

	job:start()

	vim.notify(string.format("GDB started"), vim.log.levels.INFO)

	local function communicate(commands)
		log.trace("writing '" .. table.concat(commands, ",") .. "'")
		local lines = {}
		for _, cmd in ipairs(commands) do
			job:send(cmd .. "\n")
			table.insert(lines, {})
		end

		local count = 0
		while true do
			local line = getter.recv()

			log.trace("reading '" .. line .. "'")

			if string.sub(line, 1, 1) == "^" then
				count = count + 1
				if count == #commands then
					return lines
				end
			end

			if string.sub(line, 1, 1) == "~" then
				table.insert(lines[count + 1], vim.json.decode(string.sub(line, 2)))
			end
		end
	end

	return communicate
end

---Starts GDB if not running, loads symbol if the path changed or forced
---@param force boolean
local function make_sure_gdb_is_up_to_date(force)
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
		comms({ "set disassembly-flavor intel", "set print asm-demangle" })
	end

	-- load file
	if path ~= last_binary_path or force then
		last_binary_path = path
		comms({ string.format("file %s", path) })
		vim.notify(string.format("Disassembly completed"), vim.log.levels.INFO)
	end
end

---Renders the disasm text
---@param buf_id integer
---@param lines table
local function draw_disasm_lines(buf_id, lines)
	vim.schedule(function()
		vim.api.nvim_buf_clear_namespace(buf_id, ns_id_asm, 0, -1)

		for line_num, text in pairs(lines) do
			local virt_lines = {}
			for _, line in ipairs(text) do
				local parsed = parse_asm(line)
				table.insert(virt_lines, create_asm_with_highlights(parsed))
			end

			local col_num = 0
			vim.api.nvim_buf_set_extmark(buf_id, ns_id_asm, line_num - 1, col_num, {
				virt_lines = virt_lines,
			})
		end
		vim.notify(string.format("Disasm text is updated"), vim.log.levels.INFO)
	end)
end

local function disassemble_function(opts)
	if not comms then
		return
	end

	-- fetch what's the function address for the given lines
	local info = comms({ string.format("info line %s:%s", opts.file_path, opts.file_line) })[1]
	local func_addr = string.match(info[1], "0x[0-9a-h]+")

	-- disasm function address to asm listing
	local func_disasm_response = comms({ string.format("disassemble %s", func_addr) })[1]

	local commands = {}
	local parsed_asm = {}

	-- extract asm text and prepare source listing commands for each asm address
	for _, str in ipairs(func_disasm_response) do
		local addr, asm = string.match(str, "^%s+(0x[0-9a-h]+)%s+<[^>]+>:([^\n]+)")
		if addr and asm then
			table.insert(commands, string.format("list *%s", addr))
			table.insert(parsed_asm, asm)
		end
	end

	local address_disasm_response = comms(commands)

	local disasm = {}
	local last_line = 1

	last_disasm_lines = {}

	-- for each command response parse source code location
	for addr_idx, command_response in ipairs(address_disasm_response) do
		local raw = command_response[1]
		local asm = parsed_asm[addr_idx]

		local last = #raw - raw:reverse():find(" ") + 1
		local s = raw:sub(last + 2, -4)
		local delim = s:find(":")

		local file = s:sub(1, delim - 1)
		local line = tonumber(s:sub(delim + 1))
		if line and opts.cur_file == file then
			last_line = line
		else
			asm = string.format("%-90s // %s:%s", asm, file, line)
			log.fmt_warn("unmatched file %s against %s", raw, file)
		end

		if not disasm[last_line] then
			disasm[last_line] = {}
		end

		table.insert(last_disasm_lines, { asm, file, last_line })

		if last_line <= opts.line_end + 1 and last_line >= opts.line_start then
			table.insert(disasm[last_line], asm)
		end
	end

	return disasm
end

---Disassembles current function and calls provided callback with a table containing line nums and text
---@param callback function
local function disasm_current_func(callback)
	local file_path = vim.fn.expand("%:p")
	local line_start, line_end = get_current_function_range()
	local func_name = get_current_function_name()

	---@diagnostic disable-next-line: deprecated
	local file_line, _ = unpack(vim.api.nvim_win_get_cursor(0))
	local cur_file = vim.fn.expand("%:p")

	last_disasm_target = {
		file_path = file_path,
		file_line = file_line,
		line_start = line_start,
		line_end = line_end,
		cur_file = cur_file,
		func_name = func_name,
	}

	async.run(function()
		make_sure_gdb_is_up_to_date(false)
		callback(disassemble_function(last_disasm_target))
	end)
end

local function resolve_calls_under_the_cursor()
	local cur_file = vim.fn.expand("%:p")
	---@diagnostic disable-next-line: deprecated
	local cursor_line, _ = unpack(vim.api.nvim_win_get_cursor(0))

	async.run(function()
		make_sure_gdb_is_up_to_date(false)
		if not comms then
			return
		end

		-- fetch what's the function address for the given lines
		local info = comms({ string.format("info line %s:%s", cur_file, cursor_line) })[1]

		local match = string.gmatch(info[1], "0x[0-9a-h]+")
		local addresses = {}
		for i in match do
			table.insert(addresses, i)
		end

		-- disasm function address
		local response = comms({ string.format("disassemble %s,%s", addresses[1], addresses[2]) })[1]
		local names = {}
		local jumps = {}
		for _, str in ipairs(response) do
			local _, asm = string.match(str, "^%s+(0x[0-9a-h]+)%s+<[^>]+>:([^\n]+)")
			if asm and asm:find("call ") then
				local addr, name = string.match(asm, "^[^0]+(0x[0-9a-h]+)%s+([^\n]+)")
				log.fmt_trace("got function call asm %s, parsed address: %s and name %s", str, addr, name)
				if name then
					table.insert(names, name)
					table.insert(jumps, addr)
				end
			end
		end

		if #names == 0 then
			log.fmt_warn("no function names parsed from %s", vim.inspect(response))
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
				}, function(_, idx)
					tx(jumps[idx])
				end)
			end)

			addr = rx()
		end

		info = comms({ string.format("info line *%s", addr) })[1]
		local line, file = string.match(info[1], 'Line%s(%d+)[^"]+["]([^"]+)["]')

		if line ~= nil and file ~= nil then
			log.fmt_info("parsed line %s and file %s from %s", line, file, info[1])

			if string.sub(file, 1, 1) ~= "/" then
				-- resolve the relative path to the binary
				local new_file = vim.fs.dirname(last_binary_path) .. "/" .. file
				log.fmt_info("resolved file %s from %s and %s", new_file, last_binary_path or "null", file or "null")
				file = new_file
			end

			vim.schedule(function()
				vim.cmd(string.format(":edit %s", file))
				vim.cmd(string.format(":%d", line))
			end)
		else
			vim.notify(string.format("Unable to resolve address %s", addr), vim.log.levels.WARN)
		end
	end)
end

M = {}

M.setup = function(_)
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

			local file_path = sessions_path .. input
			local data = { src = vim.api.nvim_buf_get_lines(0, 0, -1, false), disasm = {}, ft = vim.bo.ft }

			vim.fn.mkdir(sessions_path, "p")

			disasm_current_func(function(disasm)
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

	vim.keymap.set("n", "<leader>dal", function()
		vim.fn.mkdir(sessions_path, "p")

		local files = vim.split(vim.fn.glob(sessions_path .. "*"), "\n", { trimempty = true })

		vim.ui.select(files, {
			prompt = "Pick session to load",
			format_item = function(item)
				return item:sub(#sessions_path + 1)
			end,
		}, function(_, idx)
			if not files[idx] then
				return
			end

			local content = vim.fn.readfile(files[idx])
			local data = vim.json.decode(content[1])

			local disasm = {}
			for _, obj in pairs(data.disasm) do
				disasm[obj.line_num] = obj.disasm
			end

			vim.bo.ft = data.ft
			vim.api.nvim_buf_set_lines(0, 0, -1, false, data.src)
			draw_disasm_lines(0, disasm)
		end)
	end, { remap = true, desc = "Load saved session to the current buffer" })

	vim.keymap.set("n", "<leader>dar", function()
		vim.fn.mkdir(sessions_path, "p")

		local files = vim.split(vim.fn.glob(sessions_path .. "*"), "\n", { trimempty = true })

		vim.ui.select(files, {
			prompt = "Pick session to remove",
			format_item = function(item)
				return item:sub(#sessions_path + 1)
			end,
		}, function(_, idx)
			if files[idx] then
				os.remove(files[idx])
			end
		end)
	end, { remap = true, desc = "Remove saved session" })

	vim.keymap.set("n", "<leader>daq", function()
		vim.api.nvim_buf_clear_namespace(0, ns_id_asm, 0, -1)
		if comms then
			local c = comms

			async.run(function()
				c({ string.format("quit") })
			end)

			comms = nil
			last_binary_path = ""
		end
	end, { remap = true, desc = "Clean disassembly and quit GDB" })

	vim.keymap.set("n", "<leader>dad", function()
		vim.api.nvim_buf_set_lines(0, 0, -1, false, last_disasm_lines)
		vim.bo.ft = "asm"
	end, { remap = true, desc = "Set disassembly text to current buffer for debugging" })

	vim.keymap.set("n", "<leader>dac", function()
		resolve_calls_under_the_cursor()
	end, { remap = true, desc = "Jump to a call" })

	vim.keymap.set("n", "<leader>dab", function()
		is_auto_reload_enabled = not is_auto_reload_enabled
		vim.notify(string.format("Auto reload is %s", is_auto_reload_enabled and "ON" or "OFF"), vim.log.levels.INFO)
	end, { remap = true, desc = "Toggle auto reload on build" })

	vim.keymap.set("n", "<leader>dat", function()
		-- remember current buffer and create highlight
		local src_buf = vim.api.nvim_get_current_buf()
		local group_name = "Pmenu"
		local func_name = get_current_function_name()

		vim.api.nvim_set_hl(0, "DisasmWhiteOnGrey", { bg = "#363545", fg = "#ffffff" })
		vim.api.nvim_buf_clear_namespace(src_buf, ns_id_asm, 0, -1)

		disasm_current_func(function()
			vim.schedule(function()
				-- create new window and buffer
				vim.api.nvim_command("vsplit")

				local asm_win = vim.api.nvim_get_current_win()
				local asm_buf = vim.api.nvim_create_buf(true, true)
				vim.api.nvim_buf_set_name(asm_buf, func_name .. "-" .. last_binary_path)
				vim.api.nvim_win_set_buf(asm_win, asm_buf)
				vim.bo.ft = "asm"

				-- transform lines to backward map asm -> src
				local text_lines = {}
				local asm_to_src = {}
				local src_to_asm = {}
				for idx, data in ipairs(last_disasm_lines) do
					---@diagnostic disable-next-line: deprecated
					local asm, file, line = unpack(data)
					table.insert(text_lines, asm)
					asm_to_src[idx] = { file, line }
					if not src_to_asm[line] then
						src_to_asm[line] = {}
					end

					table.insert(src_to_asm[line], idx)
				end

				-- set the text
				vim.api.nvim_buf_set_lines(asm_buf, 0, -1, false, text_lines)

				-- track cursor movement and highlight the src window
				local asm_auto_id = vim.api.nvim_create_autocmd("CursorMoved", {
					group = group_id,
					buffer = asm_buf,
					callback = function(ev)
						if ev.buf ~= asm_buf then
							return
						end

						---@diagnostic disable-next-line: deprecated
						local cursor_line, _ = unpack(vim.api.nvim_win_get_cursor(0))
						---@diagnostic disable-next-line: deprecated
						local _, line = unpack(asm_to_src[cursor_line])

						vim.api.nvim_buf_clear_namespace(src_buf, ns_id_hl, 0, -1)
						vim.api.nvim_buf_set_extmark(
							src_buf,
							ns_id_hl,
							line - 1,
							0,
							{ end_row = line, hl_group = group_name }
						)
					end,
				})

				local src_auto_id = vim.api.nvim_create_autocmd("CursorMoved", {
					group = group_id,
					buffer = src_buf,
					callback = function(ev)
						if ev.buf ~= src_buf then
							return
						end

						---@diagnostic disable-next-line: deprecated
						local cursor_line, _ = unpack(vim.api.nvim_win_get_cursor(0))
						vim.api.nvim_buf_clear_namespace(asm_buf, ns_id_hl, 0, -1)
						for _, line in ipairs(src_to_asm[cursor_line] or {}) do
							vim.api.nvim_buf_set_extmark(
								asm_buf,
								ns_id_hl,
								line - 1,
								0,
								{ end_row = line, hl_group = group_name }
							)
						end
					end,
				})

				local clear_ns = function()
					vim.api.nvim_buf_clear_namespace(src_buf, ns_id_hl, 0, -1)
					vim.api.nvim_buf_clear_namespace(asm_buf, ns_id_hl, 0, -1)
				end

				local asm_auto_id_leave = vim.api.nvim_create_autocmd("BufLeave", {
					buffer = asm_buf,
					group = group_id,
					callback = clear_ns,
				})

				local src_auto_id_leave = vim.api.nvim_create_autocmd("BufLeave", {
					buffer = src_buf,
					group = group_id,
					callback = clear_ns,
				})

				vim.api.nvim_create_autocmd("BufDelete", {
					buffer = asm_buf,
					group = group_id,
					callback = function()
						clear_ns()
						vim.api.nvim_del_autocmd(asm_auto_id)
						vim.api.nvim_del_autocmd(src_auto_id)
						vim.api.nvim_del_autocmd(asm_auto_id_leave)
						vim.api.nvim_del_autocmd(src_auto_id_leave)
						if vim.api.nvim_win_is_valid(asm_win) then
							vim.api.nvim_win_close(asm_win, false)
						end
					end,
				})
			end)
		end)
	end, { remap = true, desc = "Test call" })
end

M.on_build_completed = function()
	if is_auto_reload_enabled then
		local func_name = get_current_function_name()
		async.run(function()
			make_sure_gdb_is_up_to_date(true)

			if last_disasm_target and func_name == last_disasm_target.func_name then
				vim.schedule(function()
					disasm_current_func(function(disasm)
						draw_disasm_lines(0, disasm)
					end)
				end)
			end
		end)
	end
end

return M
