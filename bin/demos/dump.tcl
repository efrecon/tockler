lappend auto_path [file join [file dirname [info script]] docker] [file join [file dirname [info script]] .. ..]
package require docker

docker verbosity 6

proc dumpme {id type line} {
    puts "$id/$type :: $line"
}

# Connect to local docker socket
if { $argc == 0 } {
    set argv [list unix:///var/run/docker.sock]
}
set d [docker connect {*}$argv]

# Enumerate all running containers and dump what they all write on the
# stdout
foreach c [$d containers] {
    set id [string range [dict get $c Id] 0 11]
    $d attach $id [list dumpme $id] stream 1 stdout 1
}

vwait forever
