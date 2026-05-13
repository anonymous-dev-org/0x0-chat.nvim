local ReferenceMentions = require("zxz.context.reference_mentions")

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

  it("parses first-class AI IDE context mentions", function()
    local mentions = ReferenceMentions.parse(
      "use @fetch:https://example.com/docs and @diff:main plus @rule:project @thread:abc123 @terminal",
      vim.fn.getcwd()
    )
    assert.are.equal(5, #mentions)
    assert.are.equal("fetch", mentions[1].type)
    assert.are.equal("https://example.com/docs", mentions[1].url)
    assert.are.equal("branch_diff", mentions[2].type)
    assert.are.equal("main", mentions[2].base)
    assert.are.equal("rule", mentions[3].type)
    assert.are.equal("project", mentions[3].name)
    assert.are.equal("thread", mentions[4].type)
    assert.are.equal("abc123", mentions[4].id)
    assert.are.equal("terminal", mentions[5].type)
  end)

  it("summarizes explicit context mentions for transcript provenance", function()
    local labels = ReferenceMentions.summary(
      "use @fetch:https://example.com/docs and @diff:main plus @rule:project @thread:abc123 @terminal",
      vim.fn.getcwd()
    )
    assert.are.same({
      "@fetch:https://example.com/docs",
      "@diff:main",
      "@rule:project",
      "@thread:abc123",
      "@terminal",
    }, labels)
  end)

  it("builds structured context records for durable provenance", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    vim.fn.writefile({ "hello" }, root .. "/a.txt")

    local records = ReferenceMentions.records("use @a.txt and @missing.txt and @terminal", root)

    assert.are.equal(3, #records)
    assert.are.equal("file", records[1].type)
    assert.are.equal("@a.txt", records[1].label)
    assert.is_true(records[1].resolved)
    assert.are.equal("unknown", records[2].type)
    assert.are.equal("@missing.txt", records[2].label)
    assert.is_false(records[2].resolved)
    assert.are.equal("unresolved context mention", records[2].error)
    assert.are.equal("terminal", records[3].type)
    assert.is_false(records[3].resolved)

    vim.fn.delete(root, "rf")
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

  it("builds prompt blocks from stored records without re-parsing", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    vim.fn.writefile({ "alpha", "beta", "gamma" }, root .. "/a.txt")

    local records = ReferenceMentions.records("use @a.txt#L1-L2 and @missing.txt", root)
    -- Replace the prompt text entirely; blocks should still come from
    -- the records' embedded mentions, not from re-parsing this string.
    local blocks = ReferenceMentions.to_prompt_blocks_from_records("decoy text", records, root)

    local found_range, found_unknown
    for _, b in ipairs(blocks) do
      if b.type == "text" and b.text and b.text:find("<selected_code>", 1, true) then
        found_range = b.text
      end
      if b.type == "text" and b.text and b.text:find("missing", 1, true) then
        found_unknown = true
      end
    end
    assert.is_truthy(found_range)
    assert.is_truthy(found_range:find("Line 1: alpha", 1, true))
    assert.is_falsy(found_unknown) -- unresolved records produce no provider block

    vim.fn.delete(root, "rf")
  end)
end)
