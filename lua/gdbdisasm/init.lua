local Job = require("plenary.job")
local async = require("plenary.async")
local ts_utils = require("nvim-treesitter.ts_utils")
local log = require("gdbdisasm.log")

local ns_id_asm = vim.api.nvim_create_namespace("disnav-asm")
local ns_id_hl = vim.api.nvim_create_namespace("disnav-hl")
local group_id = vim.api.nvim_create_augroup("disnav", { clear = true })

local root_path = vim.fn.stdpath("data") .. "/gdb-disasm"
local sessions_path = root_path .. "/sessions/"

---@class Disasm
---@field asm string
---@field file string
---@field line integer

---@class State
---@field comms? function(table, boolean): string[][]
---@field file_path string
---@field file_line integer
---@field	line_start integer
---@field	line_end integer
---@field	cur_file string
---@field func_name string
---@field	binary_path string
---@field	running boolean
---@field disasm Disasm[]
---@field src_lines string[]
---@field ft string

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

	local function communicate(commands, ignore_response)
		log.trace("writing '" .. table.concat(commands, ",") .. "'")
		local lines = {}
		for _, cmd in ipairs(commands) do
			job:send(cmd .. "\n")
			table.insert(lines, {})
		end

		if ignore_response then
			return lines
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

	-- set some settings
	communicate({ "set disassembly-flavor intel", "set print asm-demangle" })

	return communicate
end

---Converts full disassembly info to a source location map
---@param state State
---@returns table<integer, string[]>
local function make_disasm_map(state)
	local disasm_map = {}

	for _, data in ipairs(state.disasm) do
		if not disasm_map[data.line] then
			disasm_map[data.line] = {}
		end

		if data.line <= state.line_end + 1 and data.line >= state.line_start then
			table.insert(disasm_map[data.line], data.asm)
		end
	end

	return disasm_map
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

---Dissasebmles the function specified in the state and updates the state
---@param state State
local function disassemble_function(state)
	-- fetch what's the function address for the given lines
	local info = state.comms({ string.format("info line %s:%s", state.file_path, state.file_line) })[1]
	if not info[1] then
		vim.notify(string.format("Unable to resolve %s:%s", state.file_path, state.file_line), vim.log.levels.ERROR)
		return
	end

	local func_addr = string.match(info[1], "0x[0-9a-h]+")

	-- disasm function address to asm listing
	local func_disasm_response = state.comms({ string.format("disassemble %s", func_addr) })[1]

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

	local address_disasm_response = state.comms(commands)

	state.disasm = {}

	local last_line = 1

	-- for each command response parse source code location
	for addr_idx, command_response in ipairs(address_disasm_response) do
		local raw = command_response[1]
		local asm = parsed_asm[addr_idx]

		local last = #raw - raw:reverse():find(" ") + 1
		local s = raw:sub(last + 2, -4)
		local delim = s:find(":")

		local file = s:sub(1, delim - 1)
		local line = tonumber(s:sub(delim + 1))
		if line and state.cur_file == file then
			last_line = line
		else
			asm = string.format("%-90s // %s:%s", asm, file, line)
			log.fmt_warn("unmatched file %s against %s", raw, file)
		end

		table.insert(state.disasm, { asm = asm, file = file, line = last_line })
	end

	vim.notify(string.format("%s dissasebmled", state.func_name), vim.log.levels.INFO)
end

---Reloads GDB binary
---@param state State
local function reload_gdb(state)
	-- seems like GDB is smart enough to detect if the binary needs reloading
	-- if this causes performance issues there should be a binary hash check here
	vim.notify(string.format("Loading %s", state.binary_path), vim.log.levels.INFO)
	state.comms({ string.format("file %s", state.binary_path) })
	vim.notify(string.format("Disassembly completed"), vim.log.levels.INFO)
end

local job_sender, job_receiver = async.control.channel.mpsc()
async.run(function()
	---@type State
	local state = {
		comms = nil,
		running = true,
		binary_path = "",
		cur_file = "",
		line_start = 0,
		line_end = 0,
		file_line = 0,
		file_path = "",
		func_name = "",
		disasm = {},
		src_lines = {},
		ft = "",
	}

	while state.running do
		local item = job_receiver.recv()

		-- start lazily
		state.comms = state.comms or start_gdb()

		---@diagnostic disable-next-line: deprecated
		local job, callback = type(item) == "table" and unpack(item) or item, nil

		job(state)

		-- vim.print(vim.inspect(state))

		if callback then
			callback(state)
		end
	end

	vim.notify("Exiting main event loop", vim.log.levels.INFO)
end)

