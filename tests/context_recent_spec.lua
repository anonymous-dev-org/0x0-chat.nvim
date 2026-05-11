local Recent = require("zxz.context.recent")

describe("context.recent ring", function()
  before_each(function()
    Recent.clear()
  end)

  it("returns an empty list when nothing has been pushed", function()
    assert.are.same({}, Recent.list())
  end)

  local function make_named_buf(path)
    local buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].swapfile = false
    vim.api.nvim_buf_set_name(buf, path)
    return buf
  end

  it("deduplicates a repeated path, surfacing the latest position", function()
    local buf = make_named_buf(vim.fn.getcwd() .. "/a.txt")
    Recent.push(buf)
    Recent.push(buf)
    assert.are.equal(1, #Recent.list())
    assert.are.equal("a.txt", Recent.list()[1])
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("respects the count parameter", function()
    local cwd = vim.fn.getcwd()
    for i = 1, 3 do
      local b = make_named_buf(cwd .. "/file" .. i .. ".txt")
      Recent.push(b)
      vim.api.nvim_buf_delete(b, { force = true })
    end
    local two = Recent.list(2)
    assert.are.equal(2, #two)
    assert.are.equal("file3.txt", two[1])
    assert.are.equal("file2.txt", two[2])
  end)
end)
