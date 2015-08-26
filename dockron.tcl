#! /usr/bin/env tclsh

set dirname [file dirname [file normalize [info script]]]
set appname [file rootname [file tail [info script]]]
lappend auto_path [file join $dirname docker]

package require docker

set prg_args {
    -docker    "unix:///var/run/docker.sock" "UNIX socket for connection to docker"
    -rules     ""   "List of cron specifications for restarting (multiple of 7)"
    -verbose   INFO "Verbose level"
    -reconnect 5    "Freq. of docker reconnection in sec., <0 to turn off"
    -h         ""   "Print this help and exit"
}

# Dump help based on the command-line option specification and exit.
proc ::help:dump { { hdr "" } } {
    global appname

    if { $hdr ne "" } {
	puts $hdr
	puts ""
    }
    puts "NAME:"
    puts "\t$appname - Docker component command scheduler"
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


# Did we ask for help at the command-line, print out all command-line
# options described above and exit.
if { [::getopt argv -h] } {
    ::help:dump
}

# Extract list of command-line options into array that will contain
# program state.  The description array contains help messages, we get
# rid of them on the way into the main program's status array.
array set DCKRN {
    docker     ""
}
foreach { arg val dsc } $prg_args {
    set DCKRN($arg) $val
}
for {set eaten ""} {$eaten ne $argv} {} {
    set eaten $argv
    foreach opt [array names DCKRN -*] {
	::getopt argv $opt DCKRN($opt) $DCKRN($opt)
    }
}

# Remaining args? Dump help and exit
if { [llength $argv] > 0 } {
    ::help:dump "[lindex $argv 0] is an unknown command-line option!"
}

# Local constants and initial context variables.
docker verbosity $DCKRN(-verbose)

set startup "Starting [file rootname [file tail [info script]]] with args\n"
foreach {k v} [array get DCKRN -*] {
    append startup "\t$k:\t$v\n"
}
docker log INFO [string trim $startup] $appname


# ::fieldMatch --
#
#	This command matches a crontab-like specification for a field
#	to a current value.
#
#	A field may be an asterisk (*), which always stands for
#	''first-last''.
#
#	Ranges of numbers are allowed.  Ranges are two numbers
#	separated with a hyphen.  The specified range is inclusive.
#	For example, 8-11 for an ''hours'' entry specifies execution
#	at hours 8, 9, 10 and 11.
#
#	Lists are allowed.  A list is a set of numbers (or ranges)
#	separated by commas.  Examples: ''1,2,5,9'', ''0-4,8-12''.
#
#	Step values can be used in conjunction with ranges.  Following
#	a range with ''/<number>'' specifies skips of the number's
#	value through the range.  For example, ''0-23/2'' can be used
#	in the hours field to specify command execution every other
#	hour (the alternative in the V7 standard is
#	''0,2,4,6,8,10,12,14,16,18,20,22'').  Steps are also permitted
#	after an asterisk, so if you want to say ''every two hours'',
#	just use ''*/2''.
#
# Arguments:
#	value	Current value of the field
#	spec	Matching specification
#
# Results:
#	returns 1 if the current value matches the specification, 0
#	otherwise
#
# Side Effects:
#	None.
proc ::fieldMatch { value spec } {
    if { $value != "0" } {
	regsub "^0" $value "" value
    }

    foreach rangeorval [split $spec ","] {

	# Analyse step specification
	set idx [string first "/" $rangeorval]
	if { $idx >= 0 } {
	    set step [string trim \
			  [string range $rangeorval [expr $idx + 1] end]]
	    set rangeorval [string trim \
				[string range $rangeorval 0 [expr $idx - 1]]]
	} else {
	    set step 1
	    set rangeorval [string trim $rangeorval]
	}

	# Analyse range specification.
	set values ""
	set idx [string first "-" $rangeorval]
	if { $idx >= 0 } {
	    set minval [string trim \
			    [string range $rangeorval 0 [expr $idx - 1]]]
	    if { $minval != "0" } {
		regsub "^0" $minval "" minval
	    }
	    set maxval [string trim \
			    [string range $rangeorval [expr $idx + 1] end]]
	    if { $maxval != "0" } {
		regsub "^0" $maxval "" maxval
	    }
	    for { set i $minval } { $i <= $maxval } { incr i $step } {
		if { $value == $i } {
		    return 1
		}
	    }
	} else {
	    if { $rangeorval == "*" } {
		if { ! [expr int(fmod($value, $step))] } {
		    return 1
		}
	    } else {
		if { $rangeorval == $value } {
		    return 1
		}
	    }
	}
    }

    return 0
}


proc ::connect {} {
    global DCKRN
    global appname
    
    if { $DCKRN(docker) ne "" } {
	catch {$DCKRN(docker) disconnect}
	set DCKRN(docker) ""
    }

    if { [catch {docker connect $DCKRN(-docker)} d] } {
	docker log WARN "Cannot connect to docker at $DCKRN(-docker): $d" $appname
    } else {
	set DCKRN(docker) $d
    }

    if { $DCKRN(docker) eq "" } {
	if { $DCKRN(-reconnect) >= 0 } {
	    set when [expr {int($DCKRN(-reconnect)*1000)}]
	    after $when ::connect
	}
    } else {
	::check
    }
}


proc ::check {} {
    global DCKRN
    global appname

    # Get current list of containers
    if { [catch {$DCKRN(docker) containers} containers] } {
	if { $DCKRN(-reconnect) >= 0 } {
	    set when [expr {int($DCKRN(-reconnect)*1000)}]
	    after $when ::connect
	}
	return
    }

    set now [clock seconds]
    set min [clock format $now -format "%M"]
    set hour [clock format $now -format "%H"]
    set daymonth [clock format $now -format "%e"]
    set month [clock format $now -format "%m"]
    set dayweek [clock format $now -format "%w"]

    foreach {e_min e_hour e_daymonth e_month e_dayweek ptn cmd} $DCKRN(-rules) {
	if { [fieldMatch $min $e_min] \
		 && [fieldMatch $hour $e_hour] \
		 && [fieldMatch $daymonth $e_daymonth] \
		 && [fieldMatch $month $e_month] \
		 && [fieldMatch $dayweek $e_dayweek] } {
	    foreach c $containers {
		set id ""
		if { [dict exists $c Names] } {
		    foreach name [dict get $c Names] {
			set name [string trimleft $name "/"]
			if { [string match $ptn $name] } {
			    set id [dict get $c Id]
			    break
			}
		    }
		}
		
		if { $id ne "" } {
		    docker log NOTICE "Running '$cmd' on container $id" $appname
		    set val [$DCKRN(docker) $cmd $id]
		    docker log INFO "$cmd returned: $val" $appname
		}
	    }
	}
    }

    after 60000 ::check
}

connect;    # Will start checking
vwait forever
