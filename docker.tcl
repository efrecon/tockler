package require docker::json

namespace eval ::docker {
    variable DOCKER
    if { ![info exists DOCKER] } {
        array set DOCKER {
            idGene         0
            idClamp        10000
            idFormat       7
            logger         ""
            dateLogHeader  "\[%Y%m%d %H%M%S\] \[%module%\] \[%level%\] "
            verboseTags    {1 CRITICAL 2 ERROR 3 WARN 4 NOTICE 5 INFO 6 DEBUG 7 TRACE}
            verbose        3
            logd           stderr
            -socat         "socat"
            -nc            "nc"
            -cert          ""
            -key           ""
        }
        variable version 0.3
        variable libdir [file dirname [file normalize [info script]]]
    }
    namespace export connect verbosity logger log filters
    namespace ensemble create
}

####################################################################
#
# Procedures can be called as "docker xxx" or "::docker::xxx", these are meant
# for operating on the internals of the API implementation package or as helpers
# procedures.  The most important procedure is connect, which will return an
# identifier for the connection, an identifier that should be used for all
# further operations on the connection, i.e. all calls to the Docker API.
#
####################################################################


# ::docker::connect -- Connect to docker endpoint
#
#       Creates a new connection to the docker daemon.  This will
#       return a handle that also is a command which should be used
#       for all further operations on the daemon.  The command takes a
#       number of dash-led options with values, these are:
#	-nc	Location of nc for UNIX socket encapsulation
#
# Arguments:
#	args	Dash-led options and arguments, see above.
#
# Results:
#       Returns a handle for the connection, this is a command used
#       for tk-style calling conventions.
#
# Side Effects:
#       None.
proc ::docker::connect { url args } {
    variable DOCKER

    # Create an identifier, arrange for it to be a command.
    set cx [Identifier [namespace current]::docker:]
    interp alias {} $cx {} ::docker::Dispatch $cx
    upvar \#0 $cx CX
    set CX(self) $cx
    set CX(url) $url
    # Inherit values from the arguments, make sure we pick up the
    # defaults from the main library variable.
    array set CX [array get DOCKER -*]
    foreach {k v} $args {
        set k -[string trimleft $k -]
        if { [::info exists CX($k)] } {
            set CX($k) $v
        } else {
            return -code error "$k is an unknown option"
        }
    }

    # Initialise the connection
    Init $cx

    return $cx
}


# ::docker::logger -- Set logger command
#
#       Arrange for a command to receive logging messages.  The
#       command will receive two more arguments which will be the
#       integer logging level and the message.  Lower numbers are for
#       critical messages, the higher the number is, the less
#       important it is.
#
# Arguments:
#	cmd	New log command, empty to revert to dump on stderr.
#
# Results:
#       None.
#
# Side Effects:
#       None.
proc ::docker::logger { { cmd "" } } {
    variable DOCKER
    set DOCKER(logger) $cmd
}


# ::docker::verbosity -- Get or Set verbosity
#
#       Get or set the verbosity level of the module.  By default,
#       unless this is changed, the module will be totally silent.
#       But verbosity can be turned up for debugging purposes.
#
# Arguments:
#	lvl	New level to set (a positive integer, or a recognised string)
#
# Results:
#       The resulting level that was set, or an error.  When called
#       with no argument or an empty level (or a negative level), this
#       will be returning the current level.
#
# Side Effects:
#       Will output timestamped messages on stderr, unless a log
#       command is specified.
proc ::docker::verbosity { {lvl -1} } {
    variable DOCKER

    if { $lvl >= 0 && $lvl ne "" } {
        set lvl [LogLevel $lvl]
        if { $lvl < 0 } {
            return -code error "Verbosity level $lvl not recognised"
        }
        set DOCKER(verbose) $lvl
    }
    return $DOCKER(verbose)
}



# ::docker::log -- Conditional Log output
#
#       This procedure will output the message passed as a parameter
#       if the logging level of the module is set higher than the
#       level of the message.  The level can either be expressed as an
#       integer (preferred) or a string pattern.
#
# Arguments:
#	lvl	Log level (integer or string).
#	msg	Message
#
# Results:
#       None.
#
# Side Effects:
#       Will either callback the logger command or output on stderr
#       whenever the logging level allows.
proc ::docker::log { lvl msg { module "" } } {
    variable DOCKER
    global argv0

    # Convert to integer
    set lvl [LogLevel $lvl]

    # If we should output, either pass to the global logger command or
    # output a message onto stderr.
    if { [LogLevel $DOCKER(verbose)] >= $lvl } {
        if { $module eq "" } {
            if { [catch {::info level -1} caller] } {
                # Catches all errors, but mainly when we call log from
                # toplevel of the calling stack.
                set module [file rootname [file tail $argv0]]
            } else {
                set proc [namespace which [lindex $caller 0]]
                set proc [string map [list "::" "/"] $proc]
                set module [lindex [split $proc "/"] end-1]
                if { $module eq "" } {
                    set module [file rootname [file tail $argv0]]
                }
            }
        }
        if { $DOCKER(logger) ne "" } {
            # Be sure we didn't went into problems...
            if { [catch {eval [linsert $DOCKER(logger) end \
                        $lvl $module $msg]} err] } {
                puts $DOCKER(logd) "Could not callback logger command: $err"
            }
        } else {
            # Convert the integer level to something easier to
            # understand and output onto DOCKER(logd) (which is stderr,
            # unless this has been modified)
            array set T $DOCKER(verboseTags)
            if { [::info exists T($lvl)] } {
                set log [string map [list \
                        %level% $T($lvl) \
                        %module% $module] \
                        $DOCKER(dateLogHeader)]
                set log [clock format [clock seconds] -format $log]
                append log $msg
                puts $DOCKER(logd) $log
            }
        }
    }
}


# ::docker::filters -- Create a JSON filter
#
#      A number of API calls accept a JSON filter as a query parameter.  This
#      procedure is a helper for creating properly formatted JSON for these
#      filters.  For example, calling docker filters dangling 1 would return the
#      JSON necssary to request the listing of dangling volumes, which should be
#      passed to the parameter -filter of the API call.
#
# Arguments:
#      args     even-long list of (alternating) keys and values.
#
# Results:
#      Properly JSON formatted a map[string][]string, as documented.
#
# Side Effects:
#      None.
proc ::docker::filters { args } {
    set filters {}
    foreach {k v} $args {
        dict lappend filters $k $v
    }

    set json "\{"
    dict for {k l} $filters {
        append json "\"$k\": "
        append json "\["
        foreach v $l {
            append json "\"$v\","
        }
        set json [string trimright $json ","]
        append json "\],"
    }
    set json [string trimright $json ","]
    append json "\}"
    return $json
}



####################################################################
#
# Procedures below should not be called directly, but rather via the identifier
# of the connection returned by connect, Tk-style.  Most procedures below belong
# to the "old" Docker API, i.e. before the regrouping of commands that occurred
# after version 1.13.0 of the Docker enging CLI.  The procedures are loosely
# based on the naming conventions of the regular docker CLI, but accept
# different (query) parameters, as of the API parameters instead.
#
####################################################################


# ::docker::disconnect -- Disconnects from endpoint
#
#      Disconnects an existing connection and (possibly) forget about the
#      connection.  Once the connection has been forgotten it cannot be used
#      further for accessing the Daemon.  In most cases, you do not want to keep
#      any information about the connection, the boolean is mostly for internal
#      use.
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#      keep     Keep connection in memory, do not remove object.
#
# Results:
#      None.
#
# Side Effects:
#      Disconnects the socket, possibly removing all knowledge about that
#      connection.
proc ::docker::disconnect { cx {keep 0}} {
    upvar \#0 $cx CX

    if { $CX(sock) ne "" } {
        catch {close $CX(sock)}
    }
    if { !$keep} {
        unset $cx
    }
}


# ::docker::images -- List images
#
#      Get a list of the current images available at the Daemon.
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#      args     Even-long list of query parameter to append to call
#
# Results:
#      Returns a list of dictionaries with information on the images, as
#      document in the Docker API.
#
# Side Effects:
#      None.
proc ::docker::images { cx args } {
    eval [linsert $args 0 Request $cx GET /images/json]
    array set RSP [Response $cx]
    switch -glob -- $RSP(code) {
        2* {
            return [Read $cx $RSP(meta)]
        }
        default {
            return -code error "$RSP(code): [Read $cx $RSP(meta) 0]"
        }
    }
}


# ::docker::reconnect -- Reconnects
#
#      Forcefully reconnects an existing connection
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#
# Results:
#      None.
#
# Side Effects:
#      Disconnect the socket at re-establishes connection
proc ::docker::reconnect { cx } {
    disconnect $cx 1
    Init $cx
}


# ::docker::ping -- Ping
#
#      Send a ping and return result (which should be the string OK in most
#      cases.)
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#
# Results:
#      Result of ping, the string OK when connection is working.
#
# Side Effects:
#      None.
proc ::docker::ping { cx } {
    Request $cx GET _ping
    array set RSP [Response $cx]
    switch -glob -- $RSP(code) {
        2* {
            return [Read $cx $RSP(meta) 0 0]
        }
        default {
            return -code error "$RSP(code): [Read $cx $RSP(meta) 0]"
        }
    }
}


# ::docker::containers -- List containers
#
#      Get a list of the current containers available at the Daemon.  You ought
#      to call container ls for an implementation that supports all details,
#      this is kept for backward compatibility with older code only.
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#      args     Even-long list of query parameters to append to call
#
# Results:
#      Returns a list of dictionaries with information on the running
#      containers, as document in the Docker API.
#
# Side Effects:
#      None.
proc ::docker::containers { cx args } {
    eval [linsert $args 0 Request $cx GET /containers/json]
    array set RSP [Response $cx]
    switch -glob -- $RSP(code) {
        2* {
            return [Read $cx $RSP(meta)]
        }
        default {
            return -code error "$RSP(code): [Read $cx $RSP(meta) 0]"
        }
    }
}

# ::docker::inspect -- Inspect a container
#
#      Inspect a known container available at the Daemon.  You ought to call
#      container inspect for an implementation that supports all details, this
#      is kept for backward compatibility with older code only.
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#      id       Identifier (or name) of container
#      args     Even-long list of query parameters to append to call
#
# Results:
#      Returns a dictionary with information on the container, as document in
#      the Docker API.
#
# Side Effects:
#      None.
proc ::docker::inspect { cx id args } {
    eval [linsert $args 0 Request $cx GET /containers/$id/json]
    array set RSP [Response $cx]
    switch -glob -- $RSP(code) {
        2* {
            return [Read $cx $RSP(meta)]
        }
        default {
            return -code error "$RSP(code): [Read $cx $RSP(meta) 0]"
        }
    }
}


# ::docker::top -- List processes in container
#
#      List the processes of a known container available at the Daemon.
#      You ought to call container top for an implementation that supports all
#      details, this is kept for backward compatibility with older code only.
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#      id       Identifier (or name) of container
#      args     Even-long list of query parameters to append to call
#
# Results:
#      Returns a dictionary with information on the processes, as document in
#      the Docker API.
#
# Side Effects:
#      None.
proc ::docker::top { cx id args } {
    return [eval [linsert $args 0 Get $cx $id top]]
}


# ::docker::changes -- List filesystem changes
#
#      Returns which files in a container's filesystem have been added, deleted,
#      or modified. You ought to call container changes for an implementation
#      that supports all details, this is kept for backward compatibility with
#      older code only.
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#      id       Identifier (or name) of container
#      args     Even-long list of query parameters to append to call
#
# Results:
#      Returns a dictionary with information on the changes, as documented in
#      the Docker API, or an error
#
# Side Effects:
#      None.
proc ::docker::changes { cx id args } {
    return [eval [linsert $args 0 Get $cx $id changes]]
}


# ::docker::stats -- Get container stats
#
#      Return a live stream of a container's resource usage statistics.  This
#      will arrange for a command to be called back everytime new statistics are
#      available. By default, JSON data callback is converted to Tcl
#      dictionaries for easier parsing.  When no command is provided, statistics
#      are collected once and returned.
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#      id       Identifier (or name) of container
#      cmd      Command to callback with stats (empty for no stream)
#      json     Convert JSON callback data to Tcl dict representations.
#
# Results:
#      When called with an empty command, return statistics, as documented by
#      the Docker API.
#
# Side Effects:
#      None.
proc ::docker::stats { cx id { cmd {} } { json 1 } } {
    if { $cmd ne "" } {
        Request $cx GET /containers/$id/stats stream 1
        if { $json } {
            Follow $cx [list [namespace current]::JSONify $cmd]
        } else {
            Follow $cx $cmd
        }
    } else {
        return [Get $cx $id stats stream 0]
    }
}

# ::docker::resize -- Resize a container TTY
#
#      Resize the TTY for a container. You must restart the container for the
#      resize to take effect. You ought to call container resize for an
#      implementation that supports all details, this is kept for backward
#      compatibility with older code only.
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#      id       Identifier (or name) of container
#      w        width of the tty session in characters
#      h        height of the tty session in characters
#
# Results:
#      Returns an error when return code is not 20X.
#
# Side Effects:
#      None.
proc ::docker::resize { cx id {w 80} {h 24}} {
    return [Do $cx $id resize h $h w $w]
}


# ::docker::start -- Start a container
#
#      Start a container. You ought to call container start for an
#      implementation that supports all details, this is kept for backward
#      compatibility with older code only.
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#      id       Identifier (or name) of container
#      args     Even-long list of query parameters to append to call
#
# Results:
#      Returns an error when return code is not 20X.
#
# Side Effects:
#      None.
proc ::docker::start { cx id } {
    return [eval [linsert $args 0 Do $cx $id start]]
}


# ::docker::kill -- Kill a container
#
#      Kill a container. You ought to call container kill for an
#      implementation that supports all details, this is kept for backward
#      compatibility with older code only.
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#      id       Identifier (or name) of container
#      args     Even-long list of query parameters to append to call
#
# Results:
#      Returns an error when return code is not 20X.
#
# Side Effects:
#      None.
proc ::docker::kill { cx id } {
    return [eval [linsert $args 0 Do $cx $id kill]]
}


# ::docker::pause -- Pause a container
#
#      Pause a container. You ought to call container pause for an
#      implementation that supports all details, this is kept for backward
#      compatibility with older code only.
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#      id       Identifier (or name) of container
#
# Results:
#      Returns an error when return code is not 20X.
#
# Side Effects:
#      None.
proc ::docker::pause { cx id } {
    return [Do $cx $id pause]
}


# ::docker::unpause -- Unpause a container
#
#      Unpause a container. You ought to call container unpause for an
#      implementation that supports all details, this is kept for backward
#      compatibility with older code only.
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#      id       Identifier (or name) of container
#
# Results:
#      Returns an error when return code is not 20X.
#
# Side Effects:
#      None.
proc ::docker::unpause { cx id } {
    return [Do $cx $id unpause]
}


# ::docker::stop -- Stop a container
#
#      Stop a container. You ought to call container stop for an
#      implementation that supports all details, this is kept for backward
#      compatibility with older code only.
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#      id       Identifier (or name) of container
#      t        Number of seconds to wait before kill the container, empty for Docker defaults.
#
# Results:
#      Returns an error when return code is not 20X.
#
# Side Effects:
#      None.
proc ::docker::stop { cx id {t ""}} {
    if { $t eq "" } {
        return [Do $cx $id stop]
    } else {
        return [Do $cx $id stop t $t]
    }
}


