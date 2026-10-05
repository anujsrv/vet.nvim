# vet.nvim


A minimal neovim plugin implementing the **dispatch -> agent edits -> review ->
accept/reject** loop. This is the smallest possible slice of "dispatch to AI coding
harness + review the diff" workflow, built natively in Lua with zero
dependencies beyond neovim itself (`vim.diff`, `jobstart`, floating windows).

## What it does

1. `:VetDispatch <instruction>` snapshots the current file, then runs a
   configured agent CLI against it asynchronously (non-blocking — you can
   keep editing elsewhere while it runs).
2. When the agent process exits, the plugin computes a unified diff between
   the file's before/after content using neovim's built-in `vim.diff`.
3. A floating window opens showing that diff with three keys:
   - `a` — **accept**: keep the agent's edit (already on disk).
   - `r` — **reject**: discard the edit, restoring the original content.
   - `q` — close without deciding (edit stays on disk, pending).


## Running the demo yourself

```sh
cd demo-project
nvim calc.py
:VetDispatch add a multiply function
# wait ~1s for the mock agent, then review the floating diff:
#   a = accept, r = reject, q = close
```

## Wiring a real agent (aider / claude code / codex / etc.)

Replace the default `cmd_template` in your config:

```lua
require("vet").setup({
  cmd_template = function(prompt, filepath)
    -- Example: aider, non-interactive, auto-commit disabled (we handle accept/reject ourselves)
    return { "aider", "--no-auto-commits", "--yes", "--message", prompt, filepath }
  end,
})
```

Any CLI that edits the target file in place and exits works — the plugin
doesn't care what produced the change, only what changed. This keeps it
agent-agnostic, matching the "swap the backend freely" design goal.

### GitHub Copilot CLI

A built-in preset wires up the [GitHub Copilot CLI](https://docs.github.com/copilot/how-tos/use-copilot-agents/use-copilot-cli)
(`copilot -p ...` non-interactive mode):

```lua
require("vet").setup({
  cmd_template = require("vet").agents.copilot(),
})
```

Optional settings:

```lua
require("vet").setup({
  cmd_template = require("vet").agents.copilot({
    bin = "copilot",              -- executable name/path (default: "copilot")
    model = "claude-sonnet-4.5",  -- passed via --model
    reasoning_effort = "high",    -- passed via --reasoning-effort
    extra_args = { "--log-level", "error" },
  }),
})
```

Under the hood this runs `copilot -p "<prompt>" --allow-all-tools
--allow-all-paths --silent`, which is required for Copilot to edit files
without interactive confirmation prompts. The prompt is prefixed with an
instruction scoping the edit to the dispatched file, so vet.nvim's
single-file diff/review model stays accurate.

## Verified behavior (automated test)

`test_poc.lua` drives neovim headlessly and asserts both outcomes:

- **Accept case**: dispatch → mock agent appends `multiply()` → press `a` →
  file retains the new function.
- **Reject case**: dispatch → mock agent appends `multiply()` → press `r` →
  file is restored to its original content (verified absent from the file).

Run it with:

```sh
nvim --headless -u NONE -l test_poc.lua demo-project
```

Both cases pass; the demo project's git working tree is left clean after
each run (reset via `git checkout -- calc.py` at the start of each test
case).

## Known PoC limitations (intentional, for a minimal slice)

- Single-file granularity only (no multi-file agent runs / per-hunk
  accept-reject yet — real agents like aider/claude-code often touch several
  files per instruction).
