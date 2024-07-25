local Job = require 'plenary.job'

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
  -- vim.print(string.format("current file: %s", cur_file))
  for _, target in ipairs(data) do
    -- vim.print(string.format("cmd file: %s", target.file))
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

local data = load_commands()
local cmd = get_build_command_for_current_file(data)
local binary, args = make_disasm_command_and_args(cmd)
vim.print(string.format("running %s with %s", binary, table.concat(args, " ")))
Job:new({
  command = binary,
  args = args,
  on_exit = function(j, return_val)
    if return_val == 0 then
      for _, v in ipairs(j:result()) do
        vim.print(v)
      end
    else
      vim.notify(string.format("failed to build asm, code: %s", return_val), vim.log.levels.ERROR)
    end
  end,
}):sync()

-- vim.json.decode()
