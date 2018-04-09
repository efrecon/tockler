lappend auto_path [file join [file dirname [info script]] docker] [file join [file dirname [info script]] .. ..]
package require docker

#docker verbosity 6

# Connect to local docker socket
if { $argc == 0 } {
    set argv [list unix:///var/run/docker.sock]
}

proc collect { id { dta {}} } {
    global argv
    
    if { ! [info exists ::C_$id] } {
        # Open new connection to daemon to collect statistics as they go for all
        # containers.
        set c [docker connect {*}$argv]
        dict set ::C_$id id $id
        dict set ::C_$id name ""
        dict set ::C_$id connection $c
        dict set ::C_$id memPercent 0
        dict set ::C_$id mem 0
        dict set ::C_$id memLimit 0
        dict set ::C_$id cpuPercent 0
        dict set ::C_$id rx 0
        dict set ::C_$id tx 0
        dict set ::C_$id pidsCurrent 0
        dict set ::C_$id name ""
        $c stats $id [list collect $id]
    } elseif { [llength $dta] } {
        # These statistics are inline with the ones shown by docker stats, see:
        # https://github.com/docker/cli/blob/master/cli/command/container/stats_helpers.go
        if { [dict get $dta memory_stats limit] != 0 } {
            dict set ::C_$id memPercent [expr {double([dict get $dta memory_stats usage])/double([dict get $dta memory_stats limit])*100.0}]
        }
        dict set ::C_$id mem [dict get $dta memory_stats usage]
        dict set ::C_$id memLimit [dict get $dta memory_stats limit]
        set previousCPU [dict get $dta precpu_stats cpu_usage total_usage]
        set previousSystem [dict get $dta precpu_stats system_cpu_usage]
        set cpuDelta [expr {[dict get $dta cpu_stats cpu_usage total_usage]-$previousCPU}]
        set systemDelta [expr {[dict get $dta cpu_stats system_cpu_usage]-$previousSystem}]
        if { $systemDelta > 0 && $cpuDelta > 0 } {
            dict set ::C_$id cpuPercent [expr {(double($cpuDelta)/double($systemDelta))*double([llength [dict get $dta cpu_stats cpu_usage percpu_usage]])*100.0}]
        } else {
            dict set ::C_$id cpuPercent 0.0
        }
        dict set ::C_$id rx 0
        dict set ::C_$id tx 0
        foreach { net vals } [dict get $dta networks] {
            dict incr ::C_$id rx [dict get $vals rx_bytes]
            dict incr ::C_$id tx [dict get $vals tx_bytes]
        }
        dict set ::C_$id pidsCurrent [dict get $dta pids_stats current]
        dict set ::C_$id name [string trimleft [dict get $dta name] "/"]
    }
}

proc display {} {
    puts \x1b\[H\x1b\[2J
    puts "NAME\tCPU%\tMEM%\tPIDS"
    foreach c [info vars ::C_*] {
        puts "[dict get [set $c] name]\t[dict get [set $c] cpuPercent]%\t[dict get [set $c] memPercent]\t[dict get [set $c] pidsCurrent]"
    }
    after 1000 display
}

# Enumerate all running containers and start collecting statistics
proc containers { d } {
    # Capture all containers and start to collect statistics (this will have no
    # effect on containers that are already under our control)
    set all [list]
    foreach c [$d containers] {
        set id [string range [dict get $c Id] 0 11]
        collect $id
        lappend all $id
    }
    
    # Remove containers that would have disappeared
    foreach c [info vars ::C_*] {
        set id [dict get [set $c] id]
        if { [lsearch $all $id] < 0 } {
            [dict get [set $c] connection] disconnect
            unset $c
        }
    }
    
    # Collect again later on
    after 5000 containers $d
}

set d [docker connect {*}$argv]
after idle containers $d
after 1000 display

vwait forever
