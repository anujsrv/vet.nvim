-- plugin/vet.lua — user command registration, autoloaded by nvim's
-- runtimepath scanning when this plugin directory is on &rtp.
-- NOTE: still requires the "vet.nvim" lua module name on disk pending a

if vim.g.loaded_vet then
  return
end
vim.g.loaded_vet = true

vim.api.nvim_create_user_command("VetDispatch", function(cmd_opts)
  local vet = require("vet")
  vet.dispatch(cmd_opts.args)
end, {
  nargs = "+",
  desc = "Dispatch an instruction to the configured AI agent for the current buffer, then review the diff (vet.nvim)",
})

