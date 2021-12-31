vim9script

if has('pythonx')
    g:neovim_rpc#py = 'pythonx'
    def Pyeval(expr: string): any
        return pyxeval(expr)
    enddef
elseif has('python3')
    g:neovim_rpc#py = 'python3'
    def Pyeval(expr: string): any
        return py3eval(expr)
    enddef
else
    g:neovim_rpc#py = 'python'
    def Pyeval(expr: string): any
        return pyeval(expr)
    enddef
endif

def Py(cmd: string)
    execute g:neovim_rpc#py cmd
enddef

def neovim_rpc#serveraddr(): string
    if exists('g:_neovim_rpc_nvim_server')
        return g:_neovim_rpc_nvim_server
    endif

    if &encoding !=? "utf-8"
        throw '[vim-hug-neovim-rpc] requires `:set encoding=utf-8`'
    endif

    try
        Py('import pynvim')
    catch
        try
            Py('import neovim')
        catch
            neovim_rpc#_error("failed executing: " ..
                g:neovim_rpc#py .. " import [pynvim|neovim]")
            neovim_rpc#_error(v:exception)
            throw '[vim-hug-neovim-rpc] requires one of `:' .. g:neovim_rpc#py ..
                ' import [pynvim|neovim]` command to work'
        endtry
    endtry

    Py('import neovim_rpc_server')
    var servers = Pyeval('neovim_rpc_server.start()')

    g:_neovim_rpc_nvim_server     = servers[0]
    g:_neovim_rpc_vim_server = servers[1]

    g:_neovim_rpc_main_channel = ch_open(g:_neovim_rpc_vim_server)

    # identify myself
    ch_sendexpr(g:_neovim_rpc_main_channel, 'neovim_rpc_setup')

    return g:_neovim_rpc_nvim_server
enddef

# elegant python function call wrapper
def neovim_rpc#pyxcall(func: string, ...args: list<any>): any
    Py('import vim, json')
    g:neovim_rpc#_tmp_args = copy(args)
    var ret = Pyeval(func .. '(*vim.vars["neovim_rpc#_tmp_args"])')
    unlet g:neovim_rpc#_tmp_args
    return ret
enddef

# supported opt keys:
# - on_stdout
# - on_stderr
# - on_exit
# - detach
def neovim_rpc#jobstart(cmd: any, opts: dict<any> = {}): number

    opts['_close'] = 0
    opts['_exit'] = 0

    final real_opts: dict<any> = {mode: 'raw'}
    if has_key(opts, 'detach') && opts['detach']
        real_opts['stoponexit'] = ''
    endif

    if has_key(opts, 'on_stdout')
        real_opts['out_cb'] = neovim_rpc#_on_stdout
    endif
    if has_key(opts, 'on_stderr')
        real_opts['err_cb'] = neovim_rpc#_on_stderr
    endif
    real_opts['exit_cb'] = neovim_rpc#_on_exit
    real_opts['close_cb'] = neovim_rpc#_on_close

    const job   = job_start(cmd, real_opts)
    const jobid = ch_info(job)['id']

    g:_neovim_rpc_jobs[jobid] = {cmd: cmd, opts: opts, job: job}

    return jobid
enddef

def neovim_rpc#jobstop(jobid: number): number
    const job = g:_neovim_rpc_jobs[jobid]['job']
    return job_stop(job)
enddef

def neovim_rpc#rpcnotify(channel: number, event: string, ...args: list<any>)
    neovim_rpc#pyxcall('neovim_rpc_server.rpcnotify', channel, event, args)
enddef

var rspid = 1
func neovim_rpc#rpcrequest(channel, event, ...)
    let s:rspid = s:rspid + 1

    " a unique key for storing response
    let rspid = '' .. s:rspid

    " neovim's rpcrequest doesn't have timeout
    let opt = {'timeout': 24 * 60 * 60 * 1000}
    let args = ['rpcrequest', a:channel, a:event, a:000, rspid]
    call ch_evalexpr(g:_neovim_rpc_main_channel, args, opt)

    let expr = 'neovim_rpc_server.responses.pop("' .. rspid .. '")'

    call s:Py('import neovim_rpc_server, json')
    let [err, result] = s:Pyeval(expr)
    if err
        if type(err) == type('')
            throw err
        endif
        throw err[1]
    endif
    return result
endfunc

def neovim_rpc#_on_stdout(job: job, data: any)
    const jobid = ch_info(job)['id']
    const opts = g:_neovim_rpc_jobs[jobid]['opts']
    # convert to neovim style function call
    call(opts['on_stdout'], [jobid, split(data, "\n", 1), 'stdout'], opts)
enddef

def neovim_rpc#_on_stderr(job: job, data: any)
    const jobid = ch_info(job)['id']
    const opts = g:_neovim_rpc_jobs[jobid]['opts']
    # convert to neovim style function call
    call(opts['on_stderr'], [jobid, split(data, "\n", 1), 'stderr'], opts)
enddef

def neovim_rpc#_on_exit(job: job, status: number)
    const jobid = ch_info(job)['id']
    const opts = g:_neovim_rpc_jobs[jobid]['opts']
    opts['_exit'] = 1
    # cleanup when both close_cb and exit_cb is called
    if opts['_close'] && opts['_exit']
        unlet g:_neovim_rpc_jobs[jobid]
    endif
    if has_key(opts, 'on_exit')
        # convert to neovim style function call
        call(opts['on_exit'], [jobid, status, 'exit'], opts)
    endif
enddef

def neovim_rpc#_on_close(job: job)
    const jobid = ch_info(job)['id']
    const opts = g:_neovim_rpc_jobs[jobid]['opts']
    opts['_close'] = 1
    # cleanup when both close_cb and exit_cb is called
    if opts['_close'] && opts['_exit']
        unlet g:_neovim_rpc_jobs[jobid]
    endif
enddef

def neovim_rpc#_callback()
    execute g:neovim_rpc#py .. ' neovim_rpc_server.process_pending_requests()'
enddef

g:_neovim_rpc_main_channel = -1
g:_neovim_rpc_jobs = {}

def neovim_rpc#_error(msg: string)
    if mode() == 'i'
        # NOTE: side effect, sorry, but this is necessary
        set nosmd
    endif
    echohl ErrorMsg
    echom '[vim-hug-neovim-rpc] ' .. msg
    echohl None
enddef

def neovim_rpc#_nvim_err_write(msg: string)
    if mode() == 'i'
        # NOTE: side effect, sorry, but this is necessary
        set nosmd
    endif
    echohl ErrorMsg
    g:error = msg
    echom msg
    echohl None
enddef

def neovim_rpc#_nvim_out_write(msg: string)
    echom msg
enddef
