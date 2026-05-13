local helpers = require("tests.helpers")

describe("history_store", function()
  local tmp

  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    vim.env.XDG_STATE_HOME = tmp
  end)

  after_each(function()
    helpers.cleanup(tmp)
    vim.env.XDG_STATE_HOME = nil
  end)

  it("persists structured context records with user messages", function()
    local HistoryStore = require("zxz.core.history_store")
    local entry = {
      id = "context-records",
      title = "context records",
      created_at = os.time(),
      messages = {
        {
          type = "user",
          id = "1",
          text = "inspect @a.txt",
          context_records = {
            {
              raw = "@a.txt",
              type = "file",
              label = "@a.txt",
              source = "a.txt",
              resolved = true,
            },
          },
        },
      },
    }

    HistoryStore.save(entry)
    local loaded = HistoryStore.load("context-records")

    assert.is_truthy(loaded)
    assert.are.equal("@a.txt", loaded.messages[1].context_records[1].raw)
    assert.are.equal("file", loaded.messages[1].context_records[1].type)
    assert.is_true(loaded.messages[1].context_records[1].resolved)
  end)
end)
