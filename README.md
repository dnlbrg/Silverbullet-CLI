# SilverBullet CLI

A command-line interface for [SilverBullet](https://silverbullet.md/), the extensible note-taking and personal knowledge management system. Manage your notes, create backups, search content, and visualize page connections directly from your terminal.

## Features

✨ **Full CRUD Operations** - Create, read, update, and delete pages  
🔍 **Smart Search** - Search across all your notes with snippet preview  
💾 **Backup & Restore** - Create and restore backups with optional system page filtering  
📊 **Graph Visualization** - Visualize page connections in text or Graphviz format  
📥 **Import/Export** - Download and upload individual pages  
🌍 **Multilingual** - Built-in English and German support  
⚡ **Fast & Efficient** - Built with Nim for native performance  
🎨 **Beautiful Output** - Color-coded, emoji-enhanced terminal interface

## Installation

### Prerequisites

- [Nim](https://nim-lang.org/) compiler (2.0 or later)
- A running SilverBullet instance

### Build from Source

```bash
git clone https://github.com/dnlbrg/silverbullet-cli.git
cd silverbullet-cli
nim c -d:release -d:ssl --opt:size sbm.nim
```

This creates an optimized binary `sbm` (or `sbm.exe` on Windows).

### Optional: Add to PATH

```bash
# Linux/macOS
sudo cp sbm /usr/local/bin/sb

# Windows
# Move sbm.exe to a directory in your PATH
```

## Quick Start

### 1. Configure Connection

```bash
sb config http://localhost:3000
```

With authentication token:
```bash
sb config https://your-server.com your-auth-token
```

### 2. Set Your Language

```bash
sb lang en    # English
sb lang de    # German
```

### 3. List Your Pages

```bash
sb list
```

### 4. Search Notes

```bash
sb search "TODO"
```

## Usage

### Basic Commands

#### View Help
```bash
sb help
```

#### List All Pages
```bash
sb list              # Without system pages
sb list --all        # Include system pages
```

#### Get Page Content
```bash
sb get "My Notes"
```

#### Create a New Page
```bash
sb create "Meeting Notes" "# Meeting with Team"
echo "# New Note" | sb create "From Pipe"
```

#### Edit Existing Page
```bash
sb edit "My Notes" "Updated content"
cat file.txt | sb edit "My Notes"
```

#### Append to Page
```bash
sb append "Daily Log" "- Completed task X"
```

#### Delete Page
```bash
sb delete "Old Notes"        # With confirmation
sb delete "Old Notes" -f     # Force, no confirmation
```

### Search & Discovery

#### Search Pages
```bash
sb search "keyword"
```

#### Show Recent Pages
```bash
sb recent              # Last 10 pages
sb recent --all        # Include system pages
```

#### Visualize Page Links
```bash
sb graph               # Text format
sb graph dot           # Graphviz DOT format
sb graph dot > graph.dot && dot -Tpng graph.dot -o graph.png
```

### Backup & Restore

#### Create Backup
```bash
sb backup                          # Creates backup-DDMMYYYY-HHMMSS/
sb backup /path/to/backup         # Custom directory
sb backup --full                   # Include system pages
sb backup --verbose                # Show each file
```

#### Restore from Backup
```bash
sb restore backup-24112025-143025
sb restore backup-24112025-143025 --to=Archive    # Import to Archive/*
sb restore /path/to/backup --verbose               # Show progress
```

### Import & Export

#### Download Single Page
```bash
sb download "Important Notes"              # Saves as "Important Notes.md"
sb download "Important Notes" notes.md     # Custom filename
```

#### Upload File as Page
```bash
sb upload document.md "New Page"
sb upload ~/docs/notes.txt "Imported Notes"
```

## Configuration

Configuration is stored in:
- **Linux/macOS**: `~/.config/silverbullet-cli/config.json`
- **Windows**: `%APPDATA%/silverbullet-cli/config.json`

### Config File Format
```json
{
  "serverUrl": "http://localhost:3000",
  "authToken": "your-token-here",
  "language": "en"
}
```

### Alternative Config File
```bash
sb --configfile=/path/to/config.json list
```

## Global Options

| Option | Description |
|--------|-------------|
| `--configfile=<path>` | Use alternative config file |
| `--all`, `-a` | Show system pages (Library/, SETTINGS, etc.) |
| `--full` | Include system pages in backup/restore |
| `--verbose` | Show detailed output during operations |
| `--force`, `-f` | Skip confirmations (e.g., for delete) |
| `--to=<prefix>` | Target prefix for restore operations |

## Examples

### Daily Workflow

```bash
# Morning: Check recent changes
sb recent

# Create today's note
sb create "$(date +%Y-%m-%d)" "# Daily Log\n\n## Tasks"

# Append to daily log
sb append "$(date +%Y-%m-%d)" "- Completed project X"

# Search for open tasks
sb search "TODO"

# Evening: Create backup
sb backup ~/backups/silverbullet
```

### Batch Operations

```bash
# Backup and visualize
sb backup --verbose
sb graph dot | dot -Tpng > connections.png

# Import multiple files
for file in *.md; do
  sb upload "$file" "${file%.md}"
done

# Export all pages (requires backup first)
sb backup export/
```
## Advanced Features

### Graph Visualization with Graphviz (buggy at the moment)

```bash
# Generate DOT file and create visualization
sb graph dot > notes.dot
dot -Tpng notes.dot -o notes.png      # PNG image
dot -Tsvg notes.dot -o notes.svg      # SVG image
dot -Tpdf notes.dot -o notes.pdf      # PDF document

# Interactive visualization
dot -Tx11 notes.dot                    # X11 window
```

### Pipe Operations

```bash
# Chain commands
echo "# Quick Note" | sb create "Quick" && sb get "Quick"

# Process content
sb get "Data" | grep "TODO" | wc -l

# Backup and compress
sb backup backup-temp && tar -czf backup.tar.gz backup-temp/
```

## Troubleshooting

### Connection Issues

```bash
# Test connection
curl http://localhost:3000

# Check config
cat ~/.config/silverbullet-cli/config.json

# Reconfigure
sb config http://localhost:3000
```

### Authentication Errors

If you're getting 401/403 errors:
1. Check your auth token is correct
2. Verify token hasn't expired
3. Reconfigure with new token: `sb config <url> <new-token>`

### Encoding Issues

If you see garbled characters:
- Ensure your terminal supports UTF-8
- On Windows, use `chcp 65001` before running commands

## Development

### Building

```bash
# Debug build
nim c sbm.nim

# Release build (optimized)
nim c -d:release -d:ssl --opt:size sbm.nim

# With additional features
nim c -d:release -d:ssl --opt:size --threads:on sbm.nim
```

### Testing

```bash
# Configure test server
sb config http://localhost:3000

# Run basic tests
sb list
sb create "Test Page" "Test content"
sb get "Test Page"
sb delete "Test Page" -f
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

### Guidelines

1. Follow existing code style
2. Add tests for new features
3. Update documentation
4. Ensure all tests pass

## License

MIT License - see LICENSE file for details

## Acknowledgments

- [SilverBullet](https://silverbullet.md/) - The amazing note-taking system
- [Nim](https://nim-lang.org/) - The programming language

## Links

- **SilverBullet**: https://silverbullet.md/
- **Documentation**: https://silverbullet.md/

---