local function get_cmake_target_path()
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
	return path
end

local function disasm_current_func(on_already_done)
	-- update current state
	local file_path = vim.fn.expand("%:p")
	local line_start, line_end = get_current_function_range()
	local func_name = get_current_function_name()

	---@diagnostic disable-next-line: deprecated
	local file_line, _ = unpack(vim.api.nvim_win_get_cursor(0))
	local cur_file = vim.fn.expand("%:p")
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	local ft = vim.bo.ft

	-- schedule job
	job_sender.send(function(state)
		if state.func_name == func_name and #state.disasm then
			-- already disasmed
			if on_already_done ~= nil then
				on_already_done(state)
			end
			return
		end

		state.file_path = file_path
		state.file_line = file_line
		state.line_start = line_start
		state.line_end = line_end
		state.cur_file = cur_file
		state.func_name = func_name
		state.src_lines = lines
		state.ft = ft

		disassemble_function(state)
	end)

	return func_name
end

M = {}

---Sets path to binary
---@param path string
M.set_binary_path = function(path)
	job_sender.send(function(state)
		state.binary_path = path
		reload_gdb(state)
	end)
end

M.stop = function(stop_loop)
	vim.api.nvim_buf_clear_namespace(0, ns_id_asm, 0, -1)

	job_sender.send(function(state)
		state.running = not stop_loop
		state.comms({ "quit" }, true)
		state.comms = nil
		state.func_name = ""
	end)
end

M.toggle_inline_disasm = function()
	local current_buf = vim.api.nvim_get_current_buf()

	disasm_current_func(function(state)
		-- we have already disasmed this, so this is toggle off
		vim.schedule(function()
			vim.api.nvim_buf_clear_namespace(current_buf, ns_id_asm, 0, -1)
		end)

		state.func_name = ""
	end)

	job_sender.send(function(state)
		if state.func_name ~= "" then
			draw_disasm_lines(current_buf, make_disasm_map(state))
		end
	end)
end

---Disassembles current function and renders the results to new window
M.new_window_disasm = function()
	local func_name = disasm_current_func()
	local src_buf = vim.api.nvim_get_current_buf()

	vim.api.nvim_set_hl(0, "DisasmWhiteOnGrey", { bg = "#363545", fg = "#ffffff" })
	vim.api.nvim_buf_clear_namespace(src_buf, ns_id_asm, 0, -1)

	local group_name = "Pmenu"
	job_sender.send(function(state)
		vim.schedule(function()
			-- create new window and buffer
			vim.api.nvim_command("vsplit")

			local asm_win = vim.api.nvim_get_current_win()
			local asm_buf = vim.api.nvim_create_buf(true, true)
			vim.api.nvim_buf_set_name(asm_buf, state.binary_path .. ":" .. func_name .. ":" .. asm_buf)
			vim.api.nvim_win_set_buf(asm_win, asm_buf)
			vim.bo.ft = "asm"

			-- transform lines to backward map asm -> src
			local text_lines = {}
			local asm_to_src = {}
			local src_to_asm = {}
			for idx, data in ipairs(state.disasm) do
				table.insert(text_lines, data.asm)
				asm_to_src[idx] = { data.file, data.line }
				if not src_to_asm[data.line] then
					src_to_asm[data.line] = {}
				end

				table.insert(src_to_asm[data.line], idx)
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

			-- track cursor movement and highlight the asm window
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
end

M.resolve_calls_under_the_cursor = function()
	disasm_current_func()

	---@diagnostic disable-next-line: deprecated
	local file_line, _ = unpack(vim.api.nvim_win_get_cursor(0))

	job_sender.send(function(state)
		-- fetch current line asm and parse it
		local commands = {}
		local map = make_disasm_map(state)
		for _, asm in ipairs(map[file_line]) do
			local match = string.gmatch(asm, "call%s+(0x[0-9a-h]+)")
			for i in match do
				table.insert(commands, string.format("info line *%s", i))
			end
		end

		-- disasm all function calls to info
		local response = state.comms(commands)

		local names = {}
		local jumps = {}
		local start_pattern = "starts at address"
		for _, lines in ipairs(response) do
			local s = lines[1]
			local line, file = string.match(s, 'Line%s(%d+)[^"]+["]([^"]+)["]')
			if line and file then
				local begin = s:find(start_pattern) + #start_pattern + 1
				local name = s:sub(s:find(" ", begin), s:find("and ends at") - 1)
				table.insert(names, string.format("%s at %s:%s", name, file, line))
				table.insert(jumps, { file, line })
			end
		end

		if #names == 0 then
			log.fmt_warn("no function names parsed from %s", vim.inspect(response))
			return
		end

		local tx, rx = async.control.channel.oneshot()
		local location = nil

		if #names == 1 then
			location = jumps[1]
		else
			vim.schedule(function()
				vim.ui.select(names, {
					prompt = "Pick function to jump to",
				}, function(_, idx)
					tx(jumps[idx])
				end)
			end)

			location = rx()
		end

		if not location then
			return
		end

		---@diagnostic disable-next-line: deprecated
		local file, line = unpack(location)

		if line ~= nil and file ~= nil then
			if string.sub(file, 1, 1) ~= "/" then
				-- resolve the relative path to the binary
				local new_file = vim.fs.dirname(state.binary_path) .. "/" .. file
				log.fmt_info("Resolved file %s from %s and %s", new_file, state.binary_path or "null", file or "null")
				file = new_file
			end

			vim.schedule(function()
				vim.cmd(string.format(":edit %s", file))
				vim.cmd(string.format(":%d", line))
			end)
		else
			vim.notify(string.format("Unable to resolve address %s", location), vim.log.levels.WARN)
		end
	end)
end

M.save_current_state = function()
	vim.ui.input({ prompt = "Enter name for the saved session: " }, function(input)
		if not input then
			return
		end

		local file_path = sessions_path .. input

		disasm_current_func()

		job_sender.send(function(state)
			local copy = {}
			for k, v in pairs(state) do
				if k ~= "comms" then
					copy[k] = v
				end
			end

			vim.schedule(function()
				vim.fn.writefile({ vim.json.encode(copy) }, file_path)
				vim.notify(string.format("Saved session to %s", file_path), vim.log.levels.INFO)
			end)
		end)
	end)
end

M.load_saved_state = function()
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

		vim.bo.ft = data.ft
		vim.api.nvim_buf_set_lines(0, 0, -1, false, data.src_lines)

		job_sender.send(function(state)
			for k, v in pairs(data) do
				state[k] = v
			end

			draw_disasm_lines(0, make_disasm_map(state))
		end)
	end)
end

M.setup = function(_)
	vim.keymap.set("n", "<leader>dai", function()
		local path = get_cmake_target_path()
		if path then
			M.set_binary_path(path)
			M.toggle_inline_disasm()
		end
	end, { remap = true, desc = "Toggle disassembly of current function" })

	vim.keymap.set("n", "<leader>das", function()
		local path = get_cmake_target_path()
		if path then
			M.set_binary_path(path)
			M.save_current_state()
		end
	end, { remap = true, desc = "Save current session state to a file" })

	vim.keymap.set(
		"n",
		"<leader>dal",
		M.load_saved_state,
		{ remap = true, desc = "Load saved session to the current buffer" }
	)

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
		M.stop()
	end, { remap = true, desc = "Clean disassembly and quit GDB" })

	vim.keymap.set("n", "<leader>dac", function()
		local path = get_cmake_target_path()
		if path then
			M.set_binary_path(path)
			M.resolve_calls_under_the_cursor()
		end
	end, { remap = true, desc = "Jump to a call" })

	vim.keymap.set("n", "<leader>dab", function()
		is_auto_reload_enabled = not is_auto_reload_enabled
		vim.notify(string.format("Auto reload is %s", is_auto_reload_enabled and "ON" or "OFF"), vim.log.levels.INFO)
	end, { remap = true, desc = "Toggle auto reload on build" })

	vim.keymap.set("n", "<leader>daw", function()
		local path = get_cmake_target_path()
		if path then
			M.set_binary_path(path)
			M.new_window_disasm()
		end
	end, { remap = true, desc = "Disassemble to new window" })
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
