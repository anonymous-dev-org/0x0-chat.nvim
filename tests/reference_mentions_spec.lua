local ReferenceMentions = require("zeroxzero.reference_mentions")

describe("reference_mentions @diagnostics", function()
  it("parses @diagnostics as a diagnostics mention with no severity filter", function()
    local mentions = ReferenceMentions.parse("please look at @diagnostics for the file", vim.fn.getcwd())
    assert.are.equal(1, #mentions)
    assert.are.equal("diagnostics", mentions[1].type)
    assert.is_nil(mentions[1].severity)
    assert.are.equal("all", mentions[1].severity_label)
  end)

  it("parses @diagnostics:errors with the ERROR severity filter", function()
    local mentions = ReferenceMentions.parse("@diagnostics:errors only", vim.fn.getcwd())
    assert.are.equal(1, #mentions)
    assert.are.equal("diagnostics", mentions[1].type)
    assert.are.equal(vim.diagnostic.severity.ERROR, mentions[1].severity)
    assert.are.equal("errors", mentions[1].severity_label)
  end)

  it("parses @diagnostics:warnings with the WARN severity filter", function()
    local mentions = ReferenceMentions.parse("check @diagnostics:warnings", vim.fn.getcwd())
    assert.are.equal(vim.diagnostic.severity.WARN, mentions[1].severity)
  end)

  it("deduplicates repeated @diagnostics mentions", function()
    local mentions = ReferenceMentions.parse("@diagnostics @diagnostics @diagnostics:errors", vim.fn.getcwd())
    assert.are.equal(2, #mentions) -- "all" + "errors" are distinct, repeats fold
  end)

  it("expands @diagnostics to a fenced markdown block in to_prompt_blocks", function()
    -- vim.diagnostic.get works on the current buffer; we don't seed any diagnostics
    -- so the expansion should still produce a block with "(no diagnostics)".
    local blocks = ReferenceMentions.to_prompt_blocks("look at @diagnostics", vim.fn.getcwd())
    local found
    for _, b in ipairs(blocks) do
      if b.type == "text" and b.text:find("Diagnostics in ", 1, true) then
        found = b.text
        break
      end
    end
    assert.is_truthy(found)
    assert.is_truthy(found:find("```", 1, true))
  end)

  it("parses @hover @def @symbol as lsp mentions", function()
    local mentions = ReferenceMentions.parse("check @hover and @def and @symbol", vim.fn.getcwd())
    assert.are.equal(3, #mentions)
    for _, m in ipairs(mentions) do
      assert.are.equal("lsp", m.type)
    end
  end)

  it("parses @recent and @recent:5", function()
    local mentions = ReferenceMentions.parse("show @recent and @recent:5", vim.fn.getcwd())
    assert.are.equal(2, #mentions)
    assert.are.equal("recent", mentions[1].type)
    assert.is_nil(mentions[1].count)
    assert.are.equal(5, mentions[2].count)
  end)

  it("parses @repomap", function()
    local mentions = ReferenceMentions.parse("@repomap", vim.fn.getcwd())
    assert.are.equal(1, #mentions)
    assert.are.equal("repomap", mentions[1].type)
  end)

  it("does not match @-tokens embedded in emails or mid-word", function()
    -- bob@example.com → no mention.
    -- README.md@v2 → no mention (mid-word @).
    -- @diagnostics at start, after a period+space → recognized.
    local mentions = ReferenceMentions.parse("email bob@example.com about README.md@v2. @diagnostics", vim.fn.getcwd())
    assert.are.equal(1, #mentions)
    assert.are.equal("diagnostics", mentions[1].type)
  end)

  it("matches @-tokens after opening punctuation", function()
    local mentions = ReferenceMentions.parse("see (@diagnostics) and [@hover] and {@def}", vim.fn.getcwd())
    assert.are.equal(3, #mentions)
  end)
end)
