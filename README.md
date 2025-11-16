# zotero-md.nvim

A Neovim plugin for inserting Zotero references into markdown files using Telescope.

## Features

- Browse and search your Zotero library with a beautiful columnar UI (inspired by [zotcite](https://github.com/jalvesaq/zotcite))
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
  preview_format = "{title}, {year}, {authors}, {publication}, {abstract}",

  -- Fields to use for searching in Telescope picker
  search_fields = { "title", "year", "authors" },

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
- `:ZoteroInfo` - Show detailed info for the Zotero reference link under cursor
- `:ZoteroDebug` - Debug database connection and show diagnostic information

### Keymaps

- `<C-z>` in insert mode - Opens the picker (only in markdown files)
- `<leader>zi` in normal mode - Shows detailed reference info for link under cursor

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
- `{abstract}` - Abstract/summary of the reference
- `{key}` - Zotero item key (useful for debugging)

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
-- Default: Visual Autoregressive Modeling, 2024, Radford et al., arXiv, [abstract text]
preview_format = "{title}, {year}, {authors}, {publication}, {abstract}"

-- Minimal: Visual Autoregressive Modeling, 2024, Radford et al.
preview_format = "{title}, {year}, {authors}"

-- Academic: Radford et al. (2024). Visual Autoregressive Modeling. arXiv
preview_format = "{authors} ({year}). {title}. {publication}"

-- With custom Extra fields: (GPT2) Visual Autoregressive Modeling, 2024, Radford et al., (OpenAI), arXiv (ICML 2019)
preview_format = "({abbreviation}) {title}, {year}, {authors}, ({organization}), {publication} ({eventshort})"
```

**Note:** Empty parentheses, brackets, and extra commas are automatically cleaned up if placeholders are empty.

### Search Fields

The `search_fields` option controls which fields are searchable in the Telescope picker. By default, you can search by title, year, and authors.

**Available fields**: `title`, `year`, `authors`, `publication`, `type`, `abbreviation`, `organization`, `eventshort`, `abstract`, `key`

```lua
-- Default: search by title, year, and authors
search_fields = { "title", "year", "authors" }

-- Search by title and publication only
search_fields = { "title", "publication" }

-- Search by all metadata fields
search_fields = { "title", "year", "authors", "publication", "type", "organization" }

-- Search by title, abbreviation, and key (useful for debugging)
search_fields = { "title", "abbreviation", "key" }
```

**Tip**: Keep the list short for faster searching. Adding more fields increases search scope but may make it harder to find specific items.

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

## Architecture

The plugin is organized into modular components for easy maintenance and extension:

### Module Structure

```
lua/zotero-md/
├── init.lua        # Main entry point and orchestration
├── config.lua      # Configuration management
├── cache.lua       # In-memory and file-based caching
├── database.lua    # SQLite database queries
├── parser.lua      # Extra field and citation formatting
├── ui.lua          # Telescope picker and floating windows
└── utils.lua       # Shared utility functions
```

### Key Components

- **config.lua**: Manages default and user configuration, provides accessor methods
- **cache.lua**: Handles in-memory caching and JSON file persistence
- **database.lua**: Executes SQLite queries, handles temp database copying, loads references with complex joins
- **parser.lua**: Parses Zotero Extra field (key:value pairs), formats citations with placeholders
- **ui.lua**: Creates Telescope picker with dynamic columns, floating info windows, link detection
- **utils.lua**: Common functions like markdown detection and SQLite result parsing

### Database Query Strategy

The plugin uses an optimized two-query approach (inspired by zotcite):

1. **Authors Query**: Fetches ALL authors at once with priority sorting (author > artist > performer...)
2. **Items Query**: Fetches item metadata with COALESCE fallback chains for publication fields

This avoids N+1 query problems and loads 1000+ references in milliseconds.

### Data Flow

```
User Action → init.lua → load_references()
                            ↓
                        cache.lua (check validity)
                            ↓
                        database.lua (if cache invalid)
                            ↓
                        parser.lua (format citations)
                            ↓
                        ui.lua (show picker/info)
```

## Troubleshooting

### "Database is locked" error

This has been fixed. The plugin creates a temporary copy of the Zotero database in Neovim's cache directory before querying it. This approach (borrowed from [zotcite](https://github.com/jalvesaq/zotcite)) completely avoids lock conflicts and works safely even when Zotero is running.

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

Inspired by [zotcite](https://github.com/jalvesaq/zotcite). The database reading logic, two-query optimization strategy, and UI design are adapted from zotcite's approach to efficiently loading Zotero references.
