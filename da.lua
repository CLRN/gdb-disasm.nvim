local Job = require 'plenary.job'

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

  table.insert(res, "-Wa,-adhln")
  table.insert(res, "-g")
  table.insert(res, "-masm=intel")
  table.insert(res, "-fno-asynchronous-unwind-tables")
  table.insert(res, "-fno-dwarf2-cfi-asm")
  table.insert(res, "-fno-exceptions")
  table.insert(res, "| c++filt")
  table.insert(res, "| sed 's/\t/    /g'")

  return "bash", {"-c", table.concat(res, " ")}
end

-- @param data table
-- @param file_name string
-- @return table
local function create_disasm(data, file_name)
  local lines = {}
  local last_line = nil
  local last_code_hint_line = nil
  local last_code_hint_file = nil
  local last_reported_hint = nil

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
    if asm and last_line then
      -- "1356 0009 48897D98 		mov	QWORD PTR [rbp-104], rdi"
      if lines[last_line] == nil then
        lines[last_line] = {}
      end

      if last_code_hint_file ~= file_name and last_code_hint_line and last_code_hint_line ~= last_reported_hint then
        local n = string.find(last_code_hint_line, "****", 1, true) or 1
        local hint = string.sub(last_code_hint_line, n + 5):match("^%s*(.-)%s*$")
        if #hint > 1 then
          asm = string.format("%-90s %s", asm, last_code_hint_line:match("^%s*(.-)%s*$"))
        end
        -- last_reported_hint = last_code_hint_line
      end

      vim.print(asm)
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


-- local s = " 3673:/opt/rh/devtoolset-11/root/usr/include/c++/11/bits/basic_string.h ****       : _M_dataplus(_S_construct(__n, __c, __a), __a)"
-- local n = string.find(s, "****", 1, true)
-- vim.print(string.format("n: %s, %s", n, string.sub(s, n)))
-- vim.print(string.match(" 1868 001c E8000000 		call	calc(int, int)", disasm_pattern))
-- dev@docker:/workarea/disnav$ /opt/bb/bin/g++ -S perf.cpp -fverbose-asm -masm=intel -Os -o - | c++filt
-- dev@docker:/workarea/disnav$ /opt/bb/bin/g++ -isystem /opt/bb/include -D_GLIBCXX_USE_CXX11_ABI=0 -march=westmere -m64 -fno-strict-aliasing -g -O2 -fno-omit-frame-pointer -std=gnu++20 -Werror=all -Wno-deprecated-declarations -Wno-error=deprecated-declarations -fdiagnostics-color=always -c /workarea/disnav/perf.cpp -S -fverbose-asm -masm=intel -Os -o - |c++filt | less
-- getGccDumpOptions(gccDumpOptions, outputFilename: string) {
