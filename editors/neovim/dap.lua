local M = {}

function M.setup()
  local ok, dap = pcall(require, "dap")
  if not ok then return end

  dap.adapters.refract = {
    type = "executable",
    command = "refract",
    args = { "--dap" },
  }

  dap.configurations.ruby = dap.configurations.ruby or {}
  table.insert(dap.configurations.ruby, {
    type = "refract",
    request = "launch",
    name = "Refract: Launch current file",
    program = "${file}",
    cwd = "${workspaceFolder}",
    args = {},
  })
  table.insert(dap.configurations.ruby, {
    type = "refract",
    request = "attach",
    name = "Refract: Attach to PID",
    pid = function()
      return tonumber(vim.fn.input("PID: "))
    end,
  })
end

return M
