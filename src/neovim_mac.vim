function! neovim_mac#DropText(text) abort
    let begin = getpos(".")

    if begin[2] != 1
        let begin[2] += 1
    endif

    call nvim_put(a:text, "c", 1, 1)
    call setpos("'<", begin)
    call setpos("'>", getpos("."))

    normal! gv
endfunction

function! neovim_mac#OpenTabs(paths) abort
    let edit = ( bufnr('$') == 1    &&
               \ line('$')  == 1    &&
               \ bufname(1) == ""   &&
               \ getline(1) == "" )

    for path in a:paths
        if edit
            let edit = 0
            execute "edit " . path
            continue
        endif

        let bufnr = bufnr(path)

        if bufnr != -1
            let window_ids = getbufinfo(bufnr)[0]["windows"]

            if len(window_ids) == 0
                let bufnr = -1
            endif
        endif

        if bufnr == -1
            execute "tabedit " . path
            continue
        endif

        let [tabpage, window] = win_id2tabwin(window_ids[0])

        execute "tabnext " . tabpage
        execute window . " wincmd w"
    endfor
endfunction