# ::docker::wait -- Wait for a container
#
#      Wait for a container. You ought to call container wait for an
#      implementation that supports all details, this is kept for backward
#      compatibility with older code only.
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#      id       Identifier (or name) of container
#      cond     Wait until container state reaches: not-running (default), next-exit, removed.
#
# Results:
#      Returns an error when return code is not 20X.
#
# Side Effects:
#      None.
proc ::docker::wait { cx id {cond ""}} {
    if { $cond eq "" } {
        return [Do $cx $id wait]
    } else {
        return [Do $cx $id wait condition $cond]
    }
}


# ::docker::restart -- Restart a container
#
#      Restart a container. You ought to call container restart for an
#      implementation that supports all details, this is kept for backward
#      compatibility with older code only.
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#      id       Identifier (or name) of container
#      t        Number of seconds to wait before kill the container, empty for Docker defaults.
#
# Results:
#      Returns an error when return code is not 20X.
#
# Side Effects:
#      None.
proc ::docker::restart { cx id {t ""}} {
    if { $t eq "" } {
        return [Do $cx $id restart]
    } else {
        return [Do $cx $id restart t $t]
    }
}


# ::docker::rename -- Rename a container
#
#      Rename a container. You ought to call container rename for an
#      implementation that supports all details, this is kept for backward
#      compatibility with older code only.
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#      id       Identifier (or name) of container
#      name     New name of the container.
#
# Results:
#      Returns an error when return code is not 20X.
#
# Side Effects:
#      None.
proc ::docker::rename { cx id name } {
    if { $name ne "" } {
        return [Do $cx $id rename name $name]
    }
}


# ::docker::attach -- Attach to container
#
#      Attach to container, see Docker API for more information about the arguments.
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#      id       Identifier (or name) of container
#      cmd      Command to callback with container output
#      args     Even-long list of query parameters to append to call
#
# Results:
#      None.
#
# Side Effects:
#      None.
proc ::docker::attach { cx id cmd args } {
    upvar \#0 $cx CX

    eval [linsert $args 0 Request $cx POST /containers/$id/attach]
    Follow $cx $cmd
}


# ::docker::exec -- Exec command inside container
#
#      This will create an exec instance inside a running container, and then
#      start the instance.  A command will be called back with the output of the
#      exec instance.
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#      id       Identifier (or name) of container
#      cmd      Command to callback with exec instance output
#      args     -stdin, -nostdin, etc (same for stderr and stdout), -tty, -notty,
#               (-i is an alias for all standard i/o)
#
# Results:
#      None.
#
# Side Effects:
#      None.
proc ::docker::exec { cx id cmd args } {
    upvar \#0 $cx CX

    # Defauts, then capture -xxx and -noxxx options into JSON booleans
    set in "false"; set out "true"; set err "false"; set tty "true"
    if { [GetOpt args -stdi] } { set in "true" };    # -stdin
    if { [GetOpt args -nostdi] } { set in "false" }
    if { [GetOpt args -stdo] } { set out "true" };   # -stdout
    if { [GetOpt args -nostdo] } { set out "false" }
    if { [GetOpt args -stde] } { set err "true" };   # -stderr
    if { [GetOpt args -nostde] } { set err "false" }
    if { [GetOpt args -t] } { set tty "true" };      # -tty
    if { [GetOpt args -not] } { set tty "false" }
    if { [GetOpt args -i] } { set in "true"; set out "true"; set err "true" }

    # Construct JSON request
    set json "\{ "
    append json "\"AttachStdin\": $in, "
    append json "\"AttachStdout\": $out, "
    append json "\"AttachStderr\": $err, "
    append json "\"Tty\": $tty, "
    # Consider the incoming command to be a valid Tcl-list and construct a JSON
    # array from it.
    foreach c $cmd {
        append jcmd "\"$c\", "
    }
    set jcmd [string trimright $jcmd " ,"]
    append json "\"Cmd\": \[ $jcmd \] "
    append json "\}"

    # Now perform JSON request and parse response. This is to CREATE (and not
    # yet execute) and execution context, according to the API manual.
    # https://docs.docker.com/engine/reference/api/docker_remote_api_v1.24/#/exec-create
    RequestJSON $cx POST /containers/$id/exec $json {}
    array set RSP [Response $cx]
    switch -glob -- $RSP(code) {
        2* {
            # On successfull execution context creation, capture if the caller
            # wished to be notified through callbacks. If not, we'll capture
            # output and return it.
            array set RES [Read $cx $RSP(meta)]
            GetOpt args -callback -value cb -default ""
            unset RSP;  # Will be reused just below, not entirely cleancode...

            # Now start the execution context and capture output or provide
            # callback with output.
            set json "\{ \"Detach\": false \}"
            RequestJSON $cx POST /exec/$RES(Id)/start $json {}
            if { $cb eq "" } {
                set r [Identifier [namespace current]::result:]
                upvar \#0 $r RS
                set RS(stdout) ""
                set RS(stderr) ""
                set RS(done) 0
                Follow $cx [list [namespace current]::Collect $r]
                vwait ${r}(done)

                if { $RS(stderr) ne "" } {
                    set res $RS(stderr)
                } else {
                    set res $RS(stdout)
                }
                unset $r
                return $res
            } else {
                Follow $cx $cb
            }
        }
        default {
            return -code error "$RSP(code): [Read $cx $RSP(meta) 0]"
        }
    }
    return ""
}



####################################################################
#
# Procedures below should not be called directly, but rather via the identifier
# of the connection returned by connect, Tk-style.  These procedures follow
# loosely the same naming conventions as of the re-grouping of commands (into
# sub-commands) that occurred after version 1.13.0 was released.  Users are
# encouraged to use this new set of commands for the sake of clarity, but also
# because older implementations (above) are depreceted.
#
####################################################################



# ::docker::container -- descr
#
#      descr
#
# Arguments:
#      cx       descr
#      cmd      descr
#      args     descr
#
# Results:
#      None.
#
# Side Effects:
#      None.
proc ::docker::container { cx cmd args } {
    upvar \#0 $cx CX

    # Not ready yet, but almost inline with new API structuring (everything
    # behind the container sub-command)
    set cmd [string tolower $cmd]
    switch -- $cmd {
        "ls" {
            QueryHeaders args params
            return [APICall $cx -rest GET -namespace containers -op json -- {*}$params]
        }
        "create" {
            # container create -name /hello -- {<JSON>}
            QueryHeaders args params
            return [APICall $cx -rest POST -namespace containers -op $cmd -json $args \
                    -- {*}$params]
        }
        "update" {
            QueryHeaders args params
            return [APICall $cx -rest POST -namespace containers -op $cmd -id [lindex $args 0] -json [lrange $args 1 end] \
                    -- {*}$params]
        }
        "inspect" {
            QueryHeaders args params
            return [APICall $cx -rest GET -namespace containers -id [lindex $args 0] -op json \
                    -- {*}$params]
        }
        "logs" {
            QueryHeaders args params
            set lines [APICall $cx -rest GET -namespace containers -id [lindex $args 0] -op $cmd -raw-stream \
                    -- {*}$params]
            # Arrange to clean every line and make sure we return a list of lines.
            return [split [string trim $lines] "\n"]
        }
        "stats" {
            QueryHeaders args params
            return [APICall $cx -rest GET -namespace containers -id [lindex $args 0] -op $cmd -stream [lindex $args 1] \
                    -- {*}$params]
        }
        "top" -
        "changes" {
            QueryHeaders args params
            return [APICall $cx -rest GET -namespace containers -id [lindex $args 0] -op $cmd \
                    -- {*}$params]
        }
        "resize" -
        "start" -
        "stop" -
        "restart" -
        "kill" -
        "rename" -
        "pause" -
        "unpause" -
        "wait" {
            QueryHeaders args params
            return [APICall $cx -rest POST -namespace containers -id [lindex $args 0] -op $cmd \
                    -- {*}$params]
        }
        "update" {
            QueryHeaders args params
            return [APICall $cx -rest POST -namespace containers -id [lindex $args 0] -op update -json $args \
                    -- {*}$params]
        }
        "rm" -
        "delete" {
            QueryHeaders args params
            return [APICall $cx -rest DELETE -namespace containers -id [lindex $args 0] \
                    -- {*}$params]
        }
        "prune" {
            # container prune -filters [docker filters until 1h30m]
            QueryHeaders args params
            return [APICall $cx -rest POST -namespace containers -op prune \
                    -- {*}$params]
        }
    }
}


# ::docker::image -- descr
#
#      descr
#
# Arguments:
#      cx       descr
#      cmd      descr
#      args     descr
#
# Results:
#      None.
#
# Side Effects:
#      None.
proc ::docker::image { cx cmd args } {
    upvar \#0 $cx CX

    # Not ready yet, but almost inline with new API structuring (everything
    # behind the container sub-command)
    set cmd [string tolower $cmd]
    switch -- $cmd {
        "ls" {
            QueryHeaders args params headers
            return [APICall $cx -rest GET -namespace images -op json -- {*}$params]
        }
        "create" {
            QueryHeaders args params headers
            return [APICall $cx -rest POST -namespace images -op create -headers $headers \
                    -- {*}$params]
        }
        "inspect" {
            return [APICall $cx -rest GET -namespace images -id [lindex $args 0] -op json]
        }
        "history" {
            return [APICall $cx -rest GET -namespace images -id [lindex $args 0] -op history]
        }
        "search" {
            QueryHeaders args params
            return [APICall $cx -rest GET -namespace images -op $cmd \
                    -- {*}$params]
        }
        "push" -
        "tag" {
            QueryHeaders args params headers
            return [APICall $cx -rest POST -namespace images -id [lindex $args 0] -op $cmd -headers $headers \
                    -- {*}$params]
        }
        "rm" -
        "delete" {
            QueryHeaders args params
            return [APICall $cx -rest DELETE -namespace images -id [lindex $args 0] \
                    -- {*}$params]
        }
        "prune" {
            # image prune -filters [docker filters dangling 1]
            QueryHeaders args params headers
            return [APICall $cx -rest POST -namespace images -op prune \
                    -- {*}$params]
        }
    }
}


# ::docker::service -- descr
#
#      descr
#
# Arguments:
#      cx       descr
#      cmd      descr
#      args     descr
#
# Results:
#      None.
#
# Side Effects:
#      None.
proc ::docker::service { cx cmd args } {
    upvar \#0 $cx CX

    switch -- [string tolower $cmd] {
        "ls" {
            # service ls
            # service ls -filters [docker filters name "top"]
            QueryHeaders args params
            return [APICall $cx -rest GET -namespace services -- {*}$params]
        }
        "create" {
            # service create -X-Registry-Auth XXX -version 23 -- {"Name": "top",...}
            QueryHeaders args params headers
            return [APICall $cx -rest POST -namespace services -op create -json $args -headers $headers \
                    -- {*}$params]
        }
        "inspect" {
            # service inspect -insertDefaults true -- hopeful_cori
            QueryHeaders args params
            return [APICall $cx -rest GET -namespace services -id [lindex $args 0] \
                    -- {*}$params]
        }
        "rm" -
        "delete" {
            QueryHeaders args params headers
            return [APICall $cx -rest DELETE -namespace services -id [lindex $args 0] -headers $headers \
                    -- {*}$params]
        }
        "update" {
            QueryHeaders args params headers
            return [APICall $cx -rest POST -namespace services -id [lindex $args 0] -op update -json $args -headers $headers \
                    -- {*}$params]
        }
    }
}


# ::docker::secret -- descr
#
#      descr
#
# Arguments:
#      cx       descr
#      cmd      descr
#      args     descr
#
# Results:
#      None.
#
# Side Effects:
#      None.
proc ::docker::secret { cx cmd args } {
    upvar \#0 $cx CX

    switch -- [string tolower $cmd] {
        "ls" {
            QueryHeaders args params
            return [APICall $cx -rest GET -namespace secrets -- {*}$params]
        }
        "create" {
            QueryHeaders args params
            return [APICall $cx -rest POST -namespace secrets -op create -json $args \
                    -- {*}$params]
        }
        "inspect" {
            # secret inspect -- my_secret
            QueryHeaders args params
            return [APICall $cx -rest GET -namespace secrets -id [lindex $args 0] \
                    -- {*}$params]
        }
        "rm" -
        "delete" {
            QueryHeaders args params
            return [APICall $cx -rest DELETE -namespace secrets -id [lindex $args 0] \
                    -- {*}$params]
        }
        "update" {
            QueryHeaders args params
            return [APICall $cx -rest POST -namespace secrets -id [lindex $args 0] -op update -json $args \
                    -- {*}$params]
        }
    }
}


# ::docker::config -- descr
#
#      descr
#
# Arguments:
#      cx       descr
#      cmd      descr
#      args     descr
#
# Results:
#      None.
#
# Side Effects:
#      None.
proc ::docker::config { cx cmd args } {
    upvar \#0 $cx CX

    switch -- [string tolower $cmd] {
        "ls" {
            QueryHeaders args params
            return [APICall $cx -rest GET -namespace configs -- {*}$params]
        }
        "create" {
            QueryHeaders args params
            return [APICall $cx -rest POST -namespace configs -op create -json $args \
                    -- {*}$params]
        }
        "inspect" {
            # secret inspect -- my_config
            QueryHeaders args params
            return [APICall $cx -rest GET -namespace configs -id [lindex $args 0] \
                    -- {*}$params]
        }
        "rm" -
        "delete" {
            QueryHeaders args params
            return [APICall $cx -rest DELETE -namespace configs -id [lindex $args 0] \
                    -- {*}$params]
        }
        "update" {
            QueryHeaders args params
            return [APICall $cx -rest POST -namespace configs -id [lindex $args 0] -op update -json $args \
                    -- {*}$params]
        }
    }
}


# ::docker::node -- descr
#
#      descr
#
# Arguments:
#      cx       descr
#      cmd      descr
#      args     descr
#
# Results:
#      None.
#
# Side Effects:
#      None.
proc ::docker::node { cx cmd args } {
    upvar \#0 $cx CX

    switch -- [string tolower $cmd] {
        "ls" {
            # node ls -filters [docker filters role manager]
            QueryHeaders args params
            return [APICall $cx -rest GET -namespace nodes -- {*}$params]
        }
        "inspect" {
            QueryHeaders args params
            return [APICall $cx -rest GET -namespace nodes -id [lindex $args 0] \
                    -- {*}$params]
        }
        "rm" -
        "delete" {
            QueryHeaders args params
            return [APICall $cx -rest DELETE -namespace nodes -id [lindex $args 0] \
                    -- {*}$params]
        }
        "update" {
            QueryHeaders args params
            return [APICall $cx -rest POST -namespace nodes -id [lindex $args 0] -op update -json $args \
                    -- {*}$params]
        }
    }
}


# ::docker::network -- descr
#
#      descr
#
# Arguments:
#      cx       descr
#      cmd      descr
#      args     descr
#
# Results:
#      None.
#
# Side Effects:
#      None.
proc ::docker::network { cx cmd args } {
    upvar \#0 $cx CX

    set cmd [string tolower $cmd]
    switch -- $cmd {
        "ls" {
            QueryHeaders args params
            return [APICall $cx -rest GET -namespace networks -- {*}$params]
        }
        "inspect" {
            QueryHeaders args params
            return [APICall $cx -rest GET -namespace networks -id [lindex $args 0] \
                    -- {*}$params]
        }
        "rm" -
        "delete" {
            QueryHeaders args params
            return [APICall $cx -rest DELETE -namespace networks -id [lindex $args 0] \
                    -- {*}$params]
        }
        "disconnect" -
        "connect" {
            QueryHeaders args params
            return [APICall $cx -rest POST -namespace networks -id [lindex $args 0] -op $cmd \
                    -- {*}$params]
        }
        "prune" {
            QueryHeaders args params
            return [APICall $cx -rest POST -namespace networks -op prune \
                    -- {*}$params]
        }
    }
}


