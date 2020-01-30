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

Base.display(tmux::TmuxDisplay, x) = display(tmux, MIME"text/plain"(), x)

Base.isopen(tmux::TmuxDisplay) = success(`tmux has-session -t $(tmux.pane_id)`)

function Base.close(tmux::TmuxDisplay)
    close(tmux.waiter_fifo)
    close(tmux.tty)
    cleanup_tmux(tmux)
end

function Base.show(io::IO, ::MIME"text/plain", tmux::TmuxDisplay)
    print(io, "TmuxDisplay: pane ", tmux.pane_id, ' ')
    if isopen(tmux)
        printstyled(io, "(open)"; color=:green)
    else
        printstyled(io, "(closed)"; color=:red)
    end
end

struct Lockable{T,L}
    value::T
    lock::L
end

Lockable(value) = Lockable(value, ReentrantLock())

Base.lock(f, lockable::Lockable) = lock(() -> f(lockable.value), lockable.lock)

const DISPLAYS = Lockable(Dict{String,TmuxDisplay}())
const DEFAULT_DISPLAY = Lockable(Ref{Union{Nothing,TmuxDisplay}}(nothing))

# Wrap C function?
mkfifo(path::AbstractString) = run(`mkfifo $path`)

function tmpfifo()
    path = tempname() * "_TmuxDisplays"
    mkfifo(path)
    # Retry when fail?
    return path
end

make_tty(path::AbstractString) = Base.TTY(fd(Filesystem.open(path, Filesystem.JL_O_WRONLY)))

"""
    TmuxDisplays.split_window() :: TmuxDisplay

Use `tmux split-window` to create a new pane that is used as an
external display.
"""
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
        d[tmux.pane_id] = tmux
    end
    return tmux
end

function cleanup_tmux(tmux)
    try
        rm(tmux.waiter_path, force = true)
        lock(DISPLAYS) do d
            pop!(d, tmux.pane_id, nothing)
        end
    catch err
        @error("`cleanup_tmux` failed.", exception = (err, catch_backtrace()))
    end
end

"""
    tmuxdisplay() :: TmuxDisplay

Return the default `TmuxDisplay` instance.  Create one if it does not
exist.
"""
function tmuxdisplay()
    cleanupall()
    lock(DEFAULT_DISPLAY) do ref
        d = ref[]
        if d === nothing || !isopen(d)
            ref[] = d = split_window()
        end
        return d
    end
end

"""
    tmuxdisplay(x) :: TmuxDisplay

Display `x` in a separate pane of current tmux session.  Return the
`TmuxDisplay` used for showing `x`.
"""
function tmuxdisplay(x)
    tmux = tmuxdisplay()
    display(tmux, x)
    return tmux
end

"""
    TmuxDisplays.closeall()

Close all `TmuxDisplay`s.
"""
function closeall()
    lock(DEFAULT_DISPLAY) do ref
        ref[] = nothing
    end
    lock(DISPLAYS) do d
        while !isempty(d)
            (_, tmux) = pop!(d)
            close(tmux)
        end
    end
end

# TODO: get rid of this by using another FIFO used in the "opposite"
# direction; i.e., the process inside `tmux` tries to _write_ to it
# and then the Julia side tries to read.
function cleanupall()
    lock(DISPLAYS) do d
        for (pane_id, tmux) in collect(d)
            isopen(tmux) || close(tmux)
        end
    end
end

function __init__()
    atexit(closeall)
end

end # module
