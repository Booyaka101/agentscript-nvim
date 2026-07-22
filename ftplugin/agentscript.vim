" Filetype settings for Agent Script (.agent).
if exists('b:did_ftplugin')
  finish
endif
let b:did_ftplugin = 1

" Upstream examples use 4-space indentation; the language is indentation-based.
setlocal expandtab shiftwidth=4 softtabstop=4
setlocal commentstring=#\ %s
setlocal comments=:#

let b:undo_ftplugin = 'setlocal expandtab< shiftwidth< softtabstop< commentstring< comments<'
