-- test_poc.lua — headless end-to-end test for vet.nvim
-- (still points at the on-disk "vet.nvim" dir pending the physical rename)
-- Run with:
--   nvim --headless -u NONE --cmd "set rtp+=<plugin_dir>" -l test_poc.lua <demo_project_dir>

local plugin_dir = vim.fn.getcwd() .. "/vet.nvim"
vim.opt.rtp:append(plugin_dir)

local demo_dir = arg[1] or (vim.fn.getcwd() .. "/demo-project")
local target_file = demo_dir .. "/calc.py"

local vet = require("vet")

local function read(path)
  return table.concat(vim.fn.readfile(path), "\n")
end

local function reset_file()
  os.execute(string.format("cd %q && git checkout -q -- calc.py", demo_dir))
end

local function buffer_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

local function run_case(name, decision_key, expect_contains, expect_not_contains)
  reset_file()
  local before = read(target_file)
  print("=== CASE: " .. name .. " ===")
  print("before:\n" .. before)

  -- Open the file in a real buffer first, matching the actual bug report:
  -- the buffer must reflect the accept/reject outcome without a manual :e!.
  vim.cmd("edit " .. vim.fn.fnameescape(target_file))
  local bufnr = vim.api.nvim_get_current_buf()
  assert(vim.bo[bufnr].modified == false)

  local done = false
  local result = nil

  vet.dispatch("add a multiply function", target_file, function(r)
    result = r
    done = true
  end)

  -- Wait for the agent job to finish and the review window to open.
  vim.wait(5000, function()
    return vim.api.nvim_get_mode().mode ~= nil and #vim.api.nvim_list_wins() > 1
  end, 50)

  -- Find the floating review window (not the base window).
  local review_win = nil
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(w)
    if cfg.relative ~= "" then
      review_win = w
    end
  end
  assert(review_win, "review window did not open for case: " .. name)

  -- Simulate the user pressing the decision key inside the review buffer.
  vim.api.nvim_set_current_win(review_win)
  vim.api.nvim_feedkeys(decision_key, "x", false)

  vim.wait(1000, function() return done end, 20)
  assert(done, "callback not invoked for case: " .. name)

  local after = read(target_file)
  print("after:\n" .. after)
  print("decision recorded: " .. tostring(result.accepted))

  if expect_contains then
    assert(after:find(expect_contains, 1, true), "expected content missing: " .. expect_contains)
  end
  if expect_not_contains then
    assert(not after:find(expect_not_contains, 1, true), "unexpected content present: " .. expect_not_contains)
  end

  -- The key regression check: the already-open buffer must match disk,
  -- without any manual :e!/:checktime from the test.
  local buf_after = buffer_text(bufnr)
  assert(buf_after == after, string.format(
    "buffer did not auto-sync for case %s!\n--- disk ---\n%s\n--- buffer ---\n%s",
    name, after, buf_after
  ))
  assert(vim.bo[bufnr].modified == false, "buffer incorrectly marked modified for case: " .. name)
  print("buffer auto-synced correctly (matches disk, not marked modified)")

  print("CASE PASSED: " .. name)
  print("")
end

run_case("accept", "a", "def multiply", nil)
run_case("reject", "r", nil, "def multiply")

print("ALL CASES PASSED")
vim.cmd("qa!")
