describe("chat runtime", function()
  local Runtime

  before_each(function()
    Runtime = require("zxz.chat.runtime")
    Runtime._reset_for_tests()
  end)

  it("owns live chats and active tab state", function()
    local cancelled = false
    local stopped = false
    local submitted_from_input = false
    local submitted
    local chat = {
      persist_id = "chat-1",
      tab_page_id = 10,
      cancel = function()
        cancelled = true
      end,
      stop = function()
        stopped = true
      end,
      submit = function()
        submitted_from_input = true
      end,
      submit_prompt = function(_, prompt, opts)
        submitted = { prompt = prompt, opts = opts }
      end,
    }

    Runtime.register(chat, 10)
    Runtime.set_active(10, chat)

    assert.are.same(chat, Runtime.find("chat-1"))
    assert.are.same(chat, Runtime.active(10))
    assert.are.equal(1, #Runtime.list_for_tab(10))

    Runtime.cancel("chat-1")
    Runtime.stop("chat-1")
    Runtime.submit("chat-1")
    Runtime.submit_prompt("chat-1", "work", { headless = true })

    assert.is_true(cancelled)
    assert.is_true(stopped)
    assert.is_true(submitted_from_input)
    assert.are.equal("work", submitted.prompt)
    assert.is_true(submitted.opts.headless)

    Runtime.detach_tab(10)
    assert.is_nil(Runtime.find("chat-1"))
  end)
end)
