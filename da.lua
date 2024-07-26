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
  table.insert(res, "|c++filt")

  return "bash", {"-c", table.concat(res, " ")}
end

-- @param data table
-- @param file_name string
-- @return table
local function create_disasm(data, file_name)
  local files = {}
  local last_file = nil
  local last_line = nil

  for _, line in ipairs(data) do
    -- "10:/workarea/disnav/perf.cpp ****     std::string s(test, 'a');"
    local line_num, file = string.match(line, "(%d+):([^%s]+)")
    line_num = tonumber(line_num)
    if line_num and file and file == file_name then
      last_line = line_num
      last_file = file
    elseif last_file and last_line then
      -- "1356 0009 48897D98 		mov	QWORD PTR [rbp-104], rdi"
      local asm = string.match(line, disasm_pattern)
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
-- @param file_name string
local function draw_disasm(data, file_name)
  vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)

  local disasm = create_disasm(data, file_name)
  for line_num, text in pairs(disasm[file_name]) do
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


-- vim.print(string.match(" 1356 0009 48897D98 		mov	QWORD PTR [rbp-104], rdi", "^%s%d+%s[0-9A-H]+%s[0-9A-H]+%s+(.+)$"))
-- vim.print(string.match(" 1868 001c E8000000 		call	calc(int, int)", disasm_pattern))
-- dev@docker:/workarea/disnav$ /opt/bb/bin/g++ -S perf.cpp -fverbose-asm -masm=intel -Os -o - | c++filt
-- dev@docker:/workarea/disnav$ /opt/bb/bin/g++ -isystem /opt/bb/include -D_GLIBCXX_USE_CXX11_ABI=0 -march=westmere -m64 -fno-strict-aliasing -g -O2 -fno-omit-frame-pointer -std=gnu++20 -Werror=all -Wno-deprecated-declarations -Wno-error=deprecated-declarations -fdiagnostics-color=always -c /workarea/disnav/perf.cpp -S -fverbose-asm -masm=intel -Os -o - |c++filt | less
-- getGccDumpOptions(gccDumpOptions, outputFilename: string) {
