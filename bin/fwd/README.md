# HTTP Forwarding Service

This forwarding service `forwarder.tcl` serves as an example code for the Docker
[API implementation in Tcl][1].  The service is able to attach to one or several
docker containers and send their output to remote URLs.  By default, the HTTP
operation used is a `POST`, MIME type `application/octet-stream`.  The
containers to listen to and their destinations URLs is controlled by the option
`-mapper` which should contain a space-separated list.  The list contains any
alternating number of container name, destination URLs and plugin call
specification (see below).  When the plugin specification is empty or a dash,
the data is simply posted to the remote URL (or sent using the default
operation).  The forwarding service continuously listens for container presence,
meaning that it will be able to pickup new containers matching the name and/or
reattach to containers that would be restarted or recreated.

  [1]: https://github.com/efrecon/docker-client

A plugin specification should take the form of a procedure call followed by an
`@` sign, followed by a file specification (with no spaces inbetween).  The file
should be found in the plugin directory specified by the `-exts` option to the
program.  In short, if the plugin specification looked like
`myproc@myplugin.tcl`, the file `myplugin.tcl` would be looked up in the plugin
directory, sourced in a *safe* interpreter and the procedure `myproc` would be
called with the content of the line captured on the component's `stdout`
whenever it was captured.  Being placed in a safe interpreter, the procedure
will be able to call most of the regular Tcl commands, but will not have an I/O
capabilities.  However, it can call a command called `send` which takes the
following arguments (in order): the data to be sent, an additional (and
optional) path or query argument string to *append* to the URL specified, an
optional HTTP operation to perform (`GET`, `POST`, `DELETE`, etc.) and finally
an optional MIME type. Passing empty strings for the HTTP operation or the MIME
type will pick the defaults one from the program options.  It is only possible
to append path/queries to the URL for security reasons, i.e. so as to avoid
side-effects for plugins and allow users to fully specify the (root) URL where
to send data to.

It is possible to pass arguments to the procedure. The procedure specification
part of the plugin specification (i.e. the string before the `@` sign) should
then contain a number of `!` separated tokens. The first token will be the
procedure name, and the following ones will be arguments.  These arguments are
passed further to the procedure after the data captured from the component.
