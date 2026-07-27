"
" gitlab_mr.vim — interactive GitLab merge request management via glab CLI
"

let s:pending = {}

function! gitlab_mr#check_glab() abort
  if !executable('glab')
    echohl ErrorMsg
    echom '[gitlab-mr] glab CLI not found. Install: https://gitlab.com/gitlab-org/cli'
    echohl None
    return v:false
  endif
  return v:true
endfunction

" --------------- utilities ---------------

function! s:current_branch() abort
  let l:b = substitute(system('git branch --show-current 2>/dev/null'), '\n', '', '')
  return l:b
endfunction

function! s:echo_progress(msg) abort
  let l:text = '[gitlab-mr] ' . a:msg . ' …'
  echon "\r" . l:text
  silent echom l:text
endfunction

function! s:resolve_mr_id(id) abort
  if !empty(a:id) | return a:id | endif
  let l:branch = s:current_branch()
  if empty(l:branch) | return '' | endif
  let l:out = systemlist('glab mr list --source-branch ' . shellescape(l:branch) . ' --output json 2>/dev/null')
  if v:shell_error == 0 && !empty(l:out)
    let l:mrs = json_decode(join(l:out, ''))
    if type(l:mrs) == v:t_list && len(l:mrs) > 0
      return string(l:mrs[0].iid)
    endif
  endif
  return ''
endfunction

function! s:truncate(str, max) abort
  if len(a:str) <= a:max | return a:str | endif
  return a:str[:(a:max - 3)] . '..'
endfunction

function! s:extract_project_id(web_url) abort
  let l:m = matchlist(a:web_url, '://[^/]\+/\(.\+\)/-/merge_requests/')
  if len(l:m) > 1
    return substitute(l:m[1], '/', '%2F', 'g')
  endif
  return ''
endfunction

function! s:scratch_buffer() abort
  setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
  setlocal nowrap nonumber norelativenumber signcolumn=no
endfunction

" --------------- async job system ---------------

let s:dispatch_queue = []

function! s:job_ch_id(ch) abort
  return ch_info(a:ch).id
endfunction

function! s:job_on_out(ch, msg) abort
  let l:id = s:job_ch_id(a:ch)
  if has_key(s:pending, l:id)
    call add(s:pending[l:id].output, a:msg)
  endif
endfunction

function! s:job_on_err(ch, msg) abort
  " silently ignore stderr
endfunction

function! s:job_on_exit(ch, status) abort
  let l:id = s:job_ch_id(a:ch)
  if !has_key(s:pending, l:id) | return | endif
  let l:info = s:pending[l:id]
  " Don't remove from pending yet — out_cb may fire after exit_cb
  call add(s:dispatch_queue, [l:info.handler, a:status, l:info.output, l:info.buf, l:id])
  if len(s:dispatch_queue) == 1
    call timer_start(0, function('s:job_dispatch'))
  endif
endfunction

function! s:job_dispatch(timer) abort
  while !empty(s:dispatch_queue)
    let l:item = remove(s:dispatch_queue, 0)
    call l:item[0](l:item[1], l:item[2], l:item[3])
    " Now safe to clean up pending entry
    if has_key(s:pending, l:item[4])
      call remove(s:pending, l:item[4])
    endif
  endwhile
endfunction

function! s:job_start(cmd, handler) abort
  let l:opts = {
        \ 'out_mode': 'nl',
        \ 'err_mode': 'raw',
        \ 'out_cb': function('s:job_on_out'),
        \ 'err_cb': function('s:job_on_err'),
        \ 'exit_cb': function('s:job_on_exit'),
        \ }
  let l:job = job_start(['/bin/sh', '-c', a:cmd], l:opts)
  if job_status(l:job) ==# 'fail'
    call a:handler(-1, [], bufnr('%'))
    return -1
  endif
  let l:ch = job_getchannel(l:job)
  let l:ch_id = ch_info(l:ch).id
  let s:pending[l:ch_id] = {
        \ 'handler': a:handler,
        \ 'output': [],
        \ 'buf': bufnr('%'),
        \ 'ch': l:ch,
        \ }
  return 0
endfunction

function! s:job_kill_buf(buf) abort
  " Iterate over a snapshot of keys — removing entries while iterating
  " items() can cause Vim to skip entries, leaving stale callbacks that
  " later overwrite content of the *next* file being loaded.
  for l:id in keys(s:pending)
    let l:info = s:pending[l:id]
    if l:info.buf == a:buf
      try
        call job_stop(ch_getjob(l:info.ch))
      catch
        " job already exited, channel is invalid — nothing to stop
      endtry
      call remove(s:pending, l:id)
    endif
  endfor
  " Also clean up any already-completed entries for this buffer in the dispatch queue
  call filter(s:dispatch_queue, {_, v -> v[3] != a:buf})
endfunction

" --------------- MR LIST (data + ui) ---------------

function! gitlab_mr#list(...) abort
  if !gitlab_mr#check_glab() | return | endif

  let l:args = a:0 > 0 && !empty(a:1) ? a:1 : ''
  let l:page = get(s:, 'mr_page', 1)

  let l:mr_win = bufwinnr('__gitlab_mr_list__')
  if l:mr_win != -1
    " MR list window already visible — go to it and refresh
    execute l:mr_win . 'wincmd w'
    call s:mr_fetch(l:page, l:args)
    return
  endif

  if s:dv_panes_valid()
    " In a diffview tab without MR list — embed at top
    call s:mr_embed_at_top()
    call s:mr_fetch(l:page, l:args)
    return
  endif

  " Find or create MR list tab
  let l:tab = s:mr_find_tab()
  if l:tab > 0
    execute 'tabnext' l:tab
  endif

  " Ensure MR list buffer exists (tab may exist but buffer was wiped)
  if bufwinnr('__gitlab_mr_list__') == -1
    if l:tab == 0
      tabnew
    endif
    execute 'silent! bdelete! __gitlab_mr_list__'
    silent! file __gitlab_mr_list__
    call s:scratch_buffer()
    let t:is_mr_list_tab = 1
  endif

  call s:mr_fetch(l:page, l:args)
endfunction

function! s:mr_embed_at_top() abort
  execute 'silent! bdelete! __gitlab_mr_list__'
  topleft new
  silent! file __gitlab_mr_list__
  call s:scratch_buffer()
  execute 'resize ' . (&lines * 30 / 100)
  let t:is_mr_list_tab = 1
endfunction

function! s:find_tab_by_var(varname) abort
  for l:t in range(1, tabpagenr('$'))
    if !empty(gettabvar(l:t, a:varname, 0))
      return l:t
    endif
  endfor
  return 0
endfunction

function! s:mr_find_tab() abort
  return s:find_tab_by_var('is_mr_list_tab')
endfunction

function! s:mr_fetch(page, flags) abort
  " UI: show loading state
  setlocal modifiable
  silent! %d _
  call setline(1, '▌Loading…')
  setlocal nomodifiable
  let &l:statusline = 'GitLab MRs'
  redraw!

  " Data: start async fetch
  call s:mr_fetch_data(a:page, a:flags)
  return v:true
endfunction

function! s:mr_fetch_data(page, flags) abort
  call s:echo_progress('Loading MRs (page ' . a:page . ')')
  call s:job_kill_buf(bufnr('%'))
  let l:cmd = 'glab mr list ' . a:flags . ' --page ' . a:page . ' --per-page 20 --output json 2>/dev/null'
  call s:job_start(l:cmd, function('s:mr_on_fetch', [a:page, a:flags]))