# ::docker::task -- descr
#
#      descr
#
# Arguments:
#      cx       descr
#      cmd      descr
#      args     descr
#
# Results:
#      None.
#
# Side Effects:
#      None.
proc ::docker::task { cx cmd args } {
    upvar \#0 $cx CX

    switch -- [string tolower $cmd] {
        "ls" {
            return [APICall $cx -rest GET -namespace tasks -- {*}$args]
        }
        "inspect" {
            QueryHeaders args params
            return [APICall $cx -rest GET -namespace tasks -id [lindex $args 0] \
                    -- {*}$params]
        }
    }
}


# ::docker::volume -- descr
#
#      descr
#
# Arguments:
#      cx       descr
#      cmd      descr
#      args     descr
#
# Results:
#      None.
#
# Side Effects:
#      None.
proc ::docker::volume { cx cmd args } {
    upvar \#0 $cx CX

    switch -- [string tolower $cmd] {
        "ls" {
            QueryHeaders args params
            return [APICall $cx -rest GET -namespace volumes -- {*}$params]
        }
        "create" {
            QueryHeaders args params
            return [APICall $cx -rest POST -namespace volumes -op create -json $args \
                    -- {*}$params]
        }
        "inspect" {
            # secret inspect -- my_secret
            QueryHeaders args params
            return [APICall $cx -rest GET -namespace volumes -id [lindex $args 0] \
                    -- {*}$params]
        }
        "rm" -
        "delete" {
            QueryHeaders args params
            return [APICall $cx -rest DELETE -namespace volumes -id [lindex $args 0] \
                    -- {*}$params]
        }
        "prune" {
            QueryHeaders args params
            return [APICall $cx -rest POST -namespace volumes -op prune \
                    -- {*}$params]
        }
    }
}



####################################################################
#
# Procedures below are internal to the implementation, they shouldn't
# be changed unless you wish to help...
#
####################################################################


# ::docker::URLinit -- Initialise encoding tables
#
#      Initialise map for URL encoding codes.
#
# Arguments:
#      None.
#
# Results:
#      None.
#
# Side Effects:
#      Stores encoding map in variable global to this namespace.
proc ::docker::URLinit {} {
    variable map
    variable alphanumeric a-zA-Z0-9
    for {set i 0} {$i <= 256} {incr i} {
        set c [format %c $i]
        if {![string match \[$alphanumeric\] $c]} {
            set map($c) %[format %.2x $i]
        }
    }
    # These are handled specially
    array set map { " " + \n %0d%0a }
}


# ::docker::URLencode -- URL encode a string.
#
#      Encode a string so that it complies to the set of characters that are
#      allowed in URLs.
#
# Arguments:
#      string   String to encode
#
# Results:
#      Encoded representation of the string
#
# Side Effects:
#      None.
proc ::docker::URLencode {string} {
    variable map
    variable alphanumeric

    if { ![info exists map]} {
        URLinit
    }

    # The spec says: "non-alphanumeric characters are replaced by '%HH'"
    # 1 leave alphanumerics characters alone
    # 2 Convert every other character to an array lookup
    # 3 Escape constructs that are "special" to the tcl parser
    # 4 "subst" the result, doing all the array substitutions

    regsub -all \[^$alphanumeric\] $string {$map(&)} string
    # This quotes cases like $map([) or $map($) => $map(\[) ...
    regsub -all {[][{})\\]\)} $string {\\&} string
    return [subst -nocommand $string]
}


# ::docker::URLdecode -- URL decode
#
#      Decode a string from the set of characters that are allowed in URL into
#      their original form.
#
# Arguments:
#      str     String to decode
#
# Results:
#      Decoded string
#
# Side Effects:
#      None.
proc ::docker::URLdecode { str } {
    # rewrite "+" back to space
    # protect \ from quoting another '\'
    set str [string map [list + { } "\\" "\\\\"] $str]

    # prepare to process all %-escapes
    regsub -all -- {%([A-Fa-f0-9][A-Fa-f0-9])} $str {\\u00\1} str

    # process \u unicode mapped chars
    return [subst -novar -nocommand $str]
}


# ::docker::PullOpts -- Separate options from arguments
#
#      In its deterministic form, this will separate options from arguments
#      using the double-dash in argument lists of procedure calls (or similar).
#      Everything that is before the double-dash is considered to be options,
#      while remaining is arguments.  When no double-dash is present, the first
#      non dash-led argument is considered to mark the start of arguments and
#      options are everything that is placed before.  In that case, options need
#      to come in pairs, i.e. an option followed by a value.
#
# Arguments:
#      _argv    "Pointer" to incoming arguments.
#      _opts    "Pointer" to (resulting) list of options
#
# Results:
#      None.
#
# Side Effects:
#      Will actively pull the options from the list of arguments and modify the
#      list of arguments on behalf of the caller.
proc ::docker::PullOpts { _argv _opts } {
    upvar $_argv argv $_opts opts

    set opts {}
    set ddash [lsearch $argv "--"]
    if { $ddash >= 0 } {
        # Double dash is always on the safe-side.
        set opts [lrange $argv 0 [expr {$ddash-1}]]
        set argv [lrange $argv [expr {$ddash+1}] end]
    } else {
        # Otherwise, we give it a good guess, i.e. first non-dash-led
        # argument is the start of the arguments.
        set i 0
        while { $i < [llength $argv] } {
            set lead [string index [lindex $argv $i] 0]
            if { $lead eq "-" } {
                set next [string index [lindex $argv [expr {$i+1}]] 0]
                if { $next eq "-" } {
                    incr i
                } elseif { $next eq "" } {
                    set opts $argv
                    set argv [list]
                    return
                } else {
                    incr i 2
                }
            } else {
                break
            }
        }
        set opts [lrange $argv 0 [expr {$i-1}]]
        set argv [lrange $argv $i end]
    }
}


# ::docker::GetOpt -- Quick options parser
#
#       Parses options (and their possible) values from an option list. The
#       parser provides full introspection. The parser accepts itself a number
#       of dash-led options, which are:
#	    -value   Which variable to store the value given to the option in.
#	    -option  Which variable to store which option (complete) was parsed.
#	    -default Default value to give when option not present.
#
# Arguments:
#	_argv	Name of option list in caller's context
#	name	Name of option to extract (first match, can be incomplete)
#	args	Additional arguments
#
# Results:
#       Returns 1 when a matching option was found and parsed away from the
#       option list, 0 otherwise
#
# Side Effects:
#       Modifies the option list to enable being run in loops.
proc ::docker::GetOpt {_argv name args } {
    # Get options to the option parsing procedure...
    array set OPTS {
        -value  ""
        -option ""
    }
    if { [string index [lindex $args 0] 0] ne "-" } {
        # Backward compatibility with old code! arguments that follow the name
        # of the option to parse are possibly the name of the variable where to
        # store the value and possibly a default value when the option isn't
        # found.
        set OPTS(-value) [lindex $args 0]
        if { [llength $args] > 1 } {
            set OPTS(-default) [lindex $args 1]
        }
    } else {
        array set OPTS $args
    }

    # Access where the options are stored and possible where to store
    # side-results.
    upvar $_argv argv
    if { $OPTS(-value) ne "" } {
        upvar $OPTS(-value) var
    }
    if { $OPTS(-option) ne "" } {
        upvar $OPTS(-option) opt
    }
    set opt "";  # Default is no option was extracted
    set pos [lsearch -regexp $argv ^$name]
    if {$pos>=0} {
        set to $pos
        set opt [lindex $argv $pos];  # Store the option we extracted
        # Pick the value to the option, if relevant
        if {$OPTS(-value) ne ""} {
            set var [lindex $argv [incr to]]
        }
        # Remove option (and possibly its value from list)
        set argv [lreplace $argv $pos $to]
        return 1
    } else {
        # Did we provide a value to default?
        if { [info exists OPTS(-default)] } {
            set var $OPTS(-default)
        }
        return 0
    }
}


