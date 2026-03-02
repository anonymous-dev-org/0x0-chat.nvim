if exists('g:loaded_zeroxzero')
  finish
endif
let g:loaded_zeroxzero = 1

command! ZeroSend                lua require('zeroxzero').send()
command! -range ZeroSendMessage  lua require('zeroxzero').send_message()
command! ZeroDiff                lua require('zeroxzero').diff()
command! ZeroInterrupt           lua require('zeroxzero').interrupt()
command! ZeroInlineEdit          lua require('zeroxzero').inline_edit()
