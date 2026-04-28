# MCP-Wiki

Markdown wiki MCP server with TOC extraction, paragraph-level editing, and git history.

## Install with Docker (no Perl required)

```bash
docker run --rm \
    -v "$HOME:$HOME" -e HOME="$HOME" \
    raudssus/mcp-wiki --help
```

## Install with Perl

```bash
cpanm MCP::Wiki
```

## Usage

```perl
use MCP::Wiki::Server;

my $server = MCP::Wiki::Server->new(
    wiki_root => '/path/to/wiki',
    use_git   => 1,
);

$server->on_change(sub ($event) {
    # Handle create/update/delete events
    # Useful for auto-commits, webhooks, etc.
});

$server->to_stdio;
```

## MCP Tools

| Tool | Description |
|------|-------------|
| `list_pages` | List all wiki pages |
| `get_toc` | Get table of contents for a page |
| `get_paragraph` | Get content under a specific heading |
| `create_page` | Create a new wiki page |
| `update_paragraph` | Update paragraph content |
| `rename_page` | Rename/move a page |
| `delete_page` | Delete a page |
| `get_section_history` | Get git history for a section |
| `restore_section` | Restore section from git commit |

## Configuration

- `wiki_root`: Root directory for wiki pages (default: current dir)
- `use_git`: Enable git auto-commit on changes (default: 0)
- `commit_reason_required`: Require reason for commits (default: 0)

## License

Copyright (c) 2026 Torsten Raudssus. Same terms as Perl 5 itself.