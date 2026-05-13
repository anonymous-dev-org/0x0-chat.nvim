describe("inline completion", function()
  local config

  before_each(function()
    config = require("zxz.core.config")
    config.setup({
      complete = {
        cache = { enabled = false },
      },
    })
    package.loaded["zxz.complete"] = nil
    package.loaded["zxz.complete.ghost"] = nil
  end)

  it("sanitizes ghost text before rendering and accepting", function()
    local ghost = require("zxz.complete.ghost")
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local value = " })

    ghost.show(bufnr, 0, 14, "```lua\n42" .. string.char(14) .. "\n```")

    assert.are.equal("42", ghost.get_text())
    assert.is_true(ghost.accept())
    assert.are.equal("local value = 42", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])
  end)

  it("does not request completions for nofile buffers", function()
    local acp_client = require("zxz.core.acp_client")
    local original = acp_client.stream_completion
    local called = false
    acp_client.stream_completion = function()
      called = true
      return function() end
    end

    local complete = require("zxz.complete")
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].buftype = "nofile"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local value = " })

    complete._on_text_changed()

    acp_client.stream_completion = original
    assert.is_false(called)
  end)

  it("uses the resolved provider and drops repeated prefix text", function()
    local acp_client = require("zxz.core.acp_client")
    local original = acp_client.stream_completion
    local captured
    acp_client.stream_completion = function(provider, request, on_chunk, on_done)
      captured = { provider = provider, request = request }
      on_chunk((request.prefix or "") .. "42" .. string.char(14))
      on_done()
      return function() end
    end

    local complete = require("zxz.complete")
    local ghost = require("zxz.complete.ghost")
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].filetype = "lua"
    vim.api.nvim_buf_set_name(bufnr, "/tmp/complete-test.lua")
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local value = " })
    vim.api.nvim_win_set_cursor(0, { 1, 14 })
    complete._mode = function()
      return "i"
    end

    complete._request_completion()

    acp_client.stream_completion = original

    assert.is_truthy(captured)
    assert.are.equal("codex-acp", captured.provider.command)
    assert.are.equal(vim.fn.getcwd(), captured.request.cwd)
    assert.are.equal("42", ghost.get_text())
  end)
end)
