local Job = require 'plenary.job'

local ns_id = vim.api.nvim_create_namespace "disnav"

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
--- @return string|nil
local function get_build_command_for_current_file(data)
  local cur_file = vim.fn.expand('%:p')
  for _, target in ipairs(data) do
    if target.file == cur_file then
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
  local executable = t[1]
  for idx, val in ipairs(t) do
    if not removed[idx] and idx ~= 1 then
      table.insert(res, val)
    end
  end

  table.insert(res, "-Wa,-adhln")
  table.insert(res, "-g")
  table.insert(res, "-masm=intel")
  table.insert(res, "-fno-asynchronous-unwind-tables")
  table.insert(res, "-fno-dwarf2-cfi-asm")

  return executable, res
end

-- @param data table
-- @return table
local function create_disasm(data)
  local files = {}
  local last_file = nil
  local last_line = nil

  for _, line in ipairs(data) do
    -- "10:/workarea/disnav/perf.cpp ****     std::string s(test, 'a');"
    local line_num, file = string.match(line, "(%d+):([^%s]+)")
    line_num = tonumber(line_num)
    if line_num and file then
      last_line = line_num
      last_file = file
    elseif last_file and last_line then
      -- "1356 0009 48897D98 		mov	QWORD PTR [rbp-104], rdi"
      local asm = string.match(line, "%d+%s%w+%s%w+%s+(.+)$")
      if asm then
        if files[last_file] == nil then
          files[last_file] = {}
        end
        if files[last_file][last_line] == nil then
          files[last_file][last_line] = {}
        end

        table.insert(files[last_file][last_line], asm)
      end
    end
  end

  return files
end


-- @param data table
local function draw_disasm(data)
  vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)

  local disasm = create_disasm(data)
  local cur_file = vim.fn.expand('%:p')
  for line_num, text in pairs(disasm[cur_file]) do
    local virt_lines = {}
    for _, line in ipairs(text) do
      table.insert(virt_lines, { { "    " .. line, "Comment" } })
    end

    local col_num = 0
    local mark_id = vim.api.nvim_buf_set_extmark(0, ns_id, line_num - 1, col_num, {
      virt_lines = virt_lines,
    })
  end
end

vim.keymap.set("n", "<leader>dq", function()
  vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)
end, { remap = true })

vim.keymap.set("n", "<leader>dd", function()
  local lines = {}
  for line in io.lines("out.txt") do
    lines[#lines + 1] = line
  end
  draw_disasm(lines)
end, { remap = true })

vim.keymap.set("n", "<leader>dc", function()
  local data = load_commands()
  if not data then
    return
  end

  local cmd = get_build_command_for_current_file(data)
  if not cmd then
    vim.notify(string.format("failed to get build command for current file"), vim.log.levels.ERROR)
    return
  end

  local binary, args = make_disasm_command_and_args(cmd)

  vim.notify(string.format("running %s %s", binary, table.concat(args, " ")))

  Job:new({
    command = binary,
    args = args,
    on_exit = function(j, return_val)
      if return_val == 0 then
        vim.schedule(function ()
          draw_disasm(j:result())
        end)
      else
        vim.notify(string.format("failed to build asm, code: %s", return_val), vim.log.levels.ERROR)
      end
    end,
  }):start()
end, { remap = true })
