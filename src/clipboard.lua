local function neovim_mac_set_clipboard(lines, regtype)
    return vim.rpcrequest(1, "clipboard_set", lines, regtype) 
end

local function neovim_mac_get_clipboard()
    return vim.rpcrequest(1, "clipboard_get") 
end

local client = vim.api.nvim_get_chan_info(1).client

if (type(client) == "table" and client.name == "Neovim Mac") then
    vim.g.clipboard = {
        name = "Neovim Mac",
        copy = {
            ["+"] = neovim_mac_set_clipboard,
            ["*"] = neovim_mac_set_clipboard
        },
        paste = {
            ["+"] = neovim_mac_get_clipboard,
            ["*"] = neovim_mac_get_clipboard
        }
    }
end
