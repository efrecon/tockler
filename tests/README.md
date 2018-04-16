# Testing

All these tests suppose that you have a working installation of Docker and that
your user has proper privileges. The generic idea is to perform actions using
this API implementation and to check results using the installed `docker`
binary, i.e. as seen from the official client/daemon.

As tests might take some time, it is a good idea to increase the verbosity to
get some progress when each test starts, for example:

```console
$ ./all.tcl -verbose t
```