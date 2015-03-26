#! /usr/bin/env tclsh

##################
## Module Name     --  forwarder.tcl
## Original Author --  Emmanuel Frecon - emmanuel@sics.se
## Description:
##
##    Attaches to one or several docker containers and send their
##    output line by line to remote URLs.  By default, each line that
##    is found on the output will lead to an HTTP POST operation.
##
##################

set prg_args {
    -help      ""          "Print this help and exit"
    -verbose   0           "Verbosity level \[0-5\]"
    -docker    "unix:///var/run/docker.sock" "UNIX socket for connection to docker"
    -method    POST        "HTTP method to use"
    -type      "application/octet-stream" "MIME type for query"
    -keepalive 1           "Keepalive connections"
    -mapper    {}          "Mapping from container names/ids to topics"
    -dryrun    0           "Output what would be done instead"
    -output    stdout      "Which output of the docker containers to listen to"
    -retry     5000        "Milliseconds between container attachment retries"
}



set dirname [file dirname [file normalize [info script]]]
set appname [file rootname [file tail [info script]]]
lappend auto_path [file join $dirname docker]

package require Tcl 8.6;  # base64 encoding!
package require docker
package require http


# Dump help based on the command-line option specification and exit.
proc ::help:dump { { hdr "" } } {
    global appname

    if { $hdr ne "" } {
	puts $hdr
	puts ""
    }
    puts "NAME:"
    puts "\t$appname - A HTTP(s) forwarder, docker stdout --> HTTP POST"
    puts ""
    puts "USAGE"
    puts "\t${appname}.tcl \[options\]"
    puts ""
    puts "OPTIONS:"
    foreach { arg val dsc } $::prg_args {
	puts "\t${arg}\t$dsc (default: ${val})"
    }
    exit
}

proc ::getopt {_argv name {_var ""} {default ""}} {
    upvar $_argv argv $_var var
    set pos [lsearch -regexp $argv ^$name]
    if {$pos>=0} {
	set to $pos
	if {$_var ne ""} {
	    set var [lindex $argv [incr to]]
	}
	set argv [lreplace $argv $pos $to]
	return 1
    } else {
	# Did we provide a value to default?
	if {[llength [info level 0]] == 5} {set var $default}
	return 0
    }
}

array set FWD {}
foreach {arg val dsc} $prg_args {
    set FWD($arg) $val
}

if { [::getopt argv "-help"] } {
    ::help:dump
}

for {set eaten ""} {$eaten ne $argv} {} {
    set eaten $argv
    foreach opt [array names FWD -*] {
	::getopt argv $opt FWD($opt) $FWD($opt)
    }
}

# Arguments remaining?? dump help and exit
if { [llength $argv] > 0 } {
    ::help:dump "$argv are unknown arguments!"
}

# Callback once HTTP operation has ended, output some logging details
# depending on the success of the HTTP operation
proc ::result { container url line tok } {
    global FWD

    set ncode [::http::ncode $tok]
    if { $ncode >= 200 && $ncode < 300 } {
	docker log DEBUG "Success for $FWD(-method) HTTP op on $url"
    } else {
	docker log WARN "Could not trigger $url: HTTP errcode: $ncode"
    }
    ::http::cleanup $tok
}

# Callback whenever an output line from a docker container has been
# captured, generate the appropriate HTTP operation.
proc ::forward { container url type line } {
    global FWD

    if { $type eq "error" } {
	docker log WARN "Connection to $container lost,\
                            retrying in $FWD(-retry) ms"
	after $FWD(-retry) [list ::init $container $url]
	return
    }
    if { $line ne "" } {
	set URLmatcher {(?x)        # this is _expanded_ syntax
                    ^
                    (?: (\w+) : ) ?            # <protocol scheme>
                    (?: //
                        (?:
                            (
                                [^@/\#?]+        # <userinfo part of authority>
                            ) @
                        )?
                        (                # <host part of authority>
                            [^/:\#?]+ |        # host name or IPv4 address
                            \[ [^/\#?]+ \]        # IPv6 address in square brackets
                        )
                        (?: : (\d+) )?        # <port part of authority>
                    )?
                    ( / [^\#]*)?            # <path> (including query)
                    (?: \# (.*) )?            # <fragment>
                    $
	}
	# Extract authorisation and implement basic (always a start!)
	if { [catch {regexp -- $URLmatcher $url -> \
			 proto user host port srvurl} res] == 0 } {
	    if { $user ne "" } {
		set headers [list Authorization \
				 "Basic [binary encode base64 $user]"]
	    } else {
		set headers {}
	    }
	    # dryrun will ensure we can test without triggering the
	    # remote URLs
	    if { [string is true -strict $FWD(-dryrun)] } {
		docker log NOTICE "Would $FWD(-method) $line to $url\
                                      (auth: $user)"
	    } else {
		# Construct a URL getting command and execute it.
		# Arrange to schedule a callback to be called once
		# done, so we can continue with all further lines from
		# the docker containers.
		if { [catch {::http::geturl $url \
				 -headers $headers \
				 -method $FWD(-method) \
				 -type $FWD(-type) \
				 -query $line \
				 -keepalive $FWD(-keepalive) \
				 -command [list ::result \
					       $container $url $line]} \
			  tok] == 0 } {
		    docker log DEBUG "Successfully posting line to $url"
		} else {
		    docker log WARN "Cannot post to $url: $tok"
		}
	    }
	} else {
	    docker log WARN "Cannot understand URL $url: $res"
	}
    }
}


proc ::attach { container url } {
    global DOCKER
    global FWD

    if { [catch {$DOCKER($container) inspect $container} descr] } {
	if { $FWD(-retry) >= 0 } {
	    docker log DEBUG "No container, retrying in $FWD(-retry) ms"
	    after $FWD(-retry) [list ::attach $container $url]
	}
    } elseif { [dict exists $descr State Running] \
		   && [string is true [dict get $descr State Running]] } {
	docker log NOTICE "Attaching to container $container\
                           on $FWD(-output)"
	$DOCKER($container) attach $container \
	    [list ::forward $container $url] \
	    stream 1 $FWD(-output) 1
    } elseif { $FWD(-retry) >= 0 } {
	docker log DEBUG "No container, retrying in $FWD(-retry) ms"
	after $FWD(-retry) [list ::attach $container $url]
    }
}


proc ::init { container url } {
    global DOCKER
    global FWD

    # Disconnect if we already have a connection
    if { [info exists DOCKER($container)] } {
	$DOCKER($container) disconnect
	unset DOCKER($container)
    }

    set DOCKER($container) [docker connect $FWD(-docker)]
    ::attach $container $url
    return $DOCKER($container)
}


docker verbosity $FWD(-verbose)
if { [catch {package require tls} err] == 0 } {
    ::http::register https 443 [list ::tls::socket -tls1 1]
} else {
    docker log WARN "Will not be able to handle HTTPS connections!"
}

# Enumerate containers
foreach { container url } $FWD(-mapper) {
    ::init $container $url
}

vwait forever
