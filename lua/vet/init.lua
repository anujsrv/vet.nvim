-- vet.nvim: dispatch an instruction to an AI coding agent
-- (any CLI: aider, claude code, codex, copilot, etc.) and review what it
-- changed as an in-nvim accept/reject diff, before the change is "trusted".
--
-- Core loop:
--   1. snapshot the target file
--   2. run the agent CLI against it (async)
--   3. diff snapshot vs. new content
--   4. show unified diff in a floating buffer with accept/reject keymaps

local M = {}

M.config = {
  -- cmd_template receives (prompt, filepath) and returns a list of argv.
  -- Default: the bundled mock agent
  cmd_template = function(prompt, filepath)
    local plugin_dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)lua/vet/")
    return { plugin_dir .. "mock_agent.sh", prompt, filepath }
  end,
}

-- in-memory registry of pending reviews, keyed by review id
M._pending = {}
M._next_id = 1

-- Built-in cmd_template presets for specific agent CLIs.
M.agents = {}

--- Build a cmd_template that drives the GitHub Copilot CLI
-- (https://docs.github.com/copilot/how-tos/use-copilot-agents/use-copilot-cli)
-- in non-interactive mode. Copilot edits the target file in place and exits,
-- which is exactly what vet.nvim's snapshot/diff/review loop expects.
--
-- opts (all optional):
--   bin            - copilot executable name/path (default: "copilot")
--   model          - model to pass via --model
--   reasoning_effort - value to pass via --reasoning-effort
--   extra_args     - list of additional argv entries appended to the command
function M.agents.copilot(opts)
  opts = opts or {}
  local bin = opts.bin or "copilot"

  return function(prompt, filepath)
    local full_prompt = string.format(
      "Only edit the file %s. %s",
      filepath,
      prompt
    )

    local cmd = {
      bin,
      "-p", full_prompt,
      "--allow-all-tools",
      "--allow-all-paths",
      "--silent",
    }

    if opts.model then
      vim.list_extend(cmd, { "--model", opts.model })
    end
    if opts.reasoning_effort then
      vim.list_extend(cmd, { "--reasoning-effort", opts.reasoning_effort })
    end
    if opts.extra_args then
      vim.list_extend(cmd, opts.extra_args)
    end

    return cmd
  end
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

--- Capture file contents as a list of lines (works even if buffer isn't loaded).
local function read_file_lines(path)
  if vim.fn.filereadable(path) == 0 then
    return {}
  end
  return vim.fn.readfile(path)
end

--- Write lines to disk.
local function write_file_lines(path, lines)
  vim.fn.writefile(lines, path)
end

--- Force the open buffer (if any) for `path` to match `lines` in-memory,
-- without relying on 'autoread'/:checktime (which may not fire reliably,
-- e.g. while focus is in a floating review window). Also clears 'modified'
-- since the buffer now matches what's on disk.
local function sync_buffer_to_lines(path, lines)
  local bufnr = vim.fn.bufnr(path)
  if bufnr == -1 or not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = false
end

--- Open a floating window showing a unified diff, with accept/reject keymaps.
-- on_decision(accepted: boolean) is called when the user decides.
local function open_review_window(filepath, before_lines, after_lines, on_decision)
  local diff = vim.diff(
    table.concat(before_lines, "\n") .. "\n",
    table.concat(after_lines, "\n") .. "\n",
    { result_type = "unified", ctxlen = 3 }
  ) or "(no textual diff returned)"

  local header = {
    "vet.nvim review: " .. vim.fn.fnamemodify(filepath, ":."),
    "[a] accept   [r] reject   [q] close (keeps change pending)",
    string.rep("-", 60),
  }

  local lines = {}
  vim.list_extend(lines, header)
  for line in (diff .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, line)
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "diff"
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local width = math.min(100, math.floor(vim.o.columns * 0.8))
  local height = math.min(#lines + 1, math.floor(vim.o.lines * 0.8))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " Vet.nvim Review ",
    title_pos = "center",
  })

  local function close_and_decide(accepted)
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    on_decision(accepted)
  end

  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "a", function() close_and_decide(true) end, opts)
  vim.keymap.set("n", "r", function() close_and_decide(false) end, opts)
  vim.keymap.set("n", "q", function() close_and_decide(nil) end, opts)

  return win, buf
end

--- Dispatch a prompt to the configured agent for `filepath` (defaults to current buffer).
-- Returns a review id synchronously; the review itself completes asynchronously.
-- `callback(result)` is invoked with { id, accepted } once the user decides
-- (accepted may be nil if the review window was merely closed/postponed).
function M.dispatch(prompt, filepath, callback)
  filepath = filepath or vim.api.nvim_buf_get_name(0)
  assert(filepath ~= "", "vet.dispatch: no file to target")
  filepath = vim.fn.fnamemodify(filepath, ":p")

  local before_lines = read_file_lines(filepath)
  local cmd = M.config.cmd_template(prompt, filepath)

  local id = M._next_id
  M._next_id = id + 1

  local record = { id = id, filepath = filepath, prompt = prompt, status = "running" }
  M._pending[id] = record

  local stdout_chunks = {}
  record.job = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        vim.list_extend(stdout_chunks, data)
      end
    end,
    on_exit = function(_, exit_code)
      record.exit_code = exit_code
      record.output = table.concat(stdout_chunks, "\n")

      local after_lines = read_file_lines(filepath)
      record.before_lines = before_lines
      record.after_lines = after_lines

      vim.schedule(function()
        if vim.deep_equal(before_lines, after_lines) then
          record.status = "noop"
          vim.notify("vet.nvim: agent made no changes to " .. filepath, vim.log.levels.INFO)
          if callback then callback({ id = id, accepted = nil, noop = true }) end
          return
        end

        open_review_window(filepath, before_lines, after_lines, function(accepted)
          if accepted == true then
            record.status = "accepted"
            -- disk already has the agent's content; make the open buffer match it.
            sync_buffer_to_lines(filepath, after_lines)
          elseif accepted == false then
            record.status = "rejected"
            write_file_lines(filepath, before_lines)
            sync_buffer_to_lines(filepath, before_lines)
          else
            record.status = "pending"
            -- disk currently holds the agent's content; reflect that in the buffer too,
            -- so what you see matches what's on disk until you decide later.
            sync_buffer_to_lines(filepath, after_lines)
          end
          if callback then callback({ id = id, accepted = accepted }) end
        end)
      end)
    end,
  })

  if record.job <= 0 then
    record.status = "failed_to_start"
    error("vet.nvim: failed to start agent job (cmd=" .. vim.inspect(cmd) .. ")")
  end

  return id
end

function M.status(id)
  local r = M._pending[id]
  return r and r.status or nil
end

return M
