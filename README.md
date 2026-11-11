# vim-gitlab-mr

A Vim plugin to manage GitLab Merge Requests interactively, powered by the
[glab CLI](https://gitlab.com/gitlab-org/cli).

## Requirements

- [glab CLI](https://gitlab.com/gitlab-org/cli) installed and authenticated
- Vim 8+ or Neovim

## Installation

**vim-plug**
```vim
Plug 'lyuangg/vim-gitlab-mr'
```

**lazy.nvim**
```lua
{ 'lyuangg/vim-gitlab-mr' }
```

## Configuration

```vim
let g:gitlab_mr_target_branch = 'main'

" Optional: auto-open after MR creation
let g:gitlab_mr_create_open_browser = 1   " open MR in browser
let g:gitlab_mr_create_open_diffview = 1  " open diffview
```

## Usage

### Commands

| Command | Description |
|---------|-------------|
| `:MRList [args]` | List MRs (args passed to `glab mr list`) |
| `:MRDiffview [id]` | Open diff view |
| `:MRCreate` | Create MR from current branch |
| `:MRClose [id]` | Close an MR |
| `:MRMerge [id]` | Merge an MR |

Omit `[id]` to act on the MR for the current branch.

### Keymap

No mapping is set by default. Map the plugin yourself, e.g.:

```vim
nmap <leader>gM <Plug>(gitlab-mr-list)
```

### Layout

MR list and diffview share the same tab: opening either from the other embeds
it in-place instead of creating a new tab.

- `:MRList` in a diffview tab → MR list at top (30%), diffview below
- Enter / `d` in MR list → diffview below MR list (30%/70%)
- `:MRList` or `:MRDiffview` from a normal tab → new dedicated tab
- `q` in diffview → close diffview panes, MR list fills tab

## Key Bindings

### MR List

| Key | Action |
|-----|--------|
| Enter / `d` | Open diffview |
| `c` | Close MR |
| `m` | Merge MR |
| `n` | Add note |
| `L` | View comments |
| `o` | Open in browser |
| `r` | Refresh |
| `]` / `[` | Next / prev page |
| `q` | Close |

### Diffview Tree Pane

| Key | Action |
|-----|--------|
| Enter | Expand / collapse dir |
| `?` | Toggle help overlay |
| `t` | Toggle tree / flat view |
| `J` / `K` | Scroll diff panes down / up |
| `o` | Open file in editor |
| `n` | Add note |
| `L` | View comments |
| `m` | Merge MR |
| `c` | Close MR |
| `r` | Refresh |
| `q` | Quit diffview |

### Diff Panes (base / source)

| Key | Action |
|-----|--------|
| `n` `L` `m` `c` `r` `q` | Same as tree pane |

### Comments

| Key | Action |
|-----|--------|
| `q` | Close |

HTML tags in comments are stripped automatically: block elements become line
breaks, `<li>` becomes bullet points (`•`), entities are decoded.

## Examples

```vim
:MRList
:MRList --assignee=@me
:MRDiffview
:MRDiffview 42
:MRCreate
:MRClose
:MRMerge 42
```
