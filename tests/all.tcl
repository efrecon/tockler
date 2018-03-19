#! /usr/bin/env tclsh

package prefer latest
package require Tcl
package require tcltest 2.2
namespace import tcltest::*
configure {*}$argv -testdir [file dir [info script]]
if {[singleProcess]} {
    interp debug {} -frame 1
}
runAllTests
proc exit args {}