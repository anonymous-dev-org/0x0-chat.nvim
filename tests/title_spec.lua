local function install_fake_acp(calls, config_options)
  package.loaded["zxz.core.acp_client"] = {
    new = function()
      local client = {}

      function client:start(callback)
        calls.start = (calls.start or 0) + 1
        callback(client, nil)
      end

      function client:new_session(_, callback)
        calls.new_session = (calls.new_session or 0) + 1
        callback({ sessionId = "title-session", configOptions = config_options }, nil)
      end

      function client:set_config_option(_, category, value, callback)
        calls.set_config_option = { category = category, value = value }
        callback({ configOptions = config_options }, nil)
      end

      function client:set_model(_, model, callback)
        calls.set_model = model
        callback({ configOptions = config_options }, nil)
      end

      function client:subscribe()
        calls.subscribe = (calls.subscribe or 0) + 1
      end

      function client:prompt(_, _, callback)
        calls.prompt = (calls.prompt or 0) + 1
        callback({}, nil)
      end

      function client:cancel() end
      function client:unsubscribe() end
      function client:stop() end

      return client
    end,
  }
end

describe("title generation", function()
  local saved_acp
  local config

  before_each(function()
    saved_acp = package.loaded["zxz.core.acp_client"]
    package.loaded["zxz.chat.title"] = nil
    config = require("zxz.core.config")
    config.setup({
      provider = "codex-acp",
      title_model = { ["codex-acp"] = "o3" },
      providers = {
        ["codex-acp"] = {
          name = "Codex ACP",
          command = "codex-acp",
        },
      },
    })
  end)

  after_each(function()
    package.loaded["zxz.core.acp_client"] = saved_acp
    package.loaded["zxz.chat.title"] = nil
    config.setup()
  end)

  it("uses provider default when configured title model is not advertised", function()
    local calls = {}
    install_fake_acp(calls, {
      {
        category = "model",
        currentValue = "gpt-5.5",
        options = {
          { value = "gpt-5.5", name = "gpt-5.5" },
          { value = "gpt-5", name = "gpt-5" },
        },
      },
    })

    require("zxz.chat.title").generate("codex-acp", vim.fn.getcwd(), "hello", function() end)

    assert.is_nil(calls.set_model)
    assert.is_nil(calls.set_config_option)
    assert.are.equal(1, calls.prompt)
  end)

  it("sets the configured title model when it is advertised", function()
    local calls = {}
    install_fake_acp(calls, {
      {
        category = "model",
        currentValue = "gpt-5.5",
        options = {
          { value = "gpt-5.5", name = "gpt-5.5" },
          { value = "o3", name = "o3" },
        },
      },
    })

    require("zxz.chat.title").generate("codex-acp", vim.fn.getcwd(), "hello", function() end)

    assert.are.same({ category = "model", value = "o3" }, calls.set_config_option)
    assert.is_nil(calls.set_model)
    assert.are.equal(1, calls.prompt)
  end)

  it("keeps set_model fallback for providers without model options", function()
    local calls = {}
    install_fake_acp(calls, {})

    require("zxz.chat.title").generate("codex-acp", vim.fn.getcwd(), "hello", function() end)

    assert.are.equal("o3", calls.set_model)
    assert.are.equal(1, calls.prompt)
  end)
end)
