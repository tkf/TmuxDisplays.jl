module TmuxDisplays

export tmuxdisplay

using Base: Filesystem

struct TmuxDisplay <: AbstractDisplay
    pane_id::String
    pane_pid::Int
    waiter_fifo::IOStream
    waiter_path::String
    tty::Base.TTY
end

Base.IO(tmux::TmuxDisplay) = tmux.tty

function Base.display(tmux::TmuxDisplay, mime::MIME"text/plain", x)
    io = IO(tmux)
    println(io)
    println(io)
    printstyled(io, "_"^displaysize(io)[2]; color = :blue)
    println(io)
    println(io, ' ')
    # print(io, "\e[3J")
    print(io, "\033c")
    show(io, mime, x)
    return
end

Base.isopen(tmux::TmuxDisplay) = success(`tmux has-session -t $(tmux.pane_id)`)

function Base.close(tmux::TmuxDisplay)
    close(tmux.waiter_fifo)
    close(tmux.tty)
end

struct Lockable{T,L}
    value::T
    lock::L
end

Base.lock(f, lockable::Lockable) = lock(() -> f(lockable.value), lockable.lock)

const DISPLAYS = Lockable(Dict{String,WeakRef}(), ReentrantLock())

# Wrap C function?
mkfifo(path::AbstractString) = run(`mkfifo $path`)

function tmpfifo()
    path = tempname() * "_TmuxDisplays"
    mkfifo(path)
    # Retry when fail?
    return path
end

make_tty(path::AbstractString) = Base.TTY(fd(Filesystem.open(path, Filesystem.JL_O_WRONLY)))

function split_window()
    waiter_path = tmpfifo()
    cmd = `
    tmux
    split-window
    -d
    -P
    -F '#{pane_id} #{pane_pid} #{pane_tty}'
    "cat $waiter_path"
    `
    pane_id, pane_pid, pane_tty = split(read(cmd, String))
    tmux = TmuxDisplay(
        pane_id,
        parse(Int, pane_pid),
        open(waiter_path, write = true),
        waiter_path,
        make_tty(pane_tty),
    )
    lock(DISPLAYS) do d
        d[tmux.pane_id] = WeakRef(tmux)
    end
    let waiter_fifo = tmux.waiter_fifo,
        tmux = (waiter_path = tmux.waiter_path, pane_id = tmux.pane_id)
        finalizer(waiter_fifo) do _
            @async cleanup_tmux(tmux)
        end
    end
    return tmux
end

function cleanup_tmux(tmux)
    try
        rm(tmux.waiter_path, force = true)
        # close(tmux)
        lock(DISPLAYS) do d
            pop!(d, tmux.pane_id, nothing)
        end
    catch err
        @error("`cleanup_tmux` failed.", exception = (err, catch_backtrace()))
    end
end

DEFAULT_DISPLAY = nothing

"""
    tmuxdisplay() :: TmuxDisplay

Return the default `TmuxDisplay` instance.  Create one if it does not
exist.
"""
function tmuxdisplay()
    global DEFAULT_DISPLAY
    if DEFAULT_DISPLAY === nothing || !isopen(DEFAULT_DISPLAY)
        DEFAULT_DISPLAY = split_window()
    end
    return DEFAULT_DISPLAY
end

"""
    tmuxdisplay(x) :: TmuxDisplay

Display `x` in a separate pane of current tmux session.  Return the
`TmuxDisplay` used for showing `x`.
"""
function tmuxdisplay(x)
    tmux = tmuxdisplay()
    display(tmux, MIME"text/plain"(), x)
    return tmux
end

"""
    TmuxDisplays.closeall()

Close all `TmuxDisplay`s.
"""
function closeall()
    global DEFAULT_DISPLAY
    DEFAULT_DISPLAY = nothing
    lock(DISPLAYS) do d
        for (pane_id, ref) in collect(d)
            tmux = ref.value
            tmux === nothing && continue
            close(tmux)
            cleanup_tmux(tmux)
            pop!(d, pane_id, nothing)
        end
    end
end

function __init__()
    atexit(closeall)
end

end # module
