module TmuxDisplays

export tmuxdisplay

using Base: Filesystem

struct TmuxDisplay <: AbstractDisplay
    pane_id::String
    pane_pid::Int
    waiter_fifo::Base.PipeEndpoint
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

function silent_run(cmd, msg)
    io = IOBuffer()
    success(pipeline(cmd; stdout=io, stderr=io)) ||
        @debug(
            "$cmd failed to run. ($msg)",
            output = Text(chomp(String(take!(io))))
        )
end

function Base.close(tmux::TmuxDisplay)
    silent_run(`tmux kill-pane -t $(tmux.pane_id)`, "already closed?")
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

open_pipe(path::AbstractString) =
    Base.PipeEndpoint(fd(Filesystem.open(path, Filesystem.JL_O_RDONLY)))

make_tty(path::AbstractString) = Base.TTY(fd(Filesystem.open(path, Filesystem.JL_O_WRONLY)))

as_pane_id(tmux::TmuxDisplay) = tmux.pane_id
as_pane_id(id::AbstractString) = id
as_pane_id(x) = error("Cannot interpret as tmux pane:\n", x)

"""
    TmuxDisplays.split_window() :: TmuxDisplay

Use `tmux split-window` to create a new pane that is used as an
external display.

# Keyword Arguments
- `horizontal::Bool = false`: Split pane horizontally if `true`.
- `size::Integer`: Number of lines (for vertical split) or cells (for
  horizontal split).
- `target::Union{TmuxDisplay,AbstractString}`: Tmux pane to be split.
  If it is a string, it is passed to `-t` option of `split-window` as-is.
- `focus::Bool = false`: Focus newly created pane if `true`.
"""
function split_window(; horizontal = false, size = nothing, target = nothing, focus = false)
    cmd = `tmux split-window`
    if horizontal
        cmd = `$cmd -h`
    end
    if size !== nothing
        cmd = `$cmd -l $size`
    end
    if target !== nothing
        cmd = `$cmd -t $(as_pane_id(target))`
    end
    if !focus
        cmd = `$cmd -d`
    end

    waiter_path = tmpfifo()
    cmd = `
    $cmd
    -P
    -F '#{pane_id} #{pane_pid} #{pane_tty}'
    "sleep 2147483647d > $waiter_path"
    `
    pane_id, pane_pid, pane_tty = split(read(cmd, String))
    tmux = TmuxDisplay(
        pane_id,
        parse(Int, pane_pid),
        open_pipe(waiter_path),
        waiter_path,
        make_tty(pane_tty),
    )
    lock(DISPLAYS) do d
        d[tmux.pane_id] = tmux
    end
    @debug "Created: $(sprint(show, "text/plain", tmux))"

    # Cleanup `DISPLAYS`
    @async tmux_waiter(tmux)  # unstructured concurrency...

    return tmux
end

function tmux_waiter(tmux)
    try
        @debug "Waiting for $(tmux.waiter_path) to be closed."
        read(tmux.waiter_fifo)
    catch err
        @error("`read(tmux.waiter_fifo)` failed", exception = (err, catch_backtrace()))
    finally
        @debug "Closing: $(sprint(show, "text/plain", tmux))"
        try
            close(tmux)
        catch err
            @error("`close(tmux)` failed", exception = (err, catch_backtrace()))
        end
    end
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

# TODO: get rid of this once I'm fine with `tmux_waiter`
function cleanupall()
    lock(DISPLAYS) do d
        for (pane_id, tmux) in collect(d)
            if !isopen(tmux)
                @error "Unclosed pane found" tmux
                close(tmux)
            end
        end
    end
end

function __init__()
    atexit(closeall)
end

end # module