endfunction

function! s:mr_on_fetch(page, flags, status, output, buf) abort
  if a:status != 0
    if bufexists(a:buf)
      call setbufvar(a:buf, '&modifiable', 1)
      call deletebufline(a:buf, 1, '$')
      call setbufline(a:buf, 1, 'Failed to fetch MR list')
      call setbufvar(a:buf, '&modifiable', 0)
    endif
    echohl ErrorMsg | echom '[gitlab-mr] Failed to fetch MR list' | echohl None
    return
  endif

  let l:mrs = []
  try
    let l:mrs = json_decode(join(a:output, ''))
  catch
  endtry

  if type(l:mrs) != v:t_list || empty(l:mrs)
    if bufexists(a:buf)
      call setbufvar(a:buf, '&modifiable', 1)
      call deletebufline(a:buf, 1, '$')
      call setbufline(a:buf, 1, '▌No merge requests found.')
      call setbufvar(a:buf, '&modifiable', 0)
    endif
    echom '[gitlab-mr] No merge requests found.'
    return
  endif

  if !bufexists(a:buf) | return | endif
  let l:winnr = bufwinnr(a:buf)
  if l:winnr == -1 | return | endif
  let l:win_id = win_getid(l:winnr)
  call setbufvar(a:buf, 'mr_list_data', l:mrs)
  call setbufvar(a:buf, 'mr_list_page', a:page)
  call setbufvar(a:buf, 'mr_list_flags', a:flags)
  call win_execute(l:win_id, 'call s:mr_render_from_job()')
endfunction

function! s:mr_render_from_job() abort
  call s:mr_render(b:mr_list_data, b:mr_list_page, b:mr_list_flags)
  redraw!
endfunction

function! s:mr_render(mrs, page, args) abort
  let l:lines = []
  let l:iids = []
  for l:mr in a:mrs
    let l:icon = l:mr.state ==# 'opened' ? '●' : l:mr.state ==# 'merged' ? '✓' : '✗'
    if get(l:mr, 'draft', v:false) | let l:icon = 'D' . l:icon | endif
    let l:created = s:format_timestamp(l:mr.created_at)
    let l:text = printf('!%-5d  %-19s  %-12s  %-8s  %-24s → %-24s  %s',
          \ l:mr.iid,
          \ l:created,
          \ get(l:mr.author, 'username', '?'),
          \ l:icon . ' ' . l:mr.state,
          \ s:truncate(l:mr.source_branch, 24),
          \ s:truncate(l:mr.target_branch, 24),
          \ l:mr.title)
    call add(l:lines, l:text)
    call add(l:iids, l:mr.iid)
  endfor

  let l:sep = repeat('━', winwidth(0))
  let l:header = printf('!%-5s  %-19s  %-12s  %-8s  %-24s → %-24s  %s',
        \ 'ID', 'Date', 'Author', 'State', 'Source', 'Target', 'Title')

  setlocal modifiable
  silent! %d _
  call setline(1, '▌Merge Requests (page ' . a:page . ', ' . len(l:lines) . ' results)')
  call setline(2, '')
  call setline(3, l:header)
  call setline(4, l:sep)
  call append(4, l:lines)
  call append(4 + len(l:lines), '')
  call append(5 + len(l:lines), '  d diffview  c close  m merge  n note  L comments  o browser  r refresh  ] next  [ prev  q quit')
  setlocal nomodifiable
  if !empty(l:lines) | call cursor(5, 1) | endif

  " syntax highlighting
  syntax match GitlabMrListSep    '^━\+$'
  syntax match GitlabMrListHeader '^▌.*'
  syntax match GitlabMrListHelp   '^  [a-zA-Z/<[]\+ .*q quit$'
  syntax match GitlabMrListColHdr '^!ID\s.*Title$'
  highlight default GitlabMrListSep    ctermfg=gray    guifg=#5c6370
  highlight default GitlabMrListHeader cterm=bold      ctermfg=white  guifg=#e5c07b
  highlight default GitlabMrListHelp   ctermfg=gray    guifg=#5c6370
  highlight default GitlabMrListColHdr ctermfg=gray  guifg=#abb2bf

  " per-row syntax
  syntax match GitlabMrListStateOpened '● opened'  containedin=ALL
  syntax match GitlabMrListStateMerged '✓ merged'  containedin=ALL
  syntax match GitlabMrListStateClosed '✗ closed'  containedin=ALL
  syntax match GitlabMrListDraft    'D[●✓✗]'       containedin=ALL
  highlight default GitlabMrListStateOpened ctermfg=green  guifg=#98c379
  highlight default GitlabMrListStateMerged ctermfg=blue   guifg=#61afef
  highlight default GitlabMrListStateClosed ctermfg=red    guifg=#e06c75
  highlight default GitlabMrListDraft       ctermfg=darkyellow guifg=#d19a66

  let b:mr_list_iids  = l:iids
  let b:mr_list_flags = a:args
  let s:mr_page       = a:page

  call s:mr_setup_keys()
endfunction

