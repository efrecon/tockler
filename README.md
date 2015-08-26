# docker-client

## Introduction

Implementation of the docker [client API][1] in Tcl. At present, this
covers only a subset of the API.  You will be able to introspect your
components, control them and attach to them.  There is no support for
images or execution contexts, nor to start components.  A forwarding
service is available as an example client code: the forwarder is able
to capture the output of running components and send this output,
linewise, to remote URLs, possibly via plugin transformations.  The
forwarding service is what the docker component associated to this
repository implements.

  [1]: https://docs.docker.com/reference/api/docker_remote_api/

## Quick Tutorial

The library provides an object-based API: you will get a token for a
connection to the docker daemon, and this token is also a command with
which you will perform most of all other calls, Tk-style!

### Connect

To get a token, call a command similar to the following.  Note that
when specifying a UNIX socket, the library will pipe back and forth
all commands through the `nc` executable.  This is because Tcl has no
native support for UNIX sockets.

    set docker [docker connect unix:///var/run/docker.sock]

To connect to a remote docker daemon that is listening for TCP
connections, do something similar to the command below instead:

    set docker [docker connect tcp://localhost:2375]

### Other Commands

This is undocumented for now, but follows more or less the original
API.  For example, to ping the server, call the following, which
should return the string `OK`.

    $docker ping

## Forwarding Service

This library comes with a forwarding service `forwarder.tcl` that
mainly serves as an example code.  The service is able to attach to
one or several docker components and send what they output to remote
URLs.  By default, the HTTP operation used is a `POST`, MIME type
`application/octet-stream`.  The components and their destinations
URLs is controlled by the option `-mapper` which should contain a
space-separated list.  The list contains any alternating number of
component name, destination URLs and plugin call specification (see
below).  When the plugin specification is empty or a dash, the data is
simply posted to the remote URL (or sent using the default operation).

A plugin specification should take the form of a procedure call
followed by an `@` sign, followed by a file specification (with no
spaces inbetween).  The file should be found in the plugin directory
specified by the `-exts` option to the program.  In short, if the
plugin specification looked like `myproc@myplugin.tcl`, the file
`myplugin.tcl` would be looked up in the plugin directory, sourced in
a *safe* interpreter and the procedure `myproc` would be called with
the content of the line captured on the component's `stdout` whenever
it was captured.  Being placed in a safe interpreter, the procedure
will be able to call most of the regular Tcl commands, but will not
have an I/O capabilities.  However, it can call a command called
`send` which takes the following arguments (in order): the data to be
sent, an additional (and optional) path or query argument string to
*append* to the URL specified, an optional HTTP operation to perform
(`GET`, `POST`, `DELETE`, etc.) and finally an optional MIME type.
Passing empty strings for the HTTP operation or the MIME type will
pick the defaults one from the program options.  It is only possible
to append path/queries to the URL for security reasons, i.e. so as to
avoid side-effects for plugins and allow users to fully specify the
(root) URL where to send data to.

It is possible to pass arguments to the procedure. The procedure
specification part of the plugin specification (i.e. the string before
the `@` sign) should then contain a number of `!` separated tokens.
The first token will be the procedure name, and the following ones
will be arguments.  These arguments are passed further to the
procedure after the data captured from the component.

## Component Controller

This library also comes with a service called `dockron.tcl` that is
able to execute docker commands on (groups of) components on a regular
basis.  The actions to perform are taken from the command-line option
`-rules`, which should be a white-space separated list of
specifications, a multiple of 7 items.  The items are taken in turns
and are interpreted as described below:

1. The minute of the day.
2. The hour of the day.
3. The day of the month
4. The month number.
5. The day of the week.
6. A glob-style pattern to match against the names of the component
7. The command to execute, e.g. `restart`, `pause`, etc.

For all the date related specifications, the component controller
follows the `crontab` conventions, meaning that you should be able to
specify "any" using `*`, but also intervals such as `[0-5,14-18]`, or
"every 3" using `*/3*`.