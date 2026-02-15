local lspconfig = require("lspconfig")
local configs = require("lspconfig.configs")

if not configs.refract then
  configs.refract = {
    default_config = {
      cmd = { "refract" },
      filetypes = { "ruby", "eruby", "haml" },
      root_dir = lspconfig.util.root_pattern("Gemfile", ".git", ".ruby-version"),
      single_file_support = true,
      settings = {},
      init_options = {
        disableGemIndex = false,
        disableRubocop = false,
      },
    },
  }
end

lspconfig.refract.setup({})
