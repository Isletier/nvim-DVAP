local health = {}

health.check = function()
    vim.health.start("nvim-dvap")

    if vim.fn.executable("curl") == 1 then
        local obj = vim.system({ "curl", "--version" }, { text = true }):wait()
        vim.health.ok("curl found:\n" .. obj.stdout)
    else
        vim.health.error("curl not found")
    end
end

return health
