# vim-gitlab-mr

A Vim plugin to manage GitLab Merge Requests interactively, powered by the
[glab CLI](https://gitlab.com/gitlab-org/cli).

## Requirements

- [glab CLI](https://gitlab.com/gitlab-org/cli) installed and authenticated (`glab auth login`)
- Vim 8+ or Neovim

## Installation

**vim-plug**
```vim
Plug 'a123/vim-gitlab-mr'
```

**lazy.nvim**
```lua
{ 'a123/vim-gitlab-mr' }
```

## Configuration

```vim
" default target branch for MR creation
let g:gitlab_mr_target_branch = 'main'
```

## Commands

| Command            | Description                                       |
| ------------------ | ------------------------------------------------- |
| `:MRList [args]`   | List merge requests (passes args to `glab mr list`) |
| `:MRCreate`        | Create a new MR from the current branch           |
| `:MRDiffview [id]` | Open MR diff side-by-side in a new tab            |
| `:MRClose [id]`    | Close an MR                                       |
| `:MRMerge [id]`    | Merge an MR                                       |

Omit `[id]` to act on the MR associated with the current branch.

### Keymap

```vim
" <leader>gm opens the MR list
nmap <leader>gm <Plug>(gitlab-mr-list)
```

## MR List Buffer

| Key | Action                          |
| --- | ------------------------------- |
| `<CR>` / `d` | Open diffview for selected MR |
| `c`  | Close MR (with confirmation)    |
| `m`  | Merge MR (with confirmation)    |
| `n`  | Add a note to the MR            |
| `L`  | View MR comments / discussions  |
| `o`  | Open MR in browser              |
| `r`  | Refresh the list                |
| `]`  | Next page                       |
| `[`  | Previous page                   |
| `q`  | Close the list                  |

## Diffview (Tree Pane)

The diffview opens in a new tab with a file-tree on the left and two
side-by-side diff panes on the right (base / source).

| Key | Action                          |
| --- | ------------------------------- |
| `<CR>` | Expand / collapse directory  |
| `?` | Toggle MR metadata overlay       |
| `t` | Toggle tree / flat file view     |
| `J` | Scroll diff panes down           |
| `K` | Scroll diff panes up             |
| `o` | Open file in editor              |
| `n` | Add a note to the MR            |
| `L` | View MR comments / discussions   |
| `m` | Merge MR (with confirmation)     |
| `c` | Close MR (with confirmation)     |
| `r` | Refresh / reload                 |
| `q` | Close the diffview tab           |

## Diffview (Diff Panes)

Both the base (left) and source (right) panes share the same shortcuts:

| Key | Action                        |
| --- | ----------------------------- |
| `n` | Add a note to the MR          |
| `L` | View MR comments / discussions |
| `m` | Merge MR (with confirmation)   |
| `c` | Close MR (with confirmation)   |
| `r` | Refresh / reload               |
| `q` | Close the diffview tab         |

## Comments Buffer

| Key | Action       |
| --- | ------------ |
| `q` | Close window |

Comments are loaded asynchronously. HTML tags in comment bodies are
stripped automatically — block elements become line breaks, `<li>`
items become bullet points, and common entities (`&lt;` `&gt;`
`&amp;` etc.) are decoded.

## Examples

```vim
" list all open MRs
:MRList

" list MRs assigned to me
:MRList --assignee=@me

" create a new MR
:MRCreate

" open diffview for the MR on the current branch
:MRDiffview

" open diffview for a specific MR
:MRDiffview 42

" close the MR on the current branch
:MRClose

" merge a specific MR
:MRMerge 42
```
