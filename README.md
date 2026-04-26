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
- `:ZeroChatSettings`
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

Initialize provider keys once, then start the local background server:

```sh
0x0 init
0x0 server
```

## Chat Settings

Use `:ZeroChatSettings` to choose the chat provider, model, and effort.

Settings apply to new chat sessions. Existing chat sessions keep the provider, model, and effort they were created with.
