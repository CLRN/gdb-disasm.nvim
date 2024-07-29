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

    -- fetch what's the function name for the given lines
    local info = comms(string.format("info line %s:%s", cur_file, line_start + math.floor((line_end - line_start) / 2)))
    local func_name = string.match(info[1], "<([^\\+]+)")

    -- disasm currrent function
    local response = comms(string.format("disassemble %s", func_name))

    local disasm = {}
    local last_line = 1

    for _, str in ipairs(response) do
      local addr, asm = string.match(str, "^%s+(0x[0-9a-h]+)%s+<[^>]+>:%s+([^%s]+%s+0x[0-9a-h]+%s+.+)[\n]$")
      if addr and asm then
        local t = comms(string.format("list *%s", addr))
        local s = t[1]
        local last = #s - s:reverse():find(" ") + 1
        s = s:sub(last + 2, -4)
        local delim = s:find(":")

        local file = s:sub(1, delim - 1)
        local line = tonumber(s:sub(delim + 1))
        if line and cur_file == file then
          last_line = line
        else
          -- vim.print(string.format("unmatched file %s against %s", s, cur_file))
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
          table.insert(virt_lines, { { line, "Comment" } })
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

local s = "line info: 'Line 1094 of \"/workarea/mddx/groups/f_bmesix/pipelinesegments/blps_bmesixmarketdataprocessor.cpp\" is at address 0x6bf777 <BloombergLP::Mddx::blps::BmesixMarketDataProcessor::process(BloombergLP::frl::AggregatedBook const&)+791> but contains no code.\n"
print()

-- TODO: 
-- 1. get current TS node, traverse until function_definition is found
-- 2. get line number for that definition
-- 3. run "gdb cmake-build/RelWithDebInfo/perf -ex "info line /workarea/mddx/internal/perf/perf.cpp:58" -ex quit "
-- 4. parse "Line 58 of "/workarea/mddx/internal/perf/perf.cpp" is at address 0x585380 <bm_book<float>(benchmark::State&)> but contains no code." to get bm_book<float>
-- 5. run "gdb cmake-build/RelWithDebInfo/perf -ex 'set disassembly-flavor intel' -ex 'set print asm-demangle' -ex "disassemble /m '/workarea/mddx/internal/perf/perf.cpp'::bm_book<float>" -ex quit"
-- 6. parse:
-- 99              sum += state.iterations();
--    0x00000000005855df <+607>:   sub    eax,DWORD PTR [rbx]
--    0x00000000005855e1 <+609>:   add    r14d,eax
--
-- 100             std::cout << sum << std::endl;
--    0x00000000005855e4 <+612>:   mov    edi,0x1e4c180
--    0x00000000005855e9 <+617>:   mov    esi,r14d
--    0x00000000005855ec <+620>:   call   0x40e170 <std::basic_ostream<char, std::char_traits<char> >::operator<<(int)@plt>
--    0x00000000005855f1 <+625>:   mov    r12,rax
-- alternatively:
-- 2. get function name 
-- 3. run "gdb cmake-build/RelWithDebInfo/perf -ex 'set print asm-demangle' -ex "info functions bm_book.*" -ex quit"
-- 4. parse:
-- All functions matching regular expression "bm_book.*":
--
-- or:
-- gdb cmake-build/RelWithDebInfo/applications/bmesix/bmesix -ex 'set disassembly-flavor intel' -ex 'set print asm-demangle' -ex "info line /opt/bb/include/fblsr_selectors.h:141" -ex quit
-- gdb cmake-build/RelWithDebInfo/applications/bmesix/bmesix -ex 'set disassembly-flavor intel' -ex 'set print asm-demangle' -ex "disassemble /m 0x667500" -ex quit
--
-- or: 
-- get address from line as above, then load until function end 
-- gdb cmake-build/RelWithDebInfo/applications/bmesix/bmesix -ex 'set disassembly-flavor intel' -ex 'set print asm-demangle' -ex "disassemble /m 0x6bf4f8,+1024" -ex quit
--
-- !!! seems like disasm by function name is not reliable enough, so we will do this from current cursor until function end
-- 1. get line range, save
-- 2. get line info for the current line, parse function name and address
-- 3. disasm next N instructions until reach function line range end
--
--
--
-- these work just fine: disassemble  BloombergLP::Mddx::blps::BmesixMarketDataProcessor::process(BloombergLP::frl::AggregatedBook const&)
-- but when we add /m it stops early, this is what we need to solve
--
-- !! slow but reliable:
-- 1. dump disasm without source code: disassemble  BloombergLP::Mddx::blps::BmesixMarketDataProcessor::process(BloombergLP::frl::AggregatedBook const&)
-- 2. resolve listing per address: list  *0x00000000006bf506 
--
-- File /workarea/mddx/internal/perf/perf.cpp:
-- 59:     void bm_book<float>(benchmark::State&);
-- 59:     void bm_book<int>(benchmark::State&);
-- 5. run picker for them
-- 6. continue from 5. 

-- local j = "1845 0026 7566             jne    .L111"
-- local l = "2142                  .L111:"
-- vim.print(string.match(l, "[^\\.]+[\\.](L%d+):$"))
-- local s = " 3673:/opt/rh/devtoolset-11/root/usr/include/c++/11/bits/basic_string.h ****       : _M_dataplus(_S_construct(__n, __c, __a), __a)"
-- local n = string.find(s, "****", 1, true)
-- vim.print(string.format("n: %s, %s", n, string.sub(s, n)))
-- vim.print(string.match(" 1868 001c E8000000 		call	calc(int, int)", disasm_pattern))
-- dev@docker:/workarea/disnav$ /opt/bb/bin/g++ -S perf.cpp -fverbose-asm -masm=intel -Os -o - | c++filt
-- dev@docker:/workarea/disnav$ /opt/bb/bin/g++ -isystem /opt/bb/include -D_GLIBCXX_USE_CXX11_ABI=0 -march=westmere -m64 -fno-strict-aliasing -g -O2 -fno-omit-frame-pointer -std=gnu++20 -Werror=all -Wno-deprecated-declarations -Wno-error=deprecated-declarations -fdiagnostics-color=always -c /workarea/disnav/perf.cpp -S -fverbose-asm -masm=intel -Os -o - |c++filt | less
-- getGccDumpOptions(gccDumpOptions, outputFilename: string) {
-- dev@docker:/workarea/mddx$ gdb cmake-build/RelWithDebInfo/perf -ex 'set disassembly-flavor intel' -ex 'set print asm-demangle' -ex "disassemble /m '/workarea/mddx/internal/perf/perf.cpp'::bm_book<int>" -ex quit
