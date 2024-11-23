module Watcher

#
# Imports:
#

import FileWatching

#
# MonitorTask:
#

struct MonitorTask
    monitor::FileWatching.FolderMonitor
    task::Task
end

function Base.close(mt::MonitorTask)
    close(mt.monitor)
    result = fetch(mt.task)
    if isnothing(result)
        return nothing
    else
        error("monitor task should return `nothing`, returned `$result`.")
    end
end

#
# FolderWatcher:
#

"""
    FolderWatcher(callback; roots, start_dir, delay, skiplist)

Monitor the provided `roots` directories recursively for changes. When new
subdirectories are created they are added to the watch list. When directories
are removed from the directory structure then watching is stopped on them.

  - `roots` must be an array of directory root `String`s. `["."]` by default.
  - `start_dir` is the directory to begin folder search from. `pwd()` by default.
  - `delay` is the time in seconds between each triggered callback. `0.1` by default.
  - `skiplist` directory names to avoid recursing into. By default `.git` and `node_modules`.

Stop watching by calling `close` on the `FolderWatcher` object.
"""
struct FolderWatcher{F<:Base.Callable}
    watchers::Dict{String,MonitorTask}
    callback::F
    roots::Set{String}
    start_dir::String
    delay::Float64
    skiplist::Set{String}

    function FolderWatcher(
        callback::Function = default_callback;
        roots::Vector{String} = ["."],
        start_dir::AbstractString = pwd(),
        delay::Real = 0.1,
        skiplist::Vector{String} = ["node_modules"],
    )
        isempty(roots) && error("`roots` is an empty list.")
        isdir(start_dir) || error("`start_dir` must be a directory.")
        delay > 0 || error("`delay` keyword must be positive.")

        roots = Set(roots)
        skiplist = Set(skiplist)
        push!(skiplist, ".git")

        folders = Set{String}()

        function f(path)
            fullpath = normpath(abspath(joinpath(start_dir, path, ".")))
            push!(folders, fullpath)
        end

        for each in roots
            if condition(each, skiplist)
                f(each)
                walk(f, each, skiplist)
            else
                error("cannot watch root `$each`.")
            end
        end

        fw = new{typeof(callback)}(
            Dict{String,MonitorTask}(),
            callback,
            roots,
            start_dir,
            delay,
            skiplist,
        )

        start_monitor!(fw, folders)

        for monitor in values(fw.watchers)
            schedule(monitor.task)
        end

        return fw
    end
end

struct Change
    path::String
    event::FileWatching.FileEvent
    time::UInt64
end

function default_callback(changes::Vector{Change})
    println()
    for change in sort(changes; by = x -> x.time)
        println(change.path)
    end
end

function Base.show(io::IO, fw::FolderWatcher)
    print(io, "$(FolderWatcher)(")
    if isempty(fw.watchers)
        print(io, ")")
    else
        println(io)
        for folder in sort(collect(keys(fw.watchers)))
            println(io, "  ", folder)
        end
        print(io, "])")
    end
end

function Base.close(fw::FolderWatcher)
    for monitor in values(fw.watchers)
        close(monitor)
    end
end

condition(path::String, skiplist::Set{String}) = isdir(path) && !(basename(path) in skiplist)

function walk(f::Function, dir::String, skiplist::Set{String})
    for each in readdir(dir)
        path = normpath(joinpath(dir, each))
        if condition(path, skiplist)
            f(path)
            walk(f, path, skiplist)
        end
    end
    return nothing
end

function start_monitor!(fw::FolderWatcher, folder::String)
    monitor = FileWatching.FolderMonitor(folder)
    task = Task(() -> taskfunc(fw, folder, monitor))
    fw.watchers[folder] = MonitorTask(monitor, task)
    return nothing
end

function start_monitor!(fw::FolderWatcher, folders)
    for folder in folders
        start_monitor!(fw, folder)
    end
end

function update(fw::FolderWatcher, path::String)
    if haskey(fw.watchers, path)
        if isdir(path)
            @debug "path already being watched." path
        else
            monitor = fw.watchers[path]
            close(monitor)
            delete!(fw.watchers, path)
            @debug "watched folder is missing, stop watching" path
        end
    else
        if isdir(path)
            folders = Set{String}([path])
            function f(path)
                fullpath = normpath(abspath(joinpath(path, ".")))
                push!(folders, fullpath)
            end
            walk(f, path, fw.skiplist)

            for folder in folders
                if haskey(fw.watchers, folder)
                    @debug "skipping since already watching" folder
                else
                    start_monitor!(fw, folder)
                end
            end
            for folder in folders
                monitor = fw.watchers[folder]
                schedule(monitor.task)
            end

            @debug "found new folders, watching" folders
        else
            @debug "ignoring path since not a directory and not being watched" path
        end
    end

    return nothing
end

function taskfunc(fw::FolderWatcher, folder::String, monitor::FileWatching.FolderMonitor)
    @debug "watching folder" folder
    timer_lock = ReentrantLock()
    changes_channel = Channel{Change}(Inf)
    while isopen(monitor)
        # Wait for filesystem events from the folder. We catch `EOFError`s and
        # escape the task loop since that means that the folder monitor has
        # been closed.
        fname, event = try
            wait(monitor)
        catch error
            isa(error, EOFError) && break
            rethrow(error)
        end

        # Don't allow adding new events to the channel while we are running the
        # timer otherwise we can lose events.
        lock(timer_lock) do
            if isempty(changes_channel)
                Timer(fw.delay) do timer
                    lock(timer_lock) do
                        # Capture all currently pushed FS events and run the
                        # callback. We lock here such that further events don't
                        # get discarded and instead are added to the next timer
                        # cycle.
                        changes = Change[]
                        while !isempty(changes_channel)
                            push!(changes, take!(changes_channel))
                            # Each event could cause the watch list to change,
                            # so we run an update on each event before running
                            # the callback.
                            update(fw, last(changes).path)
                        end

                        # The user callback happens here.
                        fw.callback(changes)

                        # Timers are used in a singleshot way here. Once it's
                        # been run then we start a new one for any subsequent
                        # events.
                        close(timer)
                    end
                end
            end
        end
        fullpath = joinpath(folder, fname)
        put!(changes_channel, Change(fullpath, event, time_ns()))
    end
    @debug "watcher task done" folder

    return nothing
end

end
