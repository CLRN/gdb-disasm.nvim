local Job = require 'plenary.job'
local async = require "plenary.async"

local ns_id = vim.api.nvim_create_namespace "disnav"
local disasm_lines = {}
local disasm_pattern = "^%s+%d+%s+[0-9a-h]+%s+[0-9A-H]+%s+(.+)$"

--- @return table|nil
local function load_commands()
  local status, cmake = pcall(require, "cmake-tools")
  if not status then
    vim.notify("unable to load cmake-tools", vim.log.levels.ERROR)
    return nil
  end

  local path = cmake.get_build_directory() .. "/compile_commands.json"
  local f = io.open(path, "r")
  if not f then
    vim.notify("can't open " .. path, vim.log.levels.ERROR)
    return nil
  end

  local content = f:read "*a"
  f:close()

  return vim.json.decode(content)
end

--- @param data table
--- @param file_name string
--- @return string|nil
local function get_build_command_for_file(data, file_name)
  for _, target in ipairs(data) do
    if target.file == file_name then
      return target.command
    end
  end
end

--- @param command string
--- @return string,table
local function make_disasm_command_and_args(command)
  local t = {}
  local sep = "%s"
  for str in string.gmatch(command, "([^"..sep.."]+)") do
    table.insert(t, str)
  end

  local removed = {}
  for idx, val in ipairs(t) do
    if val == "-o" then
      removed[idx] = true
      removed[idx + 1] = true
    end
  end

  local res = {}
  for idx, val in ipairs(t) do
    if not removed[idx] then
      table.insert(res, val)
    end
  end

  table.insert(res, "-o")
  table.insert(res, "/dev/null")
  table.insert(res, "-Wa,-adhln")
  table.insert(res, "-g")
  table.insert(res, "-masm=intel")
  -- table.insert(res, "-fno-asynchronous-unwind-tables")
  -- table.insert(res, "-fno-dwarf2-cfi-asm")
  -- table.insert(res, "-fno-exceptions")
  table.insert(res, "| c++filt")
  table.insert(res, "| sed 's/\t/    /g'")

  return "bash", {"-c", table.concat(res, " ")}
end

-- @param data table
-- @param file_name string
-- @return table
local function create_disasm(data, file_name)
  local lines = {}
  local labels = {}
  local last_line = nil
  local last_code_hint_line = nil
  local last_code_hint_file = nil

  for _, line in ipairs(data) do
    -- "10:/workarea/disnav/perf.cpp ****     std::string s(test, 'a');"
    local line_num, file = string.match(line, "(%d+):([^%s]+)")
    line_num = tonumber(line_num)
    if line_num then
      last_code_hint_line = line
      last_code_hint_file = file
    end

    if file == file_name then
      last_line = line_num
    end

    local asm = string.match(line, disasm_pattern)
    if not asm then
      local label_define = string.match(line, "[^\\.]+[\\.](L%d+):$")
      if label_define and labels[label_define] then
        asm = label_define .. ":"
        vim.print(string.format("found label define %s", asm))
      end
    end

    if asm and last_line then
      local label_jump = string.match(line, "[^\\.]+[\\.](L%d+)$")
      if label_jump then
        labels[label_jump] = true
        vim.print(string.format("saving label %s", label_jump))
      end

      -- "1356 0009 48897D98 		mov	QWORD PTR [rbp-104], rdi"
      if lines[last_line] == nil then
        lines[last_line] = {}
      end

      if last_code_hint_file ~= file_name and last_code_hint_line then
        asm = string.format("%-90s %s", asm, last_code_hint_line:match("^%s*(.-)%s*$"))
      end

      table.insert(lines[last_line], asm)
    end
  end

  return lines
end


-- @param data table
-- @param file_name string
local function draw_disasm(data, file_name)
  vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)

  local disasm = create_disasm(data, file_name)
  for line_num, text in pairs(disasm) do
    local virt_lines = {}
    for _, line in ipairs(text) do
      table.insert(virt_lines, { { line, "Comment" } })
    end

    local col_num = 0
    vim.api.nvim_buf_set_extmark(0, ns_id, line_num - 1, col_num, {
      virt_lines = virt_lines,
    })
  end
end

vim.keymap.set("n", "<leader>daq", function()
  vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)
end, { remap = true })

