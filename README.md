# zotero-md.nvim

A Neovim plugin for inserting Zotero references into markdown files using Telescope.

## Features

- Browse and search your Zotero library with a beautiful columnar UI (inspired by [zotcite](https://github.com/wellsdurant/zotcite))
- Insert formatted citations into markdown files
- Smart caching for fast performance
- Automatic background updates
- Customizable citation format with support for Extra field parsing
- Dynamic column widths that adapt to your library
- Syntax-highlighted preview pane
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

  -- Telescope preview format (customize how references are shown in preview pane)
  preview_format = "({abbreviation}) {title}, {year}, {authors}, ({organization}), {publication} ({eventshort})",

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
- `{abbreviation}` - From Zotero's Extra field (e.g., `Abbreviation: GPT2 (2019)`)
- `{organization}` - From Zotero's Extra field (e.g., `Organization: OpenAI`)
- `{eventshort}` - From Zotero's Extra field (e.g., `EventShort: ICML 2019`)

Example formats:

```lua
-- Default: Visual Autoregressive Modeling (2024)
citation_format = "{title} ({year})"

-- With authors: Smith et al. - Visual Autoregressive Modeling (2024)
citation_format = "{authors} - {title} ({year})"

-- Academic style: Smith et al. (2024). Visual Autoregressive Modeling
citation_format = "{authors} ({year}). {title}"

-- With abbreviation: GPT2 (2019)
citation_format = "{abbreviation}"

-- With event: ICML 2019 - Visual Autoregressive Modeling
citation_format = "{eventshort} - {title}"
```

**Note:** If the citation format results in an empty string (all placeholders are empty), it will automatically fall back to the default format `"{title} ({year})"`. This ensures you always get a valid citation even when optional fields are missing.

### Preview Format

The `preview_format` option customizes how references are displayed in the Telescope preview pane. It uses the same placeholders as `citation_format`.

**The preview shows ONLY what you specify** - no additional fields are automatically added.

```lua
-- Default: (GPT2) Visual Autoregressive Modeling, 2024, Radford et al., (OpenAI), arXiv (ICML 2019)
preview_format = "({abbreviation}) {title}, {year}, {authors}, ({organization}), {publication} ({eventshort})"

-- Minimal: Visual Autoregressive Modeling, 2024, Radford et al.
preview_format = "{title}, {year}, {authors}"

-- Academic: Radford et al. (2024). Visual Autoregressive Modeling. arXiv
preview_format = "{authors} ({year}). {title}. {publication}"
```

**Tip:** Design your format to avoid empty parentheses. Use `"{abbreviation} {title}"` instead of `"({abbreviation}) {title}"` if the field might be empty.

### Using Zotero Extra Field

The plugin automatically parses custom fields from Zotero's **Extra** field. Add fields in the format `Key: Value` (one per line):

```
Abbreviation: GPT2 (2019)
Organization: OpenAI
EventShort: ICML 2019
```

These fields will be available as placeholders in your citation format and displayed in the Telescope preview.

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
2. **Database Copy**: Creates a temporary copy of the database to avoid lock issues (safe to use while Zotero is running)
3. **Smart Caching**: References are cached to `~/.local/share/nvim/zotero-md-cache.json` for fast access
4. **Auto-Update**: When opening markdown files, the cache automatically refreshes (max once per 5 minutes)
5. **Markdown-Only**: The picker only activates in markdown files to prevent accidental insertions

## Troubleshooting

### "Database is locked" error

This has been fixed. The plugin creates a temporary copy of the Zotero database in Neovim's cache directory before querying it. This approach (borrowed from [zotcite](https://github.com/wellsdurant/zotcite)) completely avoids lock conflicts and works safely even when Zotero is running.

The temporary copy is stored at `~/.local/share/nvim/zotero-md-temp.sqlite` (or your platform's cache directory) and is only updated when the original database changes.

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