# ::docker::LogLevel -- Convert log levels
#
#       For convenience, log levels can also be expressed using
#       human-readable strings.  This procedure will convert from this
#       format to the internal integer format.
#
# Arguments:
#	lvl	Log level (integer or string).
#
# Results:
#       Log level in integer format, -1 if it could not be converted.
#
# Side Effects:
#       None.
proc ::docker::LogLevel { lvl } {
    variable DOCKER

    if { ![string is integer $lvl] } {
        foreach {l str} $DOCKER(verboseTags) {
            if { [string match -nocase $str $lvl] } {
                return $l
            }
        }
        return -1
    }
    return $lvl
}


# ::docker::Dispatch -- Library dispatcher
#
#       This is the dispatcher that is used to offer a tk-style
#       object-like API for the library on the database objects
#       created by ::docker::create.
#
# Arguments:
#	db	Identifier of the database
#	method	Method to call (i.e. one of our recognised procs)
#	args	Arguments to pass to the procedure after the DB identifier.
#
# Results:
#      Whatever is returned by the called procedure.
#
# Side Effects:
#       None.
proc ::docker::Dispatch { cx method args } {
    if { [string match \[a-z\] [string index $method 0]] } {
        if { [info commands [namespace current]::$method] eq "" } {
            return -code error "Bad method $method!"
        }
    } else {
        return -code error "Bad method $method!"
    }
    if {[catch {eval [linsert $args 0 $method $cx]} msg]} {
        return -code error $msg
    }
    return $msg
}


# ::docker::Identifier -- Create an identifier
#
#       Create a unique identifier within this namespace.
#
# Arguments:
#	pfx	String to prefix to the name of the identifier
#
# Results:
#       A unique identifier
#
# Side Effects:
#       None.
proc ::docker::Identifier { {pfx "" } } {
    variable DOCKER

    set unique [incr DOCKER(idGene)]
    ::append unique [expr {[clock clicks -milliseconds] % $DOCKER(idClamp)}]
    return [format "${pfx}%.$DOCKER(idFormat)d" $unique]
}


# ::docker::Init -- Initialise connection
#
#      Initialise connection by opening the relevant sockets or file descriptors
#      to start communicating with the (remote) Docker host.  How to open the
#      connection is based on the scheme of the URL. unix:// is for
#      communication to the local host, tcp:// or http:// are for communication
#      using sockets, and https:// is the same, but encrypted, possibly using
#      client certificate and key.  Since Tcl does not have internal support for
#      UNIX domain sockets, unix:// uses either socat (preferred) or nc to
#      establish the connection to the local daemon. This has the drawback of
#      requiring an extraneous process for each connection opened to the Docker
#      daemon.
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#
# Results:
#      Return the channel where to communicate with the daemon at (socket or
#      file descriptor); or generate an error.
#
# Side Effects:
#      Create subprocesses, or open sockets depending on the URL.
proc ::docker::Init { cx } {
    variable DOCKER

    upvar \#0 $cx CX

    set CX(sock) ""
    set sep [string first "://" $CX(url)]
    set scheme [string range $CX(url) 0 [expr {$sep-1}]]
    switch -nocase -- $scheme {
        "unix" {
            # Extract path to domain socket
            set domain [string range $CX(url) [expr {$sep+3}] end]

            # First try opening using socat, this will fail gently if
            # we could not find socat or socat actually failed.
            if { $CX(-socat) ne "" } {
                set socat [auto_execok $CX(-socat)]
                if { $socat ne "" } {
                    if {[catch {open "|$socat UNIX-CLIENT:$domain -" r+} s]} {
                        log WARN "Cannot open UNIX socket from $domain\
                                with $socat: $s"
                    } else {
                        log INFO "Opened UNIX socket at $domain using $socat"
                        set CX(sock) $s
                    }
                } else {
                    log NOTICE "Cannot find binary for socat"
                }
            }

            # Now try nc
            if { $CX(sock) eq "" && $CX(-nc) ne "" } {
                set nc [auto_execok $CX(-socat)]
                if { $nc ne "" } {
                    if {[catch {open "|$nc -U $domain" r+} s]} {
                        log WARN "Cannot open UNIX socket from $domain\
                                with $nc: $s"
                    } else {
                        log INFO "Opened UNIX socket at $domain using $nc"
                        set CX(sock) $s
                    }
                } else {
                    log NOTICE "Cannot find binary for nc"
                }
            }

            # If we still haven't got a socket, then send back an
            # error as we won't be able to continue...
            if { $CX(sock) eq "" } {
                return -code error \
                        "Cannot open UNIX socket at $domain using external binaries"
            }
        }
        "http" -
        "tcp" {
            set location [string range $CX(url) [expr {$sep+3}] end]
            foreach { host port } [split [string trimright $location /] ":"] break
            if { $port eq "" } {
                set port 2375
            }
            set CX(sock) [socket $host $port]
        }
        "https" {
            if { [catch {package require tls} ver] } {
                return -code error "Cannot find package TLS: $ver"
            }
            set location [string range $CX(url) [expr {$sep+3}] end]
            foreach { host port } [split [string trimright $location /] ":"] break
            if { $port eq "" } {
                set port 2376
            }
            set CX(sock) [::tls::socket -certfile $CX(-cert) -keyfile $CX(-key) $host $port]
        }
    }

    return $CX(sock)
}


# ::docker::Host -- Host for connection
#
#      Compute the hostname for a connection
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#
# Results:
#      Return the hostname that can be found in the URL, when it contains one.
#
# Side Effects:
#      None.
proc ::docker::Host { cx } {
    upvar \#0 $cx CX

    # Figure out the Host we are talking to, this is important as new docker
    # daemons are picky about the presence of the header.
    set sep [string first "://" $CX(url)]
    set scheme [string range $CX(url) 0 [expr {$sep-1}]]
    set host ""
    if { $scheme eq "tcp" || [string match "http*" $scheme] } {
        set location [string range $CX(url) [expr {$sep+3}] end]
        foreach { host port } [split [string trimright $location /] ":"] break
    }

    return $host
}


# ::docker::Request -- Perform HTTP request
#
#      Generate an HTTP REST request on the channel associated to a Docker
#      daemon connection.
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#      op       HTTP operation to request (GET, PUT, POST, etc)
#      path     Path to request
#      args     Even-long list of keys and values, to form qury.
#
# Results:
#      None.
#
# Side Effects:
#      Writes well-formed HTTP request on channel.
proc ::docker::Request { cx op path args } {
    upvar \#0 $cx CX

    fconfigure $CX(sock) -buffering full
    set req ""
    if { [llength $args] > 0 } {
        set req "?"
        foreach {k v} $args {
            append req "${k}=[URLencode $v]&"
        }
        set req [string trimright $req "&"]
    }
    log DEBUG "Requesting $op /[string trimleft $path /]$req"
    puts $CX(sock) "$op /[string trimleft $path /]$req HTTP/1.1"
    puts $CX(sock) "Host: [Host $cx]"
    puts $CX(sock) ""
    flush $CX(sock)
}


# ::docker::RequestJSON -- Perform HTTP request with JSON content
#
#      Generate an HTTP REST request on the channel associated to a Docker
#      daemon connection.  This is able to add specific HTTP headers, and to
#      form the query.
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#      op       HTTP operation to request (GET, PUT, POST, etc)
#      path     Path to request
#      json     JSON to (typically) POST/PUT.
#      hdrs     Even-long list of additional headers (keys and values)
#      args     Even-long list of keys and values, to form qury.
#
# Results:
#      None.
#
# Side Effects:
#      Writes well-formed HTTP request on channel.
proc ::docker::RequestJSON { cx op path json hdrs args } {
    upvar \#0 $cx CX

    fconfigure $CX(sock) -buffering full
    set req ""
    if { [llength $args] > 0 } {
        set req "?"
        foreach {k v} $args {
            append req "${k}=[URLencode $v]&"
        }
        set req [string trimright $req "&"]
    }
    log DEBUG "Requesting $op /[string trimleft $path /]$req with JSON $json"
    puts $CX(sock) "$op /[string trimleft $path /]$req HTTP/1.1"
    puts $CX(sock) "Host: [Host $cx]"
    foreach {k v} $hdrs {
        puts $CX(sock) "${k}: $v"
    }
    puts $CX(sock) "Content-Type: application/json"
    puts $CX(sock) "Content-Length: [string length $json]"
    puts $CX(sock) ""
    puts -nonewline $CX(sock) $json
    flush $CX(sock)
}