vim.keymap.set("n", "<leader>dat", function()
  local lines = {}
  for line in io.lines("out.txt") do
    lines[#lines + 1] = line
  end
  draw_disasm(lines)
end, { remap = true })

vim.keymap.set("n", "<leader>dac", function()
  local data = load_commands()
  if not data then
    return
  end

  local cur_file = vim.fn.expand('%:p')
  local cmd = get_build_command_for_file(data, cur_file)
  if not cmd then
    vim.notify(string.format("failed to get build command for current file"), vim.log.levels.ERROR)
    return
  end

  local binary, args = make_disasm_command_and_args(cmd)

  vim.notify(string.format("running %s %s", binary, table.concat(args, " ")), vim.log.levels.DEBUG)
  local errors = {}

  Job:new({
    command = binary,
    args = args,

    on_stderr = function(err, line)
      table.insert(errors, line)
    end,

    on_exit = function(j, return_val)
      vim.notify(string.format("disasm completed with code %s", return_val), vim.log.levels.DEBUG)
      if return_val == 0 then
        disasm_lines = j:result()
        vim.schedule(function ()
          draw_disasm(j:result(), cur_file)
        end)
      else
        vim.schedule(function ()
          table.insert(errors, string.format("failed to build asm, %s exited with code: %s", binary, return_val))
          vim.fn.setqflist({}, " ", { lines = errors })
          vim.api.nvim_command("copen")
          vim.api.nvim_command("cbottom")
        end)
      end
    end,
  }):start()
end, { remap = true })


vim.keymap.set("n", "<leader>dal", function()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, disasm_lines)
end, { remap = true })

local ts_utils = require'nvim-treesitter.ts_utils'

local function get_current_function_range()
  local current_node = ts_utils.get_node_at_cursor()
  local expr = current_node

  while expr do
    if expr:type() == 'function_definition' then
      break
    end
    expr = expr:parent()
  end

  if not expr then return 0, 0 end
  local range = vim.treesitter.get_range(expr)
  return range[1], range[4]
  --
  -- local node = expr:child(1)
  -- -- local range = vim.treesitter.get_node_range(node)
  --
  -- -- vim.print(start_row, end_row)
  --
  -- vim.print(string.format("function line range: %s - %s", range[1], range[4]))
  -- -- vim.print(string.format("node end: %s", node:end_()))
  -- return (ts_utils.get_node_text()) --[1]
end

-- vim.print(get_current_function_name())

local function start_gdb()
  local setter, getter = async.control.channel.mpsc()
  local job = Job:new({
    command = "gdb",
    args = { "--interpreter", "mi" },

    on_stdout = function(err, line)
      setter.send(line)
    end,

    on_stderr = function(err, line)
      vim.print("error: " .. line)
    end,

    on_exit = function(j, return_val)
      vim.notify(string.format("GDB terminated with %s", return_val), vim.log.levels.ERROR)
    end,
  })
  job:start()

  local function communicate(command)
    vim.print("writing '" .. command .. "'")
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

  return job, communicate
end

vim.keymap.set("n", "<leader>dat", function()
  local cur_file = vim.fn.expand('%:p')
  local line_start, line_end = get_current_function_range()

  async.run(function()

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

    local job, comms = start_gdb()

    -- set some settings
    comms("set disassembly-flavor intel")
    comms("set print asm-demangle")

    -- load file
    comms(string.format("file %s", path))

    -- fetch what's the function address for the given lines
    local info = comms(string.format("info line %s:%s", cur_file, line_start + math.floor((line_end - line_start) / 2)))
    local func_addr = string.match(info[1], "0x[0-9a-h]+")

    -- disasm function address
    local response = comms(string.format("disassemble %s", func_addr))

    local disasm = {}
    local last_line = 1

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
          vim.print(string.format("unmatched file %s against %s", t[1], cur_file))
        end

        if not disasm[last_line] then
          disasm[last_line] = {}
        end

        table.insert(disasm[last_line], asm)
      end
    end

    vim.schedule(function ()
      vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)

      for line_num, text in pairs(disasm) do
        local virt_lines = {}
        for _, line in ipairs(text) do
          -- vim.print(string.format("line num: %s, line text: %s", line_num, line))
          table.insert(virt_lines, { { "    " .. line, "Comment" } })
        end

        local col_num = 0
        vim.api.nvim_buf_set_extmark(0, ns_id, line_num - 1, col_num, {
          virt_lines = virt_lines,
        })
      end
    end)

    job:shutdown()
  end)
end, { remap = true })


-- TODO: 
-- add inline annnotations
-- make it exit cleanly
--
