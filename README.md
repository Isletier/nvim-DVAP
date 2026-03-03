## NVIM-DVAP

This is the core DVAP client part for Neovim.

WARNING — this implementation is very WIP and partially vibecoded; DON'T use it unless you want to participate in its development.

## References

- https://github.com/Isletier/DVAP - adapter for GDB (please, read this one)
- https://github.com/Isletier/nvim-DVAP-ui - UI part for this plugin

## Dependencies

- `curl`

## Installation

This is for packer:

```lua
use {
    'Isletier/nvim-DVAP'
}
```

I have no idea how it's done for other package managers, but I'm sure you will figure it out.

## Config

```lua
require("nvim-DVAP").setup({
    on_connected = function() end,
    on_disconnected = function() end,
    on_state_updated = function(state) end 
})
```

For the 'state' structure, refer to the implementation.

## Usage

Besides the configuration callbacks, you can also call these functions:

```lua
function M.get_state() -- same output as on state_updated
function M.connect(PATH, HOST, PORT)
function M.disconnect()
```

