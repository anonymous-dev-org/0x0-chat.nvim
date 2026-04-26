# 0x0-chat.nvim

Neovim chat, inline edit, and review client for the local 0x0 server.

## Install

```lua
{
  "anonymous-dev-org/0x0-chat.nvim",
  opts = {
    server_url = "http://localhost:4096",
  },
}
```

## Commands

- `:ZeroChat`
- `:ZeroChatNew`
- `:ZeroChatOpen <session-id>`
- `:ZeroChatSubmit`
- `:ZeroInlineEdit`
- `:ZeroReview`
- `:ZeroAcceptAll`
- `:ZeroDiscardAll`
- `:ZeroAcceptFile <path>`
- `:ZeroDiscardFile <path>`
- `:ZeroChangesStatus`
- `:ZeroCancel`
- `:ZeroClose`

## Server

Start the 0x0 server before using the plugin:

```sh
0x0 server
```