function! s:mr_setup_keys() abort
  nnoremap <buffer> <silent> <CR> :call <SID>mr_action('diffview')<CR>
  nnoremap <buffer> <silent> d  :call <SID>mr_action('diffview')<CR>
  nnoremap <buffer> <silent> c  :call <SID>mr_action('close')<CR>
  nnoremap <buffer> <silent> n  :call <SID>note_cur()<CR>
  nnoremap <buffer> <silent> L  :call <SID>comments_cur()<CR>
  nnoremap <buffer> <silent> m  :call <SID>mr_action('merge')<CR>
  nnoremap <buffer> <silent> o  :call <SID>mr_browser()<CR>
  nnoremap <buffer> <silent> r  :call <SID>mr_refresh()<CR>
  nnoremap <buffer> <silent> ]  :call <SID>mr_page(1)<CR>
  nnoremap <buffer> <silent> [  :call <SID>mr_page(-1)<CR>
  nnoremap <buffer> <silent> q  :close<CR>
endfunction

function! s:mr_current_iid() abort
  let l:ln = line('.') - 5
  if !exists('b:mr_list_iids') || l:ln < 0 || l:ln >= len(b:mr_list_iids) | return '' | endif
  return string(b:mr_list_iids[l:ln])
endfunction

function! s:mr_action(what) abort
  let l:iid = s:mr_current_iid()
  if empty(l:iid) | return | endif
  if a:what ==# 'diffview'
    call gitlab_mr#diffview(l:iid)
  elseif a:what ==# 'close'
    call gitlab_mr#close(l:iid)
  elseif a:what ==# 'merge'
    call gitlab_mr#merge(l:iid)
  endif
endfunction

function! s:mr_browser() abort
  let l:iid = str2nr(s:mr_current_iid())
  for l:mr in b:mr_list_data
    if l:mr.iid == l:iid
      call system('open ' . shellescape(l:mr.web_url) . ' &')
      return
    endif
  endfor
endfunction

function! s:mr_page(delta) abort
  let s:mr_page = get(s:, 'mr_page', 1) + a:delta
  if s:mr_page < 1 | let s:mr_page = 1 | return | endif
  call s:mr_refresh()
endfunction

function! s:mr_refresh() abort
  let l:page = get(s:, 'mr_page', 1)
  call s:mr_fetch(l:page, b:mr_list_flags)
endfunction

function! s:comments_cur() abort
  let l:iid = exists('t:dv_mr_id') ? t:dv_mr_id : s:mr_current_iid()
  if empty(l:iid) | return | endif
  call gitlab_mr#comments(l:iid)
endfunction

function! s:note_cur() abort
  let l:iid = exists('t:dv_mr_id') ? t:dv_mr_id : s:mr_current_iid()
  if empty(l:iid) | return | endif
  call s:post_note(l:iid)
endfunction

" --------------- MR CREATE ---------------

function! gitlab_mr#create(...) abort
  if !gitlab_mr#check_glab() | return | endif

  let l:branch = s:current_branch()
  if empty(l:branch)
    echohl ErrorMsg | echom '[gitlab-mr] Not in a git repository' | echohl None
    return
  endif

  " Parse extra CLI args (e.g. --wip) and optional target branch
  let l:extra_args = []
  let l:target = ''
  for l:arg in a:000
    if l:arg =~# '^--'
      call add(l:extra_args, l:arg)
    elseif empty(l:target)
      let l:target = l:arg
    else
      call add(l:extra_args, l:arg)
    endif
  endfor

  if !empty(l:target)
    " direct mode: use argument as target, auto-fill from commits
    let l:title = ''
    let l:desc = ''
  else
    " interactive mode
    call inputsave()
    let l:title = input('MR title (or Enter to auto-fill from commits): ')
    call inputrestore()

    call inputsave()
    let l:desc = input('Description (optional): ')
    call inputrestore()

    call inputsave()
    let l:target = input('Target branch [' . g:gitlab_mr_target_branch . '] (empty to cancel): ')
    call inputrestore()
    if empty(l:target)
      echom '[gitlab-mr] Cancelled.'
      return
    endif
  endif

  let l:cmd = printf('glab mr create --yes --source-branch %s --target-branch %s',
        \ shellescape(l:branch), shellescape(l:target))
  if empty(l:title)
    " Generate title from first commit's first line
    let l:commits = systemlist('git log --format=%s ' . shellescape(l:target) . '..' . shellescape(l:branch) . ' 2>/dev/null')
    if !v:shell_error && !empty(l:commits) && !empty(l:commits[0])
      let l:auto_title = trim(l:commits[0])
      if strchars(l:auto_title) > 100
        let l:auto_title = strcharpart(l:auto_title, 0, 100)
      endif
      let l:cmd .= ' --title ' . shellescape(l:auto_title)
    else
      let l:cmd .= ' --title ' . shellescape(l:branch)
    endif
  else
    let l:cmd .= ' --title ' . shellescape(l:title)
  endif
  let l:cmd .= ' --description ' . shellescape(l:desc)

  if !empty(l:extra_args)
    let l:cmd .= ' ' . join(map(copy(l:extra_args), 'shellescape(v:val)'))
  endif

  redraw!
  call s:echo_progress('Creating MR')
  let l:out = system(l:cmd . ' 2>&1')
  if v:shell_error
    echohl ErrorMsg | echom '[gitlab-mr] ' . l:out | echohl None
  else
    echom '[gitlab-mr] ' . substitute(l:out, '\n', ' ', 'g')

    " Post-creation actions
    let l:iid = substitute(l:out, '.*/merge_requests/\([0-9]\+\).*', '\1', '')
    if l:iid !~# '^\d\+$'
      let l:iid = s:resolve_mr_id('')
    endif
    if !empty(l:iid)
      if g:gitlab_mr_create_open_diffview
        call gitlab_mr#diffview(l:iid)
      endif
      if g:gitlab_mr_create_open_browser
        let l:url = matchstr(l:out, 'https\?://[^[:space:]]*merge_requests/\d\+')
        if !empty(l:url)
          call system(has('mac') ? 'open ' . shellescape(l:url) : 'xdg-open ' . shellescape(l:url) . ' &')
        endif
      endif
    endif
  endif
endfunction

" --------------- MR CLOSE ---------------

function! s:mr_subcommand(subcmd, id) abort
  if !gitlab_mr#check_glab() | return | endif

  let l:id = s:resolve_mr_id(a:id)
  if empty(l:id)
    echohl ErrorMsg | echom '[gitlab-mr] No MR found for current branch' | echohl None
    return
  endif

  let l:action = a:subcmd ==# 'merge' ? 'Merge' : 'Close'
  let l:gerund = a:subcmd ==# 'merge' ? 'Merging' : 'Closing'

  call inputsave()
  let l:confirm = input('[gitlab-mr] ' . l:action . ' MR !' . l:id . '? [y/N]: ')
  call inputrestore()
  if l:confirm !~? '^y'
    echom '[gitlab-mr] Cancelled.'
    return
  endif

  call s:echo_progress(l:gerund . ' MR !' . l:id)
  let l:out = system('glab mr ' . a:subcmd . ' ' . l:id)
  if v:shell_error
    echohl ErrorMsg | echom '[gitlab-mr] ' . l:out | echohl None
  else
    echom '[gitlab-mr] ' . l:out
  endif
endfunction

function! gitlab_mr#close(id) abort
  call s:mr_subcommand('close', a:id)
endfunction

function! gitlab_mr#merge(id) abort
  call s:mr_subcommand('merge', a:id)
endfunction

" --------------- MR DIFFVIEW (data + ui) ---------------

function! s:dv_refresh() abort
  call s:dv_fetch_and_render(t:dv_mr_id)
endfunction

function! s:dv_quit() abort
  if get(t:, 'is_mr_list_tab', 0)
    " Embedded mode: close diffview panes, MR list fills tab
    call s:dv_panes_close()
  elseif tabpagenr('$') <= 1
    only
    quit
  else
    tabclose!
  endif
endfunction

function! s:dv_node(name, path) abort
  return {'name': a:name, 'path': a:path, 'children': [], 'files': [], 'expanded': 1}
endfunction

function! s:dv_status(adds, dels) abort
  if a:adds > 0 && a:dels > 0  | return 'M' | endif
  if a:adds > 0                 | return 'A' | endif
  if a:dels > 0                 | return 'D' | endif
  return 'R'
endfunction

function! s:dv_file_dict(path, adds, dels) abort
  return {'name': fnamemodify(a:path, ':t'), 'path': a:path, 'adds': a:adds, 'dels': a:dels, 'status': s:dv_status(a:adds, a:dels)}
endfunction

function! s:dv_collect_files(raw_lines) abort
  let l:files = []
  let l:path = ''
  let l:adds = 0
  let l:dels = 0

  for l:line in a:raw_lines
    if l:line =~# '^diff --git '
      if !empty(l:path)
        call add(l:files, s:dv_file_dict(l:path, l:adds, l:dels))
      endif
      let l:m = matchlist(l:line, 'a/\(.*\) b/')
      let l:path = len(l:m) > 1 ? l:m[1] : ''
      let l:adds = 0 | let l:dels = 0
    elseif l:line =~# '^--- '
      let l:new_path = substitute(l:line, '^--- \%(a/\|b/\)\?', '', '')
      if l:new_path !~# '^/dev/null$'
        if !empty(l:path) && l:path !=# l:new_path
          call add(l:files, s:dv_file_dict(l:path, l:adds, l:dels))
          let l:adds = 0 | let l:dels = 0
        endif
        let l:path = l:new_path
      endif
    elseif l:line =~# '^+++ ' && empty(l:path)
      let l:path = substitute(l:line, '^+++ \%(a/\|b/\)\?', '', '')
    elseif l:line =~# '^\+' && l:line !~# '^+++ '
      let l:adds += 1
    elseif l:line =~# '^-' && l:line !~# '^--- '
      let l:dels += 1
    endif
  endfor

  if !empty(l:path)
    call add(l:files, {'name': fnamemodify(l:path, ':t'), 'path': l:path, 'adds': l:adds, 'dels': l:dels, 'status': s:dv_status(l:adds, l:dels)})
  endif
  return l:files
endfunction

function! s:dv_build_tree(files) abort
  let l:root = s:dv_node('', '')
  for l:f in a:files
    let l:parts = split(l:f.path, '/')
    let l:node = l:root
    let l:i = 0
    while l:i < len(l:parts) - 1
      let l:part = l:parts[l:i]
      let l:found = v:null
      for l:c in l:node.children
        if l:c.name ==# l:part
          let l:found = l:c
          break
        endif
      endfor
      if l:found is v:null
        let l:found = s:dv_node(l:part, join(l:parts[:l:i], '/'))
        call add(l:node.children, l:found)
      endif
      let l:node = l:found
      let l:i += 1
    endwhile
    call add(l:node.files, l:f)
  endfor
  return l:root
endfunction

function! s:dv_by_name(a, b) abort
  return a:a.name ==# a:b.name ? 0 : a:a.name > a:b.name ? 1 : -1
endfunction

function! s:dv_flatten(node, depth, lines, types, paths, nodes, show_tree) abort
  if a:show_tree && a:depth > 0
    let l:indent = repeat('  ', a:depth - 1)
    let l:icon   = a:node.expanded ? "\u25be" : "\u25b8"
    call add(a:lines, l:indent . l:icon . ' ' . a:node.name . '/')
    call add(a:types, 'dir')
    call add(a:paths, a:node.path)
    call add(a:nodes, a:node)
  endif

  if !a:show_tree || a:node.expanded
    call sort(a:node.children, function('s:dv_by_name'))
    for l:c in a:node.children
      call s:dv_flatten(l:c, a:depth + 1, a:lines, a:types, a:paths, a:nodes, a:show_tree)
    endfor
    call sort(a:node.files, function('s:dv_by_name'))
    for l:f in a:node.files
      let l:tag = '[' . l:f.status . ']'
      if a:show_tree
        call add(a:lines, repeat('  ', a:depth) . l:tag . ' ' . l:f.name . printf('  +%-3d -%-3d', l:f.adds, l:f.dels))
      else
        call add(a:lines, l:tag . ' ' . l:f.path . printf('  +%-3d -%-3d', l:f.adds, l:f.dels))
      endif
      call add(a:types, 'file')
      call add(a:paths, l:f.path)
      call add(a:nodes, {})
    endfor
  endif
endfunction

function! s:dv_render() abort
  let l:lines = []
  let l:types = []
  let l:paths = []
  let l:nodes = []

  call s:dv_flatten(t:dv_tree, 0, l:lines, l:types, l:paths, l:nodes, t:dv_show_tree)

  let l:mr = t:dv_mr_data
  let l:ms = exists('t:dv_merge_status') ? t:dv_merge_status : ''
  let l:merge_str = l:ms ==# 'can_be_merged' ? 'clean' : l:ms ==# 'cannot_be_merged' ? 'CONFLICT' : 'unknown'
  let l:date = s:format_timestamp(get(l:mr, 'created_at', ''))

  let l:mr_info = [
        \ '┃ MR:      ' . l:mr.iid,
        \ '┃ Title:   ' . l:mr.title,
        \ '┃ State:   ' . l:mr.state,
        \ '┃ Merge:   ' . l:merge_str,
        \ '┃ Branch:  ' . l:mr.source_branch . ' → ' . l:mr.target_branch,
        \ '┃ Author:  ' . get(l:mr.author, 'name', '?') . ' (@' . get(l:mr.author, 'username', '?') . ')',
        \ '┃ Date:    ' . l:date,
        \ '┃ URL:     ' . l:mr.web_url,
        \ ]

  if get(t:, 'dv_show_help', 0)
    let l:header = [repeat('━', 40), '  j/k    navigate', '  Enter  toggle dir', '  t      toggle tree/list',
          \ '  n      note', '  m      merge', '  c      close', '  q      quit', repeat('━', 40), ''] + l:mr_info
  else
    let l:header = ['" Press ? for help', ''] + l:mr_info
  endif
  let l:header += ['', '▌Changed files (' . len(t:dv_all_files) . ')', repeat('━', 40)]

  let l:lines = l:header + l:lines
  let l:types = repeat(['header'], len(l:header)) + l:types
  let l:paths = repeat([''], len(l:header)) + l:paths
  let l:nodes = repeat([{}], len(l:header)) + l:nodes

  let l:saved = line('.')
  let t:dv_lines = l:lines
  let t:dv_types = l:types
  let t:dv_paths = l:paths
  let t:dv_nodes = l:nodes
  let t:dv_file_first_line = len(l:header) + 1

  let s:dv_rendering = 1
  setlocal modifiable
  silent! %d _
  call setline(1, l:lines)
  setlocal nomodifiable
  let s:dv_rendering = 0
  call cursor(min([l:saved, len(l:lines)]), 1)
endfunction

function! s:dv_fill_pane_content(win_id, content, ok, file_path, suffix) abort
  call win_gotoid(a:win_id)
  setlocal modifiable
  silent! %d _
  if a:ok | call setline(1, a:content) | else | call setline(1, '') | endif
  silent! execute 'keepalt file! ' . fnamemodify(a:file_path, ':t') . a:suffix
  let &l:statusline = printf('MR #%d%s  %s', t:dv_mr_id, a:suffix, a:file_path)
  if !empty(fnamemodify(a:file_path, ':e'))
    execute 'setlocal filetype=' . fnamemodify(a:file_path, ':e')
  endif
  setlocal nomodifiable
endfunction

function! s:dv_load_file(file_path) abort
  let l:source = t:dv_source
  let l:base   = t:dv_merge_base
  let l:target = get(t:dv_mr_data, 'target_branch', '')

  " --- fetch old content (merge-base, fallback to target branch) ---
  let l:old_cmd = 'git show ' . l:base . ':' . shellescape(a:file_path) . ' 2>/dev/null'
  if !empty(l:target)
    let l:old_cmd .= ' || git show origin/' . shellescape(l:target) . ':' . shellescape(a:file_path) . ' 2>/dev/null'
  endif
  let l:old = systemlist(l:old_cmd)
  let l:old_ok = v:shell_error == 0

  " --- fetch new content (source branch) ---
  let l:new_cmd = 'git show origin/' . l:source . ':' . shellescape(a:file_path) . ' 2>/dev/null'
  let l:new = systemlist(l:new_cmd)
  let l:new_ok = v:shell_error == 0

  " --- fill panes ---
  call s:dv_fill_pane_content(t:dv_win_old, l:old, l:old_ok, a:file_path, ' (base)')
  call s:dv_fill_pane_content(t:dv_win_new, l:new, l:new_ok, a:file_path, ' (source)')

  diffupdate
  call win_gotoid(t:dv_win_tree)
  redraw!
endfunction

function! s:dv_on_cursor_move() abort
  if get(s:, 'dv_rendering', 0) | return | endif
  let t:dv_pending_load = 1
endfunction

function! s:dv_on_cursor_hold() abort
  if !get(t:, 'dv_pending_load', 0) | return | endif
  let t:dv_pending_load = 0
  if !exists('t:dv_types') | return | endif
  let l:ln = line('.') - 1
  if l:ln < 0 || l:ln >= len(t:dv_types) | return | endif
  if t:dv_types[l:ln] !=# 'file' | return | endif
  let l:path = t:dv_paths[l:ln]
  if l:path ==# get(t:, 'dv_current_file', '') | return | endif
  let t:dv_current_file = l:path
  call s:dv_load_file(l:path)
endfunction

function! s:dv_toggle_dir() abort
  if !exists('t:dv_types') | return | endif
  let l:ln = line('.') - 1
  if l:ln < 0 || l:ln >= len(t:dv_types) | return | endif
  if t:dv_types[l:ln] !=# 'dir' | return | endif
  let l:node = t:dv_nodes[l:ln]
  let l:node.expanded = !l:node.expanded
  call s:dv_render()
  let t:dv_current_file = ''
  call s:dv_on_cursor_move()
endfunction

function! s:dv_toggle_view() abort
  let t:dv_show_tree = !t:dv_show_tree
  call s:dv_render()
  let t:dv_current_file = ''
  call s:dv_on_cursor_move()
endfunction

function! s:dv_toggle_help() abort
  let t:dv_show_help = !get(t:, 'dv_show_help', 0)
  call s:dv_render()
endfunction

function! s:dv_scroll(dir) abort
  if a:dir > 0
    call win_execute(t:dv_win_old, 'normal! ' . "\<C-d>")
    call win_execute(t:dv_win_new, 'normal! ' . "\<C-d>")
  else
    call win_execute(t:dv_win_old, 'normal! ' . "\<C-u>")
    call win_execute(t:dv_win_new, 'normal! ' . "\<C-u>")
  endif
endfunction

function! s:dv_setup_keys() abort
  nnoremap <buffer> <silent> <CR>  :call <SID>dv_toggle_dir()<CR>
  nnoremap <buffer> <silent> ?     :call <SID>dv_toggle_help()<CR>
  nnoremap <buffer> <silent> t     :call <SID>dv_toggle_view()<CR>
  nnoremap <buffer> <silent> J     :call <SID>dv_scroll(1)<CR>
  nnoremap <buffer> <silent> K     :call <SID>dv_scroll(-1)<CR>
  nnoremap <buffer> <silent> o     :call <SID>dv_open_file()<CR>
  nnoremap <buffer> <silent> n     :call <SID>note_cur()<CR>
  nnoremap <buffer> <silent> L     :call <SID>comments_cur()<CR>
  nnoremap <buffer> <silent> m     :call <SID>dv_merge()<CR>
  nnoremap <buffer> <silent> c     :call <SID>dv_close()<CR>
  nnoremap <buffer> <silent> r     :call <SID>dv_refresh()<CR>
  nnoremap <buffer> <silent> q     :call <SID>dv_quit()<CR>
endfunction

function! s:dv_setup_diff_keys() abort
  nnoremap <buffer> <silent> n  :call <SID>note_cur()<CR>
  nnoremap <buffer> <silent> L  :call <SID>comments_cur()<CR>
  nnoremap <buffer> <silent> m  :call <SID>dv_merge()<CR>
  nnoremap <buffer> <silent> c  :call <SID>dv_close()<CR>
  nnoremap <buffer> <silent> r  :call <SID>dv_refresh()<CR>
  nnoremap <buffer> <silent> q  :call <SID>dv_quit()<CR>
endfunction

function! s:dv_setup_syntax() abort
  syntax match GitlabMrDvNew  '\[A\]'
  syntax match GitlabMrDvMod  '\[M\]'
  syntax match GitlabMrDvDel  '\[D\]'
  syntax match GitlabMrDvRen  '\[R\]'
  syntax match GitlabMrDvDir    '^\s*[▸▾] .*/$'
  syntax match GitlabMrDvPlus   '\s+\d\+'
  syntax match GitlabMrDvMinus  '\s-\d\+'
  syntax match GitlabMrDvLine   '^┃'
  syntax match GitlabMrDvSep    '^━\+$'
  syntax match GitlabMrDvHeader '^▌.*'
  syntax match GitlabMrDvStateOpened '\<opened\>'
  syntax match GitlabMrDvStateMerged '\<merged\>'
  syntax match GitlabMrDvStateClosed '\<closed\>'
  syntax match GitlabMrDvConflict 'CONFLICT'
  syntax match GitlabMrDvClean    '\<clean\>'
  highlight default GitlabMrDvNew      ctermfg=green   guifg=#98c379
  highlight default GitlabMrDvMod      ctermfg=yellow  guifg=#e5c07b
  highlight default GitlabMrDvDel      ctermfg=red     guifg=#e06c75
  highlight default GitlabMrDvRen      ctermfg=magenta guifg=#c678dd
  highlight default GitlabMrDvDir      ctermfg=cyan    guifg=#56b6c2
  highlight default GitlabMrDvPlus     ctermfg=green   guifg=#98c379
  highlight default GitlabMrDvMinus    ctermfg=red     guifg=#e06c75
  highlight default GitlabMrDvLine     ctermfg=blue    guifg=#4a86c8
  highlight default GitlabMrDvSep      ctermfg=gray    guifg=#5c6370
  highlight default GitlabMrDvHeader   cterm=bold      ctermfg=white  guifg=#e5c07b
  highlight default GitlabMrDvStateOpened ctermfg=green  guifg=#98c379
  highlight default GitlabMrDvStateMerged ctermfg=blue   guifg=#61afef
  highlight default GitlabMrDvStateClosed ctermfg=red    guifg=#e06c75
  highlight default GitlabMrDvConflict    ctermfg=white ctermbg=red    guifg=#ffffff guibg=#e06c75
  highlight default GitlabMrDvClean       ctermfg=green   guifg=#98c379
endfunction

function! s:dv_open_file() abort
  if !exists('t:dv_types') | return | endif
  let l:ln = line('.') - 1
  if l:ln < 0 || l:ln >= len(t:dv_types) || t:dv_types[l:ln] !=# 'file' | return | endif
  let l:path = t:dv_paths[l:ln]
  if !filereadable(l:path)
    echom '[gitlab-mr] File not found: ' . l:path
    return
  endif
  execute 'tabedit ' . fnameescape(l:path)
endfunction

function! s:post_note(iid) abort
  call inputsave()
  let l:comment = input('Comment for MR !' . a:iid . ': ')
  call inputrestore()
  if empty(l:comment) | return | endif
  let l:out = system('glab mr note ' . a:iid . ' -m ' . shellescape(l:comment) . ' 2>&1')
  if v:shell_error
    echohl ErrorMsg | echom '[gitlab-mr] ' . l:out | echohl None
  else
    echom '[gitlab-mr] Comment posted.'
  endif
endfunction

function! s:dv_merge() abort
  let l:ms = exists('t:dv_merge_status') ? t:dv_merge_status : ''
  if l:ms ==# 'cannot_be_merged'
    echohl ErrorMsg | echom '[gitlab-mr] Cannot merge: conflicts exist' | echohl None
    return
  endif
  if t:dv_mr_data.state ==# 'merged'
    echohl ErrorMsg | echom '[gitlab-mr] MR is already merged' | echohl None
    return
  endif
  call gitlab_mr#merge(t:dv_mr_id)
endfunction

function! s:dv_close() abort
  if t:dv_mr_data.state ==# 'merged'
    echohl ErrorMsg | echom '[gitlab-mr] MR is already merged' | echohl None
    return
  endif
  call gitlab_mr#close(t:dv_mr_id)
endfunction

" ── Unified pane operations (tree + base + source always handled together) ──

function! s:dv_panes_valid() abort
  return exists('t:dv_win_tree') && win_id2win(t:dv_win_tree) > 0
        \ && exists('t:dv_win_old') && win_id2win(t:dv_win_old) > 0
        \ && exists('t:dv_win_new') && win_id2win(t:dv_win_new) > 0
endfunction

function! s:dv_panes_kill_jobs() abort
  call s:job_kill_buf(winbufnr(t:dv_win_tree))
  call s:job_kill_buf(winbufnr(t:dv_win_old))
  call s:job_kill_buf(winbufnr(t:dv_win_new))
endfunction

function! s:dv_panes_reset_state(id) abort
  let t:dv_mr_id        = a:id
  let t:dv_source       = ''
  let t:dv_mr_data      = {}
  let t:dv_merge_base   = ''
  let t:dv_merge_status = ''
  let t:dv_current_file = ''
  let t:dv_all_files    = []
  let t:dv_tree         = {}
  let t:dv_lines        = []
  let t:dv_types        = []
  let t:dv_paths        = []
  let t:dv_nodes        = []
  let t:dv_show_tree    = 1
  let t:dv_show_help    = 0
  let t:dv_pending      = 0
endfunction

function! s:dv_panes_show_loading() abort
  " Clear all three panes, show Loading, update statuslines
  call win_execute(t:dv_win_tree, 'setlocal modifiable | silent! %d _ | call setline(1, ''▌Loading…'') | setlocal nomodifiable | let &l:statusline = printf(''MR #%d  Loading…'', t:dv_mr_id)')
  call win_execute(t:dv_win_old,  'setlocal modifiable | silent! %d _ | call setline(1, ''Loading…'')   | setlocal nomodifiable | let &l:statusline = printf(''MR #%d (base)'',  t:dv_mr_id)')
  call win_execute(t:dv_win_new,  'setlocal modifiable | silent! %d _ | call setline(1, ''Loading…'')   | setlocal nomodifiable | let &l:statusline = printf(''MR #%d (source)'', t:dv_mr_id)')
endfunction

function! s:dv_panes_close() abort
  if exists('t:dv_win_new') && win_id2win(t:dv_win_new) > 0
    call win_execute(t:dv_win_new, 'close')
  endif
  if exists('t:dv_win_old') && win_id2win(t:dv_win_old) > 0
    call win_execute(t:dv_win_old, 'close')
  endif
  if exists('t:dv_win_tree') && win_id2win(t:dv_win_tree) > 0
    call win_execute(t:dv_win_tree, 'close')
  endif
  unlet! t:dv_win_tree
  unlet! t:dv_win_old
  unlet! t:dv_win_new
endfunction

function! s:dv_panes_create(id) abort
  " Create tree|base|source layout. Caller ensures correct window context.
  let l:save_sr = &splitright
  set splitright

  " Tree pane (current window)
  setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
  setlocal modifiable nowrap nonumber norelativenumber signcolumn=no
  let t:dv_win_tree = win_getid()

  " Base (old) pane
  vnew
  setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
  setlocal modifiable nonumber norelativenumber signcolumn=no
  let t:dv_win_old = win_getid()

  " Source (new) pane
  vnew
  setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
  setlocal modifiable nonumber norelativenumber signcolumn=no
  let t:dv_win_new = win_getid()

  " Resize: tree=40col, base/src split rest evenly
  wincmd h
  wincmd h
  vertical resize 40
  wincmd l
  execute 'vertical resize ' . ((&columns - 40) / 2)
  wincmd h

  let &splitright = l:save_sr

  " Establish the diff group between the two content panes.
  " Once set up it stays intact across file switches — only
  " :diffupdate is called afterwards to recalculate.
  call win_execute(t:dv_win_old, 'diffthis')
  call win_execute(t:dv_win_new, 'diffthis')
endfunction

function! s:dv_panes_setup_ui() abort
  " Autocmds on tree pane, keys + syntax on all three
  setlocal updatetime=200
  augroup GitlabMrDvCursor
    autocmd!
    autocmd CursorMoved <buffer> call <SID>dv_on_cursor_move()
    autocmd CursorHold  <buffer> call <SID>dv_on_cursor_hold()
  augroup END

  call s:dv_setup_keys()
  call s:dv_setup_syntax()
  call win_execute(t:dv_win_old, 'call s:dv_setup_diff_keys()')
  call win_execute(t:dv_win_new, 'call s:dv_setup_diff_keys()')
endfunction

" ── High-level diffview operations ──

function! s:dv_reset_tab(id) abort
  call s:dv_panes_kill_jobs()
  call s:dv_panes_reset_state(a:id)
  call s:dv_panes_show_loading()
  redraw!
endfunction

function! s:dv_find_existing_tab() abort
  let l:t = s:find_tab_by_var('dv_win_tree')
  if l:t > 0 && win_id2win(gettabvar(l:t, 'dv_win_tree')) > 0
    return l:t
  endif
  return 0
endfunction

function! s:dv_create_panes_below(id) abort
  let l:mr_win = bufwinnr('__gitlab_mr_list__')

  botright new
  call s:dv_panes_reset_state(a:id)
  call s:dv_panes_create(a:id)
  call s:dv_panes_show_loading()
  call s:dv_panes_setup_ui()

  " Shrink MR list to 30%, diffview panes take the rest
  if l:mr_win != -1
    call win_execute(win_getid(l:mr_win), 'resize ' . (&lines * 30 / 100))
  endif

  redraw!
endfunction

function! s:dv_create_standalone_tab(id) abort
  tabnew
  call s:dv_panes_reset_state(a:id)
  call s:dv_panes_create(a:id)
  call s:dv_panes_show_loading()
  call s:dv_panes_setup_ui()
  redraw!
endfunction

function! gitlab_mr#diffview(id) abort
  if !gitlab_mr#check_glab() | return | endif

  let l:id = s:resolve_mr_id(a:id)
  if empty(l:id)
    echohl ErrorMsg | echom '[gitlab-mr] No MR found for current branch' | echohl None
    return
  endif

  if get(t:, 'is_mr_list_tab', 0)
    " In MR list tab: create/reuse diffview panes below
    if s:dv_panes_valid()
      call s:dv_reset_tab(l:id)
    else
      call s:dv_create_panes_below(l:id)
    endif
  else
    " Standalone: reuse existing tab or create new one
    let l:existing = s:dv_find_existing_tab()
    if l:existing > 0
      execute 'tabnext' l:existing
      if s:dv_panes_valid()
        call s:dv_reset_tab(l:id)
      else
        let l:existing = 0
      endif
    endif
    if l:existing == 0
      call s:dv_create_standalone_tab(l:id)
    endif
  endif

  " fetch data (async)
  call s:dv_fetch_and_render(l:id)
endfunction

function! s:dv_fetch_and_render(id) abort
  let l:tab = tabpagenr()
  call s:job_kill_buf(bufnr('%'))
  let l:cmd = 'glab mr view ' . a:id . ' --output json 2>/dev/null'
  call s:job_start(l:cmd, function('s:dv_on_mr_view', [a:id, l:tab]))
endfunction

function! s:dv_on_mr_view(id, tab, status, output, buf) abort
  if a:status != 0 || !bufexists(a:buf)
    echohl ErrorMsg | echom '[gitlab-mr] Failed to fetch MR !' . a:id | echohl None
    return
  endif

  " Data: parse MR JSON
  let l:mr = {}
  try
    let l:mr = json_decode(join(a:output, ''))
  catch
    echohl ErrorMsg | echom '[gitlab-mr] Failed to parse MR data' | echohl None
    return
  endtry

  if type(l:mr) != v:t_dict || empty(l:mr)
    echohl ErrorMsg | echom '[gitlab-mr] Failed to fetch MR !' . a:id | echohl None
    return
  endif

  " UI: store MR metadata in tab vars for rendering
  call settabvar(a:tab, 'dv_mr_data', l:mr)
  call settabvar(a:tab, 'dv_source', l:mr.source_branch)

  " Data: fetch diff, merge-base, and merge status
  call s:dv_fetch_diff_data(a:id, a:tab, l:mr)
endfunction

function! s:dv_fetch_diff_data(id, tab, mr) abort
  let l:target = a:mr.target_branch
  let l:source = a:mr.source_branch
  let l:pid = get(a:mr, 'project_id', 0)
  if l:pid == 0
    let l:pid = s:extract_project_id(get(a:mr, 'web_url', ''))
  endif

  call settabvar(a:tab, 'dv_pending', 2)

  let l:fetch_cmd = 'git fetch origin ' . shellescape(l:source) . ' ' . shellescape(l:target) . ' 2>/dev/null && git merge-base origin/' . shellescape(l:target) . ' origin/' . shellescape(l:source) . ' 2>/dev/null || echo FETCH_FAILED'
  call s:job_start(l:fetch_cmd, function('s:dv_on_fetch_done', [a:tab, l:target]))

  if !empty(l:pid)
    let l:merge_cmd = 'glab api "projects/' . l:pid . '/merge_requests/' . a:id . '?with_merge_status_recheck=true"'
    call s:job_start(l:merge_cmd, function('s:dv_on_merge_status_done', [a:tab]))
  else
    call settabvar(a:tab, 'dv_merge_status', '')
    let l:pending = gettabvar(a:tab, 'dv_pending') - 1
    call settabvar(a:tab, 'dv_pending', l:pending)
    call s:dv_try_render(a:tab)
  endif
endfunction

function! s:dv_on_fetch_done(tab, fallback_target, status, output, buf) abort
  let l:base = 'origin/' . a:fallback_target
  if a:status == 0 && !empty(a:output)
    let l:result = a:output[-1]
    if l:result !=# 'FETCH_FAILED'
      let l:base = substitute(l:result, '\n', '', 'g')
    endif
  endif
  call settabvar(a:tab, 'dv_merge_base', l:base)

  " Run git diff --numstat synchronously after fetch completes.
  " Output is "adds\tdels\tpath" — unambiguous and reliable.
  let l:source = gettabvar(a:tab, 'dv_source')
  let l:numstat = systemlist('git diff --numstat ' . l:base . '...origin/' . shellescape(l:source))
  call settabvar(a:tab, 'dv_numstat_raw', l:numstat)

  let l:pending = gettabvar(a:tab, 'dv_pending') - 1
  call settabvar(a:tab, 'dv_pending', l:pending)
  call s:dv_try_render(a:tab)
endfunction

function! s:dv_on_diff_done(tab, status, output, buf) abort
  if a:status == 0
    call settabvar(a:tab, 'dv_diff_raw', a:output)
  else
    call settabvar(a:tab, 'dv_diff_raw', [])
  endif
  let l:pending = gettabvar(a:tab, 'dv_pending') - 1
  call settabvar(a:tab, 'dv_pending', l:pending)
  call s:dv_try_render(a:tab)
endfunction

function! s:dv_on_merge_status_done(tab, status, output, buf) abort
  let l:merge_status = ''
  if a:status == 0
    try
      let l:info = json_decode(join(a:output, ''))
      let l:merge_status = get(l:info, 'merge_status', '')
    catch
    endtry
  endif
  call settabvar(a:tab, 'dv_merge_status', l:merge_status)
  let l:pending = gettabvar(a:tab, 'dv_pending') - 1
  call settabvar(a:tab, 'dv_pending', l:pending)
  call s:dv_try_render(a:tab)
endfunction

function! s:dv_parse_numstat(raw_lines) abort
  let l:files = []
  for l:line in a:raw_lines
    let l:parts = split(l:line, '\t')
    if len(l:parts) >= 3 && l:parts[0] =~# '^\d\+$' && l:parts[1] =~# '^\d\+$'
      call add(l:files, s:dv_file_dict(l:parts[2], str2nr(l:parts[0]), str2nr(l:parts[1])))
    endif
  endfor
  return l:files
endfunction

function! s:dv_try_render(tab) abort
  if gettabvar(a:tab, 'dv_pending') > 0 | return | endif

  " Prefer git diff --numstat (reliable tab-separated stats).
  " Fall back to raw diff parsing if numstat is empty.
  let l:numstat = gettabvar(a:tab, 'dv_numstat_raw', [])
  let l:files = s:dv_parse_numstat(l:numstat)
  if empty(l:files)
    let l:raw = gettabvar(a:tab, 'dv_diff_raw', [])
    if empty(l:raw)
      echohl ErrorMsg | echom '[gitlab-mr] Failed to get diff' | echohl None
      return
    endif
    let l:files = s:dv_collect_files(l:raw)
  endif
  if empty(l:files)
    echom '[gitlab-mr] No changed files.'
    return
  endif

  " Render in the tree window (global window ID)
  let l:tree_win = gettabvar(a:tab, 'dv_win_tree')
  if l:tree_win == 0 | return | endif

  call settabvar(a:tab, 'dv_tree', s:dv_build_tree(l:files))
  call settabvar(a:tab, 'dv_all_files', l:files)
  call settabvar(a:tab, 'dv_show_tree', 1)
  call settabvar(a:tab, 'dv_current_file', '')

  call win_execute(l:tree_win, 'call s:dv_render_from_job(' . a:tab . ')')
endfunction

function! s:dv_render_from_job(tab) abort
  call s:dv_render()

  " find first file line
  let l:first = t:dv_file_first_line
  while l:first <= len(t:dv_types) && t:dv_types[l:first - 1] !=# 'file'
    let l:first += 1
  endwhile
  if l:first <= len(t:dv_lines)
    call cursor(l:first, 1)
    let t:dv_current_file = ''
    let t:dv_pending_load = 1
    call s:dv_on_cursor_hold()
  else
    call cursor(t:dv_file_first_line, 1)
  endif

  call win_execute(t:dv_win_tree, 'let &l:statusline = printf(''MR #%d  Changes'', t:dv_mr_id)')

  redraw!
  echom '[gitlab-mr] Diff view loaded for MR !' . t:dv_mr_id
endfunction

" --------------- MR COMMENTS ---------------

function! gitlab_mr#comments(id) abort
  if !gitlab_mr#check_glab() | return | endif
  let l:id = s:resolve_mr_id(a:id)
  if empty(l:id) | return | endif

  let l:height = &lines * 30 / 100
  let l:win = bufwinnr('__gitlab_mr_comments__')
  if l:win != -1
    " reuse existing window
    execute l:win . 'wincmd w'
    execute 'resize ' . l:height
  else
    " create new window
    execute 'silent! bdelete! __gitlab_mr_comments__'
    execute 'botright ' . l:height . 'new __gitlab_mr_comments__'
    call s:scratch_buffer()

    " syntax highlighting
    syntax match GitlabMrCommentAuthor '^  ▸ \S\+' contains=GitlabMrCommentTime
    syntax match GitlabMrCommentTime   '\d\+\S* ago' contained
    syntax match GitlabMrCommentSystem '\[system\]'
    syntax match GitlabMrCommentSep    '^─\+$'
    highlight default GitlabMrCommentAuthor ctermfg=cyan  guifg=#61afef
    highlight default GitlabMrCommentTime   ctermfg=gray  guifg=#5c6370
    highlight default GitlabMrCommentSystem ctermfg=darkyellow guifg=#d19a66
    highlight default GitlabMrCommentSep    ctermfg=gray  guifg=#5c6370

    nnoremap <buffer> <silent> q :close<CR>
  endif

  let b:mr_comments_id = l:id
  let &l:statusline = printf('MR #%d  Comments', b:mr_comments_id)

  setlocal modifiable
  silent! %d _
  call setline(1, '▌Loading comments…')
  setlocal nomodifiable
  redraw!

  call s:echo_progress('Loading comments for MR !' . l:id)
  call s:job_kill_buf(bufnr('%'))
  let l:cmd = 'glab mr note list ' . l:id . ' -F json 2>/dev/null'
  call s:job_start(l:cmd, function('s:comments_on_fetch', []))
endfunction

function! s:comments_on_fetch(status, output, buf) abort
  if !bufexists(a:buf) | return | endif

  let l:notes = []
  if a:status == 0
    try
      let l:data = json_decode(join(a:output, ''))
      if type(l:data) == v:t_list
        for l:d in l:data
          let l:ns = get(l:d, 'notes', [])
          if type(l:ns) == v:t_list
            call extend(l:notes, l:ns)
          endif
        endfor
      endif
    catch
      let l:notes = []
    endtry
  endif

  call setbufvar(a:buf, 'comments_notes', l:notes)
  call setbufvar(a:buf, 'comments_status', a:status)
  let l:winnr = bufwinnr(a:buf)
  if l:winnr == -1 | return | endif
  call win_execute(win_getid(l:winnr), 'call s:comments_render()')
endfunction

function! s:comments_render() abort
  let l:notes = get(b:, 'comments_notes', [])
  let l:status = get(b:, 'comments_status', -1)

  if l:status != 0 && empty(l:notes)
    echohl ErrorMsg | echom '[gitlab-mr] Failed to load comments' | echohl None
  endif

  let l:lines = []
  call add(l:lines, '▌Comments for MR !' . b:mr_comments_id . '  (' . len(l:notes) . ' notes)')
  call add(l:lines, repeat('━', 80))

  if empty(l:notes)
    call add(l:lines, '')
    call add(l:lines, '  No comments.')
  else
    for l:n in l:notes
      call add(l:lines, '')
      let l:author = get(get(l:n, 'author', {}), 'username', get(get(l:n, 'author', {}), 'name', 'unknown'))
      let l:created = get(l:n, 'created_at', '')
      let l:body = s:strip_html(get(l:n, 'body', ''))
      let l:system = get(l:n, 'system', v:false)

      let l:time_str = s:format_timestamp(l:created)

      if l:system
        call add(l:lines, '  ▸ ' . l:author . '  ' . l:time_str . '  [system]')
      else
        call add(l:lines, '  ▸ ' . l:author . '  ' . l:time_str)
      endif

      if !empty(l:body)
        for l:bl in split(l:body, '\n')
          call add(l:lines, '    │ ' . l:bl)
        endfor
      endif
    endfor
    call add(l:lines, '')
    call add(l:lines, repeat('━', 80))
  endif

  let l:height = min([max([len(l:lines) + 1, 8]), &lines * 30 / 100])
  execute 'resize ' . l:height

  setlocal modifiable
  silent! %d _
  call setline(1, l:lines)
  setlocal nomodifiable
endfunction

function! s:format_timestamp(timestamp) abort
  if empty(a:timestamp) | return '' | endif
  let l:clean = substitute(a:timestamp, 'T', ' ', '')
  let l:clean = substitute(l:clean, '\..*', '', '')
  let l:clean = substitute(l:clean, 'Z$', '', '')
  return l:clean
endfunction

function! s:strip_html(text) abort
  let l:text = a:text

  " Normalize whitespace: collapse literal newlines and multiple spaces
  " (HTML source may have newlines between tags that conflict with our
  " block-level newline insertion)
  let l:text = substitute(l:text, '[\r\n]\+', ' ', 'g')
  let l:text = substitute(l:text, '\s\{2,\}', ' ', 'g')

  " Replace <br> variants with newlines
  let l:text = substitute(l:text, '<br\s*/\?>', '\n', 'gi')

  " List items: <li> → bullet (newline before creates separation)
  " </li> is stripped by the remaining-tags pass below
  let l:text = substitute(l:text, '<li[^>]*>', '\n  • ', 'gi')

  " Block-level elements → newlines
  let l:text = substitute(l:text, '</\?\(p\|div\|section\|article\|header\|footer\)[^>]*>', '\n', 'gi')

  " List containers
  let l:text = substitute(l:text, '<\(/\?\)\(ul\|ol\)[^>]*>', '\n', 'gi')

  " Headings
  let l:text = substitute(l:text, '</\?h[1-6][^>]*>', '\n', 'gi')

  " Blockquote, pre, hr
  let l:text = substitute(l:text, '</\?\(blockquote\|pre\|hr\)[^>]*>', '\n', 'gi')

  " Table structural elements
  let l:text = substitute(l:text, '</\?\(table\|tr\|tbody\|thead\|tfoot\|colgroup\|col\)[^>]*>', '\n', 'gi')

  " Table cells: </td> / </th> → separator, <td> / <th> → nothing
  let l:text = substitute(l:text, '</\(td\|th\)>', ' | ', 'gi')
  let l:text = substitute(l:text, '<\(td\|th\)[^>]*>', '', 'gi')

  " Strip all remaining HTML tags
  let l:text = substitute(l:text, '<[^>]\+>', '', 'gi')

  " Decode common HTML entities
  let l:text = substitute(l:text, '&lt;', '<', 'g')
  let l:text = substitute(l:text, '&gt;', '>', 'g')
  let l:text = substitute(l:text, '&amp;', '\&', 'g')
  let l:text = substitute(l:text, '&quot;', '"', 'g')
  let l:text = substitute(l:text, '&#39;', "'", 'g')
  let l:text = substitute(l:text, '&nbsp;', ' ', 'g')

  " Clean up trailing table-cell separators at end of lines
  let l:text = substitute(l:text, ' | \n', '\n', 'g')

  " Collapse 3+ consecutive newlines into 2
  let l:text = substitute(l:text, '\n\n\n\+', '\n\n', 'g')

  " Trim trailing whitespace on each line
  let l:text = substitute(l:text, '\v\s+\n', '\n', 'g')

  " Trim leading and trailing newlines
  let l:text = substitute(l:text, '^\n\+', '', '')
  let l:text = substitute(l:text, '\n\+$', '', '')

  return l:text
endfunction
