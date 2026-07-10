if exists('g:loaded_gitlab_mr')
  finish
endif
let g:loaded_gitlab_mr = 1

let g:gitlab_mr_target_branch = get(g:, 'gitlab_mr_target_branch', 'main')
let g:gitlab_mr_create_open_browser = get(g:, 'gitlab_mr_create_open_browser', 0)
let g:gitlab_mr_create_open_diffview = get(g:, 'gitlab_mr_create_open_diffview', 0)

nnoremap <silent> <Plug>(gitlab-mr-list) :<C-u>MRList<CR>
nmap <leader>gm <Plug>(gitlab-mr-list)

command! -nargs=? -complete=dir MRList  call gitlab_mr#list(<q-args>)
command! -nargs=?              MRCreate call gitlab_mr#create(<q-args>)
command! -nargs=?              MRClose call gitlab_mr#close(<q-args>)
command! -nargs=?              MRDiffview call gitlab_mr#diffview(<q-args>)
command! -nargs=?              MRMerge call gitlab_mr#merge(<q-args>)
