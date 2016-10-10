" Author: w0rp <devw0rp@gmail.com>
" Description: Main entry point for this plugin
"   Loads linters and manages lint jobs

if exists('g:loaded_ale_zmain')
    finish
endif

let g:loaded_ale_zmain = 1

let s:lint_timer = -1
let s:linters = {}
" These versions of Vim have bugs with the 'in_buf' option, so the buffer
" must be sent via getbufline() instead.
let s:has_in_buf_bugs = has('win32') || has('gui_macvim')

if !exists('g:ale_linters')
    let g:ale_linters = {}
endif

" Stores information for each job including:
"
" linter: The linter dictionary for the job.
" buffer: The buffer number for the job.
" output: The array of lines for the output of the job.
let s:job_info_map = {}

" Globals which each part of the plugin should use.
let g:ale_buffer_loclist_map = {}
let g:ale_buffer_should_reset_map = {}
let g:ale_buffer_sign_dummy_map = {}

function! s:GetFunction(string_or_ref)
    if type(a:string_or_ref) == type('')
        return function(a:string_or_ref)
    endif

    return a:string_or_ref
endfunction

function! s:ClearJob(job)
    let job_id = s:GetJobID(a:job)
    let linter = s:job_info_map[job_id].linter

    if has('nvim')
        call jobstop(a:job)
    else
        " We must close the channel for reading the buffer if it is open
        " when stopping a job. Otherwise, we will get errors in the status line.
        if ch_status(job_getchannel(a:job)) ==# 'open'
            call ch_close_in(job_getchannel(a:job))
        endif

        call job_stop(a:job)
    endif

    call remove(s:job_info_map, job_id)
    call remove(linter, 'job')
endfunction

function! s:GatherOutput(job, data)
    let job_id = s:GetJobID(a:job)

    if !has_key(s:job_info_map, job_id)
        return
    endif

    call extend(s:job_info_map[job_id].output, a:data)
endfunction

function! s:GatherOutputNeoVim(job, data, event)
    call s:GatherOutput(a:job, a:data)
endfunction

function! s:GatherOutputVim(channel, data)
    call s:GatherOutput(ch_getjob(a:channel), [a:data])
endfunction

function! s:LocItemCompare(left, right)
    if a:left['lnum'] < a:right['lnum']
        return -1
    endif

    if a:left['lnum'] > a:right['lnum']
        return 1
    endif

    if a:left['col'] < a:right['col']
        return -1
    endif

    if a:left['col'] > a:right['col']
        return 1
    endif

    return 0
endfunction

function! s:FixLoclist(buffer, loclist)
    " Some errors have line numbers beyond the end of the file,
    " so we need to adjust them so they set the error at the last line
    " of the file instead.
    let last_line_number = ale#util#GetLineCount(a:buffer)

    for item in a:loclist
        if item.lnum == 0
            " When errors appear at line 0, put them at line 1 instead.
            let item.lnum = 1
        elseif item.lnum > last_line_number
            let item.lnum = last_line_number
        endif
    endfor
endfunction

function! s:HandleExit(job)
    if a:job ==# 'no process'
        " Stop right away when the job is not valid in Vim 8.
        return
    endif

    let job_id = s:GetJobID(a:job)

    if !has_key(s:job_info_map, job_id)
        return
    endif

    let job_info = s:job_info_map[job_id]

    call s:ClearJob(a:job)

    let linter = job_info.linter
    let output = job_info.output
    let buffer = job_info.buffer

    let linter_loclist = s:GetFunction(linter.callback)(buffer, output)

    " Make some adjustments to the loclists to fix common problems.
    call s:FixLoclist(buffer, linter_loclist)

    if g:ale_buffer_should_reset_map[buffer]
        let g:ale_buffer_should_reset_map[buffer] = 0
        let g:ale_buffer_loclist_map[buffer] = []
    endif

    " Add the loclist items from the linter.
    call extend(g:ale_buffer_loclist_map[buffer], linter_loclist)

    " Sort the loclist again.
    " We need a sorted list so we can run a binary search against it
    " for efficient lookup of the messages in the cursor handler.
    call sort(g:ale_buffer_loclist_map[buffer], 's:LocItemCompare')

    if g:ale_set_loclist
        call setloclist(0, g:ale_buffer_loclist_map[buffer])
    endif

    if g:ale_set_signs
        call ale#sign#SetSigns(buffer, g:ale_buffer_loclist_map[buffer])
    endif

    " Mark line 200, column 17 with a squiggly line or something
    " matchadd('ALEError', '\%200l\%17v')
