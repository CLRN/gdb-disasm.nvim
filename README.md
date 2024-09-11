# What it is

It's a [neovim](https://github.com/neovim/neovim) plugin for interactively displaying the [assembly](https://en.wikipedia.org/wiki/Assembly_language) for your source code. Some alternatives are

- https://github.com/krady21/compiler-explorer.nvim
- https://github.com/p00f/godbolt.nvim
- https://github.com/mdedonno1337/disassemble.nvim

# Why

The alternatives work with [godbolt](https://godbolt.org/) and have to essentially compile your source code to get the assembly output.
This has many complications in case your code has dependencies or nontrivial build set up.
This plugin works by disassembling the actual binary you have compiled on your environment with your build system.

# Features

- Display assembly inline using virtual text
- Display assembly in a separate window with highlighting
- Navigate to function calls under the cursor

# Demos

## Inline assembly display and toggle

![inline asm](./doc/inline_Trim_1.0.gif.gif)

## ASM in separate window with highlighting

![window asm](./doc/window_Trim_3.gif)

## Auto update on build

![update asm](./doc/update_Trim_1.0.gif)

# Diff

![diff asm](./doc/diff_Trim_1.0.gif)

# Configuration

Example using [cmake-tools](https://github.com/Civitasv/cmake-tools.nvim) and lazy.

```lua
  {
    "CLRN/gdb-disasm.nvim",
    config = function()
      local disasm = require "gdbdisasm"
      disasm.setup {}

      local status, cmake = pcall(require, "cmake-tools")
      if not status then
        return
      end

      local target = cmake.get_build_target()
      if target then
        disasm.set_binary_path(cmake.get_build_target_path(target))
      end

      vim.keymap.set("n", "<leader>dai", disasm.toggle_inline_disasm, { desc = "Toggle disassembly" })
      vim.keymap.set("n", "<leader>das", disasm.save_current_state, { desc = "Save current session state" })
      vim.keymap.set("n", "<leader>dal", disasm.load_saved_state, { desc = "Load saved session" })
      vim.keymap.set("n", "<leader>dar", disasm.remove_saved_state, { desc = "Remove saved session" })
      vim.keymap.set("n", "<leader>dac", disasm.resolve_calls_under_the_cursor, { desc = "Jump to a call" })
      vim.keymap.set("n", "<leader>daw", disasm.new_window_disasm, { desc = "Disassemble to new window" })
      vim.keymap.set("n", "<leader>daq", disasm.stop, { desc = "Clean disassembly and quit GDB" })
    end,
  }
```

You could also add mappings similar to the below to automate target path selection and auto reloading

```lua
    -- builds a cmake target and calls assembly update in the callback
    ["<leader>cb"] = {
      function()
        require("cmake-tools").build({}, function()
          require("gdbdisasm").update_asm_display()
        end)
      end,
      "Build target",
    },

    -- selects cmake target and updates the binary path
    ["<leader>ctb"] = {
      function()
        local cmake = require "cmake-tools"
        cmake.select_build_target(function()
          vim.cmd "redrawstatus"

          local target = cmake.get_build_target()
          if target then
            require("gdbdisasm").set_binary_path(cmake.get_build_target_path(target))
          end
        end)
      end,
      "Select build target",
    },
```
