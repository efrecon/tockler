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
	    verboseTags    {1 CRITICAL 2 ERROR 3 WARN 4 NOTICE 5 INFO 6 DEBUG}
	    verbose        3
	    logd           stderr
	    -socat         "socat"
	    -nc            "nc"
	}
	variable version 0.2
	variable libdir [file dirname [file normalize [info script]]]
    }
    namespace export connect verbosity logger log
    namespace ensemble create
}


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


proc ::docker::disconnect { cx } {
    upvar \#0 $cx CX

    if { $CX(sock) ne "" } {
	catch {close $CX(sock)}
    }
    unset $cx
}

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



proc ::docker::ping { cx } {
    Request $cx GET _ping
    array set RSP [Response $cx]
    switch -glob -- $RSP(code) {
	2* {
	    return [Read $cx $RSP(meta) 0]
	}
	default {
	    return -code error "$RSP(code): [Read $cx $RSP(meta) 0]"
	}
    }
}


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


proc ::docker::top { cx id args } {
    return [eval [linsert $args 0 Get $cx $id top]]
}

proc ::docker::changes { cx id } {
    return [Get $cx $id changes]
}

proc ::docker::stats { cx id } {
    return [Get $cx $id stats]
}

proc ::docker::resize { cx id {w 80} {h 24}} {
    return [Do $cx $id resize h $h w $w]
}

proc ::docker::start { cx id } {
    return [Do $cx $id start]
}

proc ::docker::kill { cx id } {
    return [Do $cx $id kill]
}

proc ::docker::pause { cx id } {
    return [Do $cx $id pause]
}

proc ::docker::unpause { cx id } {
    return [Do $cx $id unpause]
}

proc ::docker::stop { cx id {t ""}} {
    if { $t eq "" } {
	return [Do $cx $id stop]
    } else {
	return [Do $cx $id stop t $t]
    }
}

proc ::docker::wait { cx id } {
    return [Do $cx $id wait]
}

proc ::docker::restart { cx id {t ""}} {
    if { $t eq "" } {
	return [Do $cx $id restart]
    } else {
	return [Do $cx $id restart t $t]
    }
}

proc ::docker::rename { cx id name } {
    if { $name ne "" } {
	return [Do $cx $id rename name $name]
    }
}


proc ::docker::attach { cx id cmd args } {
    upvar \#0 $cx CX

    eval [linsert $args 0 Request $cx POST /containers/$id/attach]
    Follow $cx $cmd
}


proc ::docker::exec { cx id cmd args } {
    upvar \#0 $cx CX

    set in [expr {[GetOpt args -stdin]?"true":"false"}]
    set out [expr {[GetOpt args -stdout]?"true":"false"}]
    set err [expr {[GetOpt args -stderr]?"true":"false"}]
    set tty [expr {[GetOpt args -tty]?"true":"false"}]
    set json "\{ "
    append json "\"AttachStdin\": $in, "
    append json "\"AttachStdout\": $out, "
    append json "\"AttachStderr\": $err, "
    append json "\"Tty\": $tty, "
    foreach c $cmd {
	append jcmd "\"$c\", "
    }
    set jcmd [string trimright $jcmd " ,"]
    append json "\"Cmd\": \[ $jcmd \] "
    append json "\}"
    RequestJSON $cx POST /containers/$id/exec $json
    
    array set RSP [Response $cx]
    switch -glob -- $RSP(code) {
	2* {
	    array set RES [Read $cx $RSP(meta)]
	    GetOpt args -callback -value cb -default ""
	    unset RSP
	    
	    set json "\{ \"Detach\": false \}"
	    RequestJSON $cx POST /exec/$RES(Id)/start $json
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

    if { $lvl >= 0 || $lvl ne "" } {
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
		set proc [lindex $caller 0]
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


####################################################################
#
# Procedures below are internal to the implementation, they shouldn't
# be changed unless you wish to help...
#
####################################################################


# ::docker::GetOpt -- Quick options parser
#
#       Parses options (and their possible) values from an option list. The
#       parser provides full introspection. The parser accepts itself a number
#       of dash-led options, which are:
#	-value   Which variable to store the value given to the option in.
#	-option  Which variable to store which option (complete) was parsed.
#	-default Default value to give when option not present.
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
	"tcp" {
	    set location [string range $CX(url) [expr {$sep+3}] end]
	    foreach { host port } [split $location ":"] break
	    if { $port eq "" } {
		set port 2375
	    }
	    set CX(sock) [socket $host $port]
	}
    }

    return $CX(sock)
}


proc ::docker::Request { cx op path args } {
    upvar \#0 $cx CX

    fconfigure $CX(sock) -buffering full
    set req ""
    if { [llength $args] > 0 } {
	set req "?"
	foreach {k v} $args {
	    append req "${k}=${v}&"
	}
	set req [string trimright $req "&"]
    }
    log DEBUG "Requesting $op /[string trimleft $path /]$req"
    puts $CX(sock) "$op /[string trimleft $path /]$req HTTP/1.1"
    puts $CX(sock) ""
    flush $CX(sock)
}


proc ::docker::RequestJSON { cx op path json } {
    upvar \#0 $cx CX

    fconfigure $CX(sock) -buffering full
    log DEBUG "Requesting $op /[string trimleft $path /] with JSON $json"
    puts $CX(sock) "$op /[string trimleft $path /] HTTP/1.1"
    puts $CX(sock) "Content-Type: application/json"
    puts $CX(sock) "Content-Length: [string length $json]"
    puts $CX(sock) ""
    puts -nonewline $CX(sock) $json
    flush $CX(sock)
}


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
	log DEBUG "Response $RSP(code) : [string trim $meta]"
    } else {
	return -code error "Cannot understand response: $response"
    }
    return [array get RSP]
}