# ::docker::Response -- Read start of HTTP response
#
#      Read start of HTTP response sent from Docker daemon.  This parses the
#      code and message, and continues reading possible headers until the marker
#      of resonse start.
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#
# Results:
#      Even-long list representing the response as keys and values.  Known keys
#      are version for the HTTP protocol version, code for the code, msg for the
#      HTTP message and meta, that will represent the headers as yet another
#      even-long list of keys and values.
#
# Side Effects:
#      Read resonse line by line.
proc ::docker::Response { cx } {
    upvar \#0 $cx CX

    set response [gets $CX(sock)]
    array set RSP {}
    if { [regexp {HTTP/(\d+.\d)\s+(\d+)\s+(.*)} $response \
                m RSP(version) RSP(code) RSP(msg)] } {
        set meta ""
        while 1 {
            set line [string trim [gets $CX(sock)]]
            if { $line eq "" } {
                break
            }
            foreach {k v} [split $line ":"] break
            append meta "[string trim $k]=[string trim $v] "
            lappend RSP(meta) [string trim $k] [string trim $v]
        }
        log TRACE "Response $RSP(code) : [string trim $meta]"
    } else {
        return -code error "Cannot understand response: $response"
    }
    return [array get RSP]
}

proc ::docker::String2Hex {string} {
    set where 0
    set res {}
    while {$where<[string length $string]} {
        set str [string range $string $where [expr $where+15]]
        if {![binary scan $str H* t] || $t==""} break
        regsub -all (....) $t {\1 } t4
        regsub -all (..) $t {\1 } t2
        set asc ""
        foreach i $t2 {
            scan $i %2x c
            append asc [expr {$c>=32 && $c<=127? [format %c $c]: "."}]
        }
        lappend res [format "%7.7x: %-42s %s" $where $t4  $asc]
        incr where 16
    }
    join $res \n
}


# ::docker::Data -- Read exact bytes
#
#      Read exact number of bytes out of (stream) from connection to remote
#      Docker daemon, typically while consuming blocks of chunk encoded data.
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#      len      Number of bytes to read from socket
#
# Results:
#      Content of data buffer read
#
# Side Effects:
#      Read (and block) from socket to server
proc ::docker::Data { cx len {stream 0} } {
    upvar \#0 $cx CX

    fconfigure $CX(sock) -translation binary
    if { $stream } {
        set dta [Stream $cx]
    } else {
        set dta [read $CX(sock) $len]
    }
    log TRACE "Read [string length $dta] bytes from $CX(sock), starting with [string range $dta 0 40]"
    return $dta
}


# ::docker::Chunks -- Read chunks
#
#      Read chunks sent back as part of the response from the Docker daemon.
#      When a command is provided, it will be called back with the content of
#      each chunk, including an ending (last) empty chunk.
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#      cmd      Command to callback with content of chunks
#
# Results:
#      When no command is provided, return the concatenated content of all
#      chunks that were answered back by the daemon.
#
# Side Effects:
#      Read (and block) on chunk consumption
proc ::docker::Chunks { cx { stream 0 } { cmd {} } } {
    upvar \#0 $cx CX

    if { [llength $cmd] } {
        set chunk [Chunk $cx $stream]
        # Pass empty chunks to signal end of stream
        if { [catch {eval [linsert $cmd end $chunk]} err] } {
            log WARN "Cannot push back data: $err"
        }
    } else {
        set dta ""
        while 1 {
            set chunk [Chunk $cx $stream]
            if { [string length $chunk] == 0 } {
                break
            } else {
                if { [llength $cmd] } {
                    if { [catch {eval [linsert $cmd end $chunk]} err] } {
                        log WARN "Cannot push back data: $err"
                    }
                } elseif {$stream} {
                    append dta ${chunk}\n
                } else {
                    append dta $chunk
                }
            }
        }

        # Skip footer
        while 1 {
            set l [gets $CX(sock)]
            if { $l eq "" } {
                break
            }
        }

        return $dta
    }
}


# ::docker::Chunk -- Read content of one chunk
#
#      Read and return content of a single data chunk.
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#
# Results:
#      Return content of chunk
#
# Side Effects:
#      Read header and length of chunk out of header.
proc ::docker::Chunk { cx {stream 0} } {
    upvar \#0 $cx CX

    set dta ""
    if { [gets $CX(sock) hdr] >= 0 } {
        # Split header to access the hex size
        foreach sz [split $hdr ";"] break
        # Convert hex len in decimal, if found
        if { [catch {scan $sz %x len}] == 0 && $len > 0 } {
            set dta [Data $cx $len $stream]
            fconfigure $CX(sock) -translation auto
            gets $CX(sock)
        }

    }
    return $dta
}


# ::docker::Collect -- Collect streamed content
#
#      Collect and append data content
#
# Arguments:
#      r        Collection object
#      type     Type of payload
#      payload  Data to colled
#
# Results:
#      None.
#
# Side Effects:
#      None.
proc ::docker::Collect { r type payload } {
    upvar \#0 $r RS

    if { $type eq "error" } {
        set RS(done) 1
        return
    }

    if { [info exists RS($type)] } {
        append RS($type) [string trimright $payload]\n
    }
}


# ::docker::Stream -- Read Docker streams
#
#      This reads streams used when attaching (for example) to the output of a
#      container. The procedure implements the documented format for these
#      streams and triggers a callback with the type and payload of each (line)
#      of content being read.
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#      cmd      Command to callback, type and payload will be appended
#
# Results:
#      None.
#
# Side Effects:
#      Read one message from the channel.
proc ::docker::Stream { cx {cmd {}} } {
    upvar \#0 $cx CX

    set hdr [read $CX(sock) 8]
    if { [string length $hdr] == 8 } {
        binary scan $hdr cucucucuIu type a b c size
        array set T {0 stdin 1 stdout 2 stderr}
        set payload [string trim [read $CX(sock) $size]]
        if { [llength $cmd] } {
            if { [catch {eval [linsert $cmd end $T($type) $payload]} err] } {
                log WARN "Cannot push back payload: $err"
            }
        } else {
            return $payload
        }
    } else {
        log WARN "Cannot read from socket!"
        fileevent $CX(sock) readable {}
        if { [llength $cmd] } {
            if { [catch {eval [linsert $cmd end error \
                        "Cannot read from socket"]} err] } {
                log WARN "Cannot mediate error: $err"
            }
        }
    }
    return ""
}


# ::docker::Follow -- Read response and Follow (stream) content
#
#      Arrange to read a response from the Docker daemon and follow the stream
#      of response by providing a callback for every message or chunk received.
#      This implementation is aware of the various type of content declared as
#      part of the header of the answer.
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#      cmd      Command to callback
#
# Results:
#      None.
#
# Side Effects:
#      None.
proc ::docker::Follow { cx cmd } {
    return [Consume $cx [Response $cx] $cmd]
}

proc ::docker::Consume { cx response cmd } {
    upvar \#0 $cx CX

    array set RSP $response
    switch -glob -- $RSP(code) {
        101 -
        2* {
            array set META $RSP(meta)
            if { [info exists META(Content-Type)] } {
                switch -glob -- $META(Content-Type) {
                    "application/vnd.docker.raw-stream*" {
                        fconfigure $CX(sock) -encoding binary -translation binary
                        fileevent $CX(sock) readable [list [namespace current]::Stream $cx $cmd]
                    }
                    "text/plain*" {
                        fileevent $CX(sock) readable [list [namespace current]::Chunks $cx 0 $cmd]
                    }
                }
            } elseif { [info exists META(Transfer-Encoding)] } {
                switch -glob -- $META(Transfer-Encoding) {
                    "chunked" {
                        fileevent $CX(sock) readable [list [namespace current]::Chunks $cx 0 $cmd]
                    }
                }
            }

        }
    }
}

