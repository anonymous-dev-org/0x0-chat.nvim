# 0x0.nvim

Neovim companion for the [0x0](https://github.com/anonymous-dev-org/0x0) AI coding assistant.

The TUI is the brain. Neovim is the hands. This plugin bridges the two — send file context to the TUI, review diffs natively in vimdiff, and make inline code edits without leaving your editor.

All commands, agents, and skills are defined in your `config.yaml` and `.zeroxzero/` directory — the plugin fetches them from the server at runtime.

## Requirements

- Neovim >= 0.10
- `curl` in PATH
- [`0x0-server`](https://github.com/anonymous-dev-org/0x0) installed
- `ANTHROPIC_API_KEY` environment variable set (or configured in `~/.config/0x0/config.yaml`)

## Quick Start

1. Install and set your API key:

```bash
npm i -g @anonymous-dev/0x0@latest
export ANTHROPIC_API_KEY="sk-ant-..."
```

2. Add the plugin (lazy.nvim):

```lua
{
  "anonymous-dev-org/0x0.nvim",
  opts = {},
}
```

3. Start the TUI in a terminal, then use `<leader>0s` in Neovim to send the current file to the TUI prompt.

## Installation

### lazy.nvim

```lua
{
  "anonymous-dev-org/0x0.nvim",
  opts = {},
}
```

### packer.nvim

```lua
use {
  "anonymous-dev-org/0x0.nvim",
  config = function()
    require("zeroxzero").setup()
  end,
}
```

## Configuration

```lua
require("zeroxzero").setup({
  cmd = "0x0-server",             -- Server binary (falls back to "0x0 serve")
  port = 4096,                    -- Server port
  hostname = "127.0.0.1",
  auto_start = true,              -- Start server if not running
  keymaps = {
    send = "<leader>0s",          -- Send file (n) or selection (v) to TUI
    send_message = "<leader>0S",  -- Send context + message to TUI
    diff = "<leader>0d",          -- Review diffs from latest session
    interrupt = "<leader>0i",     -- Interrupt current response
    inline_edit = "<leader>0e",   -- Inline edit at cursor/selection
  },
})
```

## Keymaps

| Keymap | Mode | Action |
|--------|------|--------|
| `<leader>0s` | n | Send current file reference to TUI prompt |
| `<leader>0s` | v | Send selection with file reference to TUI prompt |
| `<leader>0S` | n,v | Send context + typed message to TUI prompt |
| `<leader>0d` | n | Review file diffs from latest session in vimdiff |
| `<leader>0i` | n | Interrupt current response |
| `<leader>0e` | n,v | Inline edit |

## Commands

| Command | Description |
|---------|-------------|
| `:ZeroSend` | Send current file to TUI prompt |
| `:ZeroSendMessage` | Send context + message to TUI prompt |
| `:ZeroDiff` | Review diffs in vimdiff |
| `:ZeroInterrupt` | Interrupt current response |
| `:ZeroInlineEdit` | Inline edit at cursor/selection |

## Features

### Send Context to TUI

Select code in Neovim, press `<leader>0s`, and it lands in the TUI's prompt as a file reference with the selected lines. Press `<leader>0S` to also type a message.

### Diff Review

After the TUI's agent makes changes, press `<leader>0d` to fetch the file diffs and open them as native vimdiff splits. If multiple files were changed, you get a picker to choose which file to review.

### Inline Edit

Select code (or place cursor), press `<leader>0e`, type an instruction. The model edits the file directly — no chat, no context switching. The file auto-reloads when done.

### SSE Integration

The plugin maintains an SSE connection to the server for:
- **Permission dialogs** — `vim.ui.select` for allow/reject decisions
- **Question dialogs** — multi-step `vim.ui.select`/`vim.ui.input` sequences
- **File auto-reload** — buffers update when the agent edits files
- **Toast notifications** — `vim.notify` for server messages
- **Statusline** — animated spinner when the agent is working

## Statusline

```lua
-- lualine
sections = {
  lualine_x = {
    { function() return require("zeroxzero").statusline() end },
  },
}
```

## Health Check

```vim
:checkhealth zeroxzero
```

## How It Works

1. **Connect**: Checks if `0x0-server` is running on port 4096. Starts it in the background if needed.
2. **Stream**: Opens SSE connection to `GET /event` for real-time permission/question/file-edit events.
3. **Send**: Sends context to the TUI via `POST /tui/append-prompt`.
4. **Diff**: Fetches diffs via `GET /session/:id/diff` and opens native vimdiff splits.
5. **Inline Edit**: Creates a temporary session, sends the edit via `POST /session/:id/message`, auto-reloads the file.

All requests include an `x-zeroxzero-directory` header so the server routes them to the correct project instance.
