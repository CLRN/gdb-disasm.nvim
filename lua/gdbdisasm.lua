local Job = require 'plenary.job'
local async = require "plenary.async"
local ts_utils = require'nvim-treesitter.ts_utils'

local ns_id = vim.api.nvim_create_namespace "disnav"
LAST_DISASM_LINES = {}
COMMS = nil
LAST_PATH = ""

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

local function disasm_current_func()
  local cur_file = vim.fn.expand('%:p')
  local line_start, line_end = get_current_function_range()
  local cursor_line, _ = unpack(vim.api.nvim_win_get_cursor(0))

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

    if not COMMS then
      COMMS = start_gdb()

      -- set some settings
      COMMS("set disassembly-flavor intel")
      COMMS("set print asm-demangle")
    end

    -- load file
    if path ~= LAST_PATH then
      LAST_PATH = path
      COMMS(string.format("file %s", path))
    end

    -- fetch what's the function address for the given lines
    local info = COMMS(string.format("info line %s:%s", cur_file, cursor_line))
    local func_addr = string.match(info[1], "0x[0-9a-h]+")

    -- disasm function address
    local response = COMMS(string.format("disassemble %s", func_addr))

    local disasm = {}
    local last_line = 1

    LAST_DISASM_LINES = {}

    for _, str in ipairs(response) do
      local addr, asm = string.match(str, "^%s+(0x[0-9a-h]+)%s+<[^>]+>:([^\n]+)")
      if addr and asm then
        local t = COMMS(string.format("list *%s", addr))
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

        table.insert(LAST_DISASM_LINES, string.format("%-90s // %s:%s", asm, file, last_line))

        if last_line <= line_end + 1 and last_line >= line_start then
          table.insert(disasm[last_line], asm)
        end
      end
    end

    vim.schedule(function ()
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

  end)
end


M = {}

M.setup = function(cfg)
  vim.keymap.set("n", "<leader>daf", function()
    disasm_current_func()
  end, { remap = true, desc = "Disassemble current function" })

  vim.keymap.set("n", "<leader>daq", function()
    vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)
    if COMMS then
      local c = COMMS

      async.run(function()
        c(string.format("quit"))
      end)

      COMMS = nil
      LAST_PATH = ""
    end
  end, { remap = true, desc = "Clean disassembly and quit GDB" })

  vim.keymap.set("n", "<leader>das", function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, LAST_DISASM_LINES)
  end, { remap = true, desc = "Set disassembly text to current buffer" })
end

return M