proc ::docker::Data { cx len } {
    upvar \#0 $cx CX

    fconfigure $CX(sock) -translation binary
    set dta [read $CX(sock) $len]
    log DEBUG "Read [string length $dta] bytes from $CX(sock)"
    return $dta
}

proc ::docker::Chunks { cx } {
    upvar \#0 $cx CX
    
    set dta ""
    while 1 {
	set chunk [Chunk $cx]
	if { [string length $chunk] == 0 } {
	    break
	} else {
	    append dta $chunk
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


proc ::docker::Chunk { cx } {
    upvar \#0 $cx CX
    
    set dta ""
    if { [gets $CX(sock) hdr] >= 0 } {
	# Split header to access the hex size
	foreach sz [split $hdr ";"] break
	# Convert hex len in decimal
	scan $sz %x len
	if { $len > 0 } {
	    set dta [Data $cx $len]
	    fconfigure $CX(sock) -translation auto
	    gets $CX(sock)
	}
    }
    return $dta
}


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


proc ::docker::Stream { cx cmd } {
    upvar \#0 $cx CX

    set hdr [read $CX(sock) 8]
    if { [string length $hdr] == 8 } {
	binary scan $hdr cucucucuIu type a b c size
	array set T {0 stdin 1 stdout 2 stderr}
	set payload [string trim [read $CX(sock) $size]]
	if { [catch {eval [linsert $cmd end $T($type) $payload]} err] } {
	    log WARN "Cannot push back payload: $err"
	}
    } else {
	log WARN "Cannot read from socket!"
	fileevent $CX(sock) readable {}
	if { [catch {eval [linsert $cmd end error \
			       "Cannot read from socket"]} err] } {
	    log WARN "Cannot mediate error: $err"
	}
    }
}

proc ::docker::Follow { cx cmd } {
    upvar \#0 $cx CX

    array set RSP [Response $cx]
    switch -glob -- $RSP(code) {
	101 -
	2* {
	    array set META $RSP(meta)
	    if { [info exists META(Content-Type)] \
		     && $META(Content-Type) eq "application/vnd.docker.raw-stream" } {
		fconfigure $CX(sock) -encoding binary -translation binary
		fileevent $CX(sock) readable [list [namespace current]::Stream $cx $cmd]
	    }
	}
    }    
}

proc ::docker::Read { cx meta { json 1 } } {
    set dta ""
    array set META $meta

    if { [info exists META(Content-Length)] } {
	set dta [string trim [Data $cx $META(Content-Length)]]
    }

    if { [info exists META(Transfer-Encoding)] \
	     && $META(Transfer-Encoding) eq "chunked" } {
	set dta [string trim [Chunks $cx]]
    }

    if { $dta ne "" && $json } {
	return [::docker::json::parse $dta]
    } else {
	return $dta
    }
}

proc ::docker::Get { cx id op args } {
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

proc ::docker::Do { cx id op args } {
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

package provide docker $::docker::version