# ::docker::JSONify -- JSON parsed callback
#
#      Assumes incoming data is in JSON format, parse the JSON into
#      Tcl-compatible dictionary (equivalent) representations and perform
#      command callback.  This procedure is perhaps wrongly named as its main
#      goal is to parse JSON content.
#
# Arguments:
#      cmd      Command to callback.
#      dta      Raw JSON content
#
# Results:
#      None.
#
# Side Effects:
#      None.
proc ::docker::JSONify { cmd dta } {
    if { $dta ne "" } {
        eval [linsert $cmd end [::docker::json::parse [string trim $dta]]]
    }
}


# ::docker::Read -- Read remaining data from response
#
#      Read remaining data from reponse based on the headers.  This will
#      recognise chunk encoded answers and arrange to read and concatenate them
#      in one go.
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#      meta     Meta information read from beginning of response.
#      json     Should we convert JSON?
#
# Results:
#      Answer from server, perhaps converted to Tcl dictionaries for easy
#      analysis at the caller.
#
# Side Effects:
#      None.
proc ::docker::Read { cx meta {stream 0} { json 1 } } {
    set dta ""
    array set META $meta

    if { [info exists META(Content-Length)] } {
        set dta [string trim [Data $cx $META(Content-Length) $stream]]
    }

    if { [info exists META(Transfer-Encoding)] \
                && $META(Transfer-Encoding) eq "chunked" } {
        set dta [string trim [Chunks $cx $stream]]
    }

    if { $dta ne "" && $json } {
        return [::docker::json::parse $dta]
    } else {
        return $dta
    }
}


# ::docker::APICall -- Perform API call
#

#      Perform a (newer) API call to Docker daemon using REST.  This takes a
#      number of options that should be separated from further arguments using a
#      double-dash.  Options are led by dashes, so the double-dash can be
#      omitted (first non-dash means start of arguments).  Supported options are
#      as follows, reading the Docker API documentation is strongly suggested!
#
#      -rest      HTTP operation to perform (GET, PUT, DELETE, etc.)
#      -namespace Leading path without slash, e.g. /containers, /images, etc.
#      -id        Identifier of object to target, empty for none.
#      -op        Operation to call (this is typically placed after the id)
#      -json      JSON content when POST/PUTing
#      -raw       When present, do not convert JSON from answer in response.
#      -headers   Even-long list of keys values to represent additional headers.
#
#      Once double-dash (or equivalent) led option extraction has been
#      performed, all remaining arguments will be passed to the server as query
#      arguments, meaning that this should also be an even-long list.
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#      args     Options and arguments, see above
#
# Results:
#      Return response, possibly parsed from JSON to Tcl-friendly representation
#
# Side Effects:
#      None.
proc ::docker::APICall { cx args } {
    # Detach API options from arguments to the operation being called itself.
    PullOpts args opts

    # Get main options
    GetOpt opts -rest -default "GET" -value rest
    GetOpt opts -namespace -default "containers" -value namespace
    GetOpt opts -id -default "" -value id
    GetOpt opts -op -default "" -value op
    GetOpt opts -json -default "" -value json
    GetOpt opts -headers -default {} -value headers
    GetOpt opts -stream -default {} -value cmd

    # Construct API path and perform REST call
    set path /[string trimleft $namespace /]
    if { $id ne "" } {
        append path /[string trimleft $id /]
    }
    if { $op ne "" } {
        append path /[string trimleft $op /]
    }
    if { $json ne "" || [llength $headers] > 0 } {
        eval [linsert $args 0 RequestJSON $cx $rest $path $json $headers]
    } else {
        eval [linsert $args 0 Request $cx $rest $path]
    }

    # Read response and return
    set response [Response $cx]
    if { [llength $cmd] } {
        if { [GetOpt opts -raw] } {
            Consume $cx $response $cmd
        } else {
            Consume $cx $response [list [namespace current]::JSONify $cmd]
        }
    } else {
        array set RSP $response
        switch -glob -- $RSP(code) {
            2* {
                if { [GetOpt opts -raw-stream] } {
                    return [Read $cx $RSP(meta) 1 0]
                } elseif { [GetOpt opts -raw] } {
                    return [Read $cx $RSP(meta) 0 0]
                } else {
                    return [Read $cx $RSP(meta)]
                }
            }
            default {
                return -code error "$RSP(code): [Read $cx $RSP(meta) 0]"
            }
        }
    }
    return ""
}


# ::docker::Get -- Do a GET operation
#
#      Perform a get API operation on a container
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#      id       Identifier of container
#      op       Operation (start, stop, etc. as of the API)
#      args     Additional arguments to pass as query parameters
#
# Results:
#      Return JSON result parsed as Tcl dictionary.
#
# Side Effects:
#      None.
proc ::docker::Get { cx id op args } {
    return [APICall $cx -rest GET -namespace containers -id $id -op $op -- {*}$args]

    # Code below unused, kept for posterity a little while
    eval [linsert $args 0 Request $cx GET /containers/$id/$op]
    array set RSP [Response $cx]
    switch -glob -- $RSP(code) {
        2* {
            return [Read $cx $RSP(meta)]
        }
        default {
            return -code error "$RSP(code): [Read $cx $RSP(meta) 0]"
        }
    }
    return ""
}

# ::docker::Do -- Do a POST operation
#
#      Perform a post API operation on a container
#
# Arguments:
#      cx       Identifier of connection, as returned by connect
#      id       Identifier of container
#      op       Operation (rename, etc. as of the API)
#      args     Additional arguments to pass as query parameters
#
# Results:
#      Return JSON result parsed as Tcl dictionary.
#
# Side Effects:
#      None.
proc ::docker::Do { cx id op args } {
    return [APICall $cx -rest POST -namespace containers -id $id -op $op -- {*}$args]

    # Code below unused, kept for posterity a little while
    eval [linsert $args 0 Request $cx POST /containers/$id/$op]
    array set RSP [Response $cx]
    switch -glob -- $RSP(code) {
        2* {
            return [Read $cx $RSP(meta)]
        }
        default {
            return -code error "$RSP(code): [Read $cx $RSP(meta) 0]"
        }
    }
    return ""
}


# ::docker::QueryHeaders -- Separate options and arguments
#
#      Given a list of arguments to an API call, this will separate away the
#      options from the arguments.  Once done, some (probably valid) heuristice
#      are performed to separate what will become query arguments from headers.
#      Headers should start with an upper case.  Leading dashes are
#      automatically removed, in case there was some.
#
# Arguments:
#      args_    "Pointer" to initial list of arguments.
#      qry_     "Pointer" to list of query parameters
#      hdrs_    "Pointer" to headers
#
# Results:
#      None.
#
# Side Effects:
#      Actively modifies the (incoming) list of arguments.
proc ::docker::QueryHeaders { args_ { qry_ "" } { hdrs_ "" }} {
    # Access variables in caller stack and initialise vars.
    upvar $args_ args
    if { $qry_ ne "" } {
        upvar $qry_ params
    }
    set params {}
    if { $hdrs_ ne "" } {
        upvar $hdrs_ headers
    }
    set headers {}

    # Separte options from remaining arguments using the -- or heuristics
    PullOpts args opts

    # Reassemble into the list of parameters to send as query parameters and
    # others to send as part of the headers.  Current heuristic is to
    # automatically remove any leading dash and then to consider options that
    # start with an uppercase as part of the headers and all remaining ones as
    # query parameters.
    foreach {k v} $opts {
        if { [string index $k 0] eq "-" } { set k [string range $k 1 end] }
        if { [string toupper [string index $k 0]] eq [string index $k 0] } {
            lappend headers $k $v
        } else {
            lappend params $k $v
        }
    }
}


package provide docker $::docker::version