endfunction

function! s:GetJobID(job)
    if has('nvim')
        "In NeoVim, job values are just IDs.
        return a:job
    endif

    " In Vim 8, the job is a special variable, and we open a channel for each
    " job. We'll use the ID of the channel instead as the job ID.
    return ch_info(job_getchannel(a:job)).id
endfunction

function! s:HandleExitNeoVim(job, data, event)
    call s:HandleExit(a:job)
endfunction

function! s:HandleExitVim(channel)
    call s:HandleExit(ch_getjob(a:channel))
endfunction

function! s:ApplyLinter(buffer, linter)
    if has_key(a:linter, 'job')
        " Stop previous jobs for the same linter.
        call s:ClearJob(a:linter.job)
    endif

    if has_key(a:linter, 'command_callback')
        " If there is a callback for generating a command, call that instead.
        let command = s:GetFunction(a:linter.command_callback)(a:buffer)
    else
        let command = a:linter.command
    endif

    if command =~# '%s'
        " If there is a '%s' in the command string, replace it with the name
        " of the file.
        let command = printf(command, shellescape(fnamemodify(bufname(a:buffer), ':p')))
    endif

    if has('nvim')
        if a:linter.output_stream ==# 'stderr'
            " Read from stderr instead of stdout.
            let job = jobstart(command, {
            \   'on_stderr': 's:GatherOutputNeoVim',
            \   'on_exit': 's:HandleExitNeoVim',
            \})
        elseif a:linter.output_stream ==# 'both'
            let job = jobstart(command, {
            \   'on_stdout': 's:GatherOutputNeoVim',
            \   'on_stderr': 's:GatherOutputNeoVim',
            \   'on_exit': 's:HandleExitNeoVim',
            \})
        else
            let job = jobstart(command, {
            \   'on_stdout': 's:GatherOutputNeoVim',
            \   'on_exit': 's:HandleExitNeoVim',
            \})
        endif
    else
        let job_options = {
        \   'in_mode': 'nl',
        \   'out_mode': 'nl',
        \   'err_mode': 'nl',
        \   'close_cb': function('s:HandleExitVim'),
        \}

        if a:linter.output_stream ==# 'stderr'
            " Read from stderr instead of stdout.
            let job_options.err_cb = function('s:GatherOutputVim')
        elseif a:linter.output_stream ==# 'both'
            " Read from both streams.
            let job_options.out_cb = function('s:GatherOutputVim')
            let job_options.err_cb = function('s:GatherOutputVim')
        else
            let job_options.out_cb = function('s:GatherOutputVim')
        endif

        if has('win32')
            " job_start commands on Windows have to be run with cmd /c,
            " othwerwise %PATHTEXT% will not be used to programs ending int
            " .cmd, .bat, .exe, etc.
            let l:command = 'cmd /c ' . l:command
        endif

        if !s:has_in_buf_bugs
            " On some Unix machines, we can send the Vim buffer directly.
            " This is faster than reading the lines ourselves.
            let job_options.in_io = 'buffer'
            let job_options.in_buf = a:buffer
        endif

        " Vim 8 will read the stdin from the file's buffer.
        let job = job_start(l:command, l:job_options)
    endif

    " Only proceed if the job is being run.
    if has('nvim') || (job !=# 'no process' && job_status(job) ==# 'run')
        let a:linter.job = job

        " Store the ID for the job in the map to read back again.
        let s:job_info_map[s:GetJobID(job)] = {
        \   'linter': a:linter,
        \   'buffer': a:buffer,
        \   'output': [],
        \}

        if has('nvim')
            " In NeoVim, we have to send the buffer lines ourselves.
            let input = join(getbufline(a:buffer, 1, '$'), "\n") . "\n"

            call jobsend(job, input)
            call jobclose(job, 'stdin')
        elseif s:has_in_buf_bugs
            " On some Vim versions, we have to send the buffer data ourselves.
            let input = join(getbufline(a:buffer, 1, '$'), "\n") . "\n"
            let channel = job_getchannel(job)

            if ch_status(channel) ==# 'open'
                call ch_sendraw(channel, input)
                call ch_close_in(channel)
            endif
        endif
    endif
endfunction

function! s:TimerHandler(...)
    let filetype = &filetype
    let linters = ALEGetLinters(filetype)

    let buffer = bufnr('%')

    " Set a variable telling us to clear the loclist later.
    let g:ale_buffer_should_reset_map[buffer] = 1

    for linter in linters
        " Check if a given linter has a program which can be executed.
        if has_key(linter, 'executable_callback')
            let l:executable = s:GetFunction(linter.executable_callback)(buffer)
        else
            let l:executable = linter.executable
        endif

        if !executable(l:executable)
            " The linter's program cannot be executed, so skip it.
            continue
        endif

        call s:ApplyLinter(buffer, linter)
    endfor
endfunction

function s:BufferCleanup(buffer)
    if has_key(g:ale_buffer_should_reset_map, a:buffer)
        call remove(g:ale_buffer_should_reset_map, a:buffer)
    endif

    if has_key(g:ale_buffer_loclist_map, a:buffer)
        call remove(g:ale_buffer_loclist_map, a:buffer)
    endif

    if has_key(g:ale_buffer_sign_dummy_map, a:buffer)
        call remove(g:ale_buffer_sign_dummy_map, a:buffer)
    endif
endfunction

function! ALEAddLinter(filetype, linter)
    if !has_key(s:linters, a:filetype)
        let s:linters[a:filetype] = []
    endif

    let new_linter = {
    \   'name': a:linter.name,
    \   'callback': a:linter.callback,
    \}

    if has_key(a:linter, 'executable_callback')
        let new_linter.executable_callback = a:linter.executable_callback
    else
        let new_linter.executable = a:linter.executable
    endif

    if has_key(a:linter, 'command_callback')
        let new_linter.command_callback = a:linter.command_callback
    else
        let new_linter.command = a:linter.command
    endif

    if has_key(a:linter, 'output_stream')
        let new_linter.output_stream = a:linter.output_stream
    else
        let new_linter.output_stream = 'stdout'
    endif

    " TODO: Assert the value of the output_stream to be something sensible.

    call add(s:linters[a:filetype], new_linter)
endfunction

function! ALEGetLinters(filetype)
    if !has_key(s:linters, a:filetype)
        return []
    endif

    if has_key(g:ale_linters, a:filetype)
        let linters = []
        " Filter loaded linters according to list of linters specified in option
        for linter in s:linters[a:filetype]
            if index(g:ale_linters[a:filetype], linter.name) != -1
                call add(linters, linter)
            endif
        endfor
        return linters
    endif

    return s:linters[a:filetype]
endfunction

function! ALELint(delay)
    let filetype = &filetype
    let linters = ALEGetLinters(filetype)

    if s:lint_timer != -1
        call timer_stop(s:lint_timer)
        let s:lint_timer = -1
    endif

    if len(linters) == 0
        " There are no linters to lint with, so stop here.
        return
    endif

    if a:delay > 0
        let s:lint_timer = timer_start(a:delay, function('s:TimerHandler'))
    else
        call s:TimerHandler()
    endif
endfunction

" Load all of the linters for each filetype.
runtime! ale_linters/*/*.vim

if !has('nvim') && !(has('timers') && has('job') && has('channel'))
    echoerr 'ALE requires NeoVim or Vim 8 with +timers +job +channel'
    echoerr 'ALE will not be run automatically'
    finish
endif

if g:ale_lint_on_text_changed
    augroup ALERunOnTextChangedGroup
        autocmd!
        autocmd TextChanged,TextChangedI * call ALELint(g:ale_lint_delay)
    augroup END
endif

if g:ale_lint_on_enter
    augroup ALERunOnEnterGroup
        autocmd!
        autocmd BufEnter,BufRead * call ALELint(100)
    augroup END
endif

if g:ale_lint_on_save
    augroup ALERunOnSaveGroup
        autocmd!
        autocmd BufWrite * call ALELint(0)
    augroup END
endif

" Clean up buffers automatically when they are unloaded.
augroup ALEBuffferCleanup
    autocmd!
    autocmd BufUnload * call s:BufferCleanup('<abuf>')
augroup END
