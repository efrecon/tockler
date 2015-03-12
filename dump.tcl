lappend auto_path [file join [file dirname [info script]] docker]
package require docker

docker verbosity 6

proc dumpme {id type line} {
    puts "$id/$type :: $line"
}

# Connect to local docker socket
set d [docker connect unix:///var/run/docker.sock]

# Enumerate all running containers and dump what they all write on the
# stdout
foreach c [$d containers] {
    set id [string range [dict get $c Id] 0 11]
    $d attach $id [list dumpme $id] stream 1 stdout 1
}

vwait forever
