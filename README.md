# docker-client

## Introduction

Implementation of the docker [client API][1] in Tcl. At present, this covers a
large subset of the API, with a specific focus on management commands, i.e.
commands to manage images, containers, networks, swarm, nodes, etc.  This API
implementation is loosly modelled after the command-line, even though it
automatically relays API parameters as arguments to the calls. A forwarding
service is available as an example of slightly complex client code: the
forwarder is able to capture the output of running containers and send this
output, linewise, to remote URLs, possibly via plugin transformations. This
forwarding service is available as a [container][2].

  [1]: https://docs.docker.com/reference/api/docker_remote_api/
  [2]: https://hub.docker.com/r/efrecon/htdocker/

## Quick Tutorial

The library provides an object-based API: you will get a token for a connection
to the docker daemon, and this token is also a command with which you will
perform most of all other calls, Tk-style!

### Connect

To get a token, call a command similar to the following.  Note that when
specifying a UNIX socket, the library will pipe back and forth all commands
through the `nc` executable.  This is because Tcl has no native support for UNIX
sockets.

    set docker [docker connect unix:///var/run/docker.sock]

To connect to a remote docker daemon that is listening for TCP connections, do
something similar to the command below instead:

    set docker [docker connect tcp://localhost:2375]

And to connect to a remote docker daemon using TLS, which makes much more sense
than the previous command, do something similar to the following command. Tools
such as docker [machine](https://docs.docker.com/machine/) would create those
files for you.

    set docker [docker connect https://localhost:2376 -cert cert.pem -key key.pem]

### Other Commands

This is undocumented and in some flux for now, even though latest version of the
libraries have support for a large subset of the
[API](https://docs.docker.com/engine/api/latest/). An older set of commands
follow the original API, but new commands tend to follow the regrouping of
commands that occured a few years ago, under thematic sub-commands such as
[container](https://docs.docker.com/engine/reference/commandline/container/) or
[service](https://docs.docker.com/engine/reference/commandline/service/).

For an example of the old style, and provided that the variable `docker`
contains a reference to a daemon connection as examplified above, to ping the
server you would call the following, which should return the string `OK`.

    $docker ping

### API Principles

The API interface loosely follows the command-line options and arguments, but
with a preference for the API parameter names.

The following command would, for example, return a Tcl-compatible dictionary
representing all running containers on the host (this is the default):

    $docker container ls

In general, query parameters can be added as dash-led options after the
sub-command. For example, to get a list of all containers (including those that
are stopped or simply created but not running, etc.), you can issue the
following:

    $docker container ls -all 1

A large number of inspection commands have a filtering facility to focus more
easily of subsets of the information.  Specifying these queries can be
cumbersome and a command called `docker filters` is provided to help in this
task.  For example, to return the list of all running containers that are
healthy, you can issue the following. Note that `status` and `health` are keys
that can be provided to
[filter](https://docs.docker.com/engine/api/v1.36/#operation/ContainerList)
containers.

    $docker container ls -filters [docker filter status running health healthy]

A number of commands also take specific header parameters and the heuristic is
to consider all dash-led options starting with an uppercase as a header
parameter instead, e.g. `-X-Registry-Auth`.

Extra parameters, such as the name of an image or the identifier of a container
can be added after all dash-led options.  To be extra sure, you can separate
these options from the arguments using a double-dash, but this will not
generally be necessary.  For example, to inspect a specific container and
requesting its size differently than the default, you could issue the following
command:

    $docker container inspect -size true 68cec0e323169808277849a338325108b9c4821874524d2d3b7124b439c58e5d
