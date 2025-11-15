# zotero-md.nvim

A Neovim plugin for inserting Zotero references into markdown files using Telescope.

## Features

- Browse and search your Zotero library directly from Neovim
- Insert formatted citations into markdown files
- Smart caching for fast performance
- Automatic background updates
- Customizable citation format
- Only activates in markdown files

## Requirements

- Neovim >= 0.8.0
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- Zotero with a local SQLite database
- `sqlite3` command-line tool

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "wellsdurant/zotero-md.nvim",
  dependencies = {
    "nvim-telescope/telescope.nvim",
    "nvim-lua/plenary.nvim",
  },
  config = function()
    require("zotero-md").setup({
      -- Optional: customize the path to your Zotero database
      -- zotero_db_path = vim.fn.expand("~/Zotero/zotero.sqlite"),
    })
  end,
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "wellsdurant/zotero-md.nvim",
  requires = {
    "nvim-telescope/telescope.nvim",
    "nvim-lua/plenary.nvim",
  },
  config = function()
    require("zotero-md").setup()
  end,
}
```

## Configuration

Default configuration:

```lua
require("zotero-md").setup({
  -- Path to Zotero SQLite database
  zotero_db_path = vim.fn.expand("~/Zotero/zotero.sqlite"),

  -- Cache file location
  cache_file = vim.fn.expand("~/.local/share/nvim/zotero-md-cache.json"),

  -- Cache expiration time in seconds (1 hour)
  cache_expiration = 3600,

  -- Citation format (supports {title}, {year}, {authors}, {publication}, {type})
  citation_format = "{title} ({year})",

  -- Preload references on startup
  preload = true,

  -- Delay before preloading (milliseconds)
  preload_delay = 1000,

  -- Auto-update when opening markdown files
  auto_update = true,

  -- Minimum interval between auto-updates (seconds)
  auto_update_interval = 300,

  -- Telescope picker options
  telescope_opts = {
    prompt_title = "Zotero References",
    layout_strategy = "horizontal",
    layout_config = {
      width = 0.8,
      height = 0.8,
      preview_width = 0.6,
    },
  },

  -- Keymaps (set to false to disable)
  keymaps = {
    insert_mode = "<C-z>",
  },
})
```

## Usage

### Commands

- `:ZoteroPick` - Open Telescope picker to select and insert a Zotero reference
- `:ZoteroDebug` - Debug database connection and show diagnostic information

### Keymaps

By default, `<C-z>` in insert mode opens the picker (only in markdown files).

### Citation Format

The `citation_format` option controls how references are displayed in the picker and inserted into your document. Available placeholders:

- `{title}` - Reference title
- `{year}` - Publication year
- `{authors}` - Formatted author names
- `{publication}` - Publication/journal name
- `{type}` - Item type (article, book, etc.)

Example formats:

```lua
-- Default: Visual Autoregressive Modeling (2024)
citation_format = "{title} ({year})"

-- With authors: Smith et al. - Visual Autoregressive Modeling (2024)
citation_format = "{authors} - {title} ({year})"

-- Academic style: Smith et al. (2024). Visual Autoregressive Modeling
citation_format = "{authors} ({year}). {title}"
```

All citations are inserted as markdown links to the Zotero item:

```markdown
[Visual Autoregressive Modeling (2024)](zotero://select/library/items/CCVXUEIE)
```

Clicking these links will open the reference in Zotero.

## Finding Your Zotero Database

The default location for the Zotero database varies by platform:

- **Linux**: `~/Zotero/zotero.sqlite`
- **macOS**: `~/Zotero/zotero.sqlite`
- **Windows**: `C:\Users\USERNAME\Zotero\zotero.sqlite`

If you're using a custom Zotero data directory, you can find it in Zotero:
1. Open Zotero
2. Go to Edit → Preferences → Advanced → Files and Folders
3. Look for "Data Directory Location"
4. The database is `zotero.sqlite` in that directory

## How It Works

1. **Initial Load**: On startup (with `preload = true`), the plugin reads your Zotero database and caches references
2. **Caching**: References are cached to `~/.local/share/nvim/zotero-md-cache.json` for fast access
3. **Auto-Update**: When opening markdown files, the cache automatically refreshes (max once per 5 minutes)
4. **Smart Queries**: The plugin queries the Zotero SQLite database in read-only mode (safe to use while Zotero is running)
5. **Markdown-Only**: The picker only activates in markdown files to prevent accidental insertions

## Troubleshooting

### "Database is locked" error

This has been fixed in the latest version. The plugin now uses `-readonly` mode to query the database, which works even when Zotero is running.

### "No Zotero references found"

Run `:ZoteroDebug` to diagnose the issue. This will show:
- Database path and whether it exists
- Total number of items in the database
- Whether references can be loaded successfully
- A sample reference if available

Common causes:
- Incorrect database path (check your Zotero data directory location)
- Empty Zotero library
- Database permissions issue

## License

MIT

## Credits

Inspired by [raindrop-md.nvim](https://github.com/wellsdurant/raindrop-md.nvim) and based on the Zotero database reading logic from [zotcite](https://github.com/wellsdurant/zotcite).
