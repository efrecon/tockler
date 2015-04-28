FROM efrecon/tcl
MAINTAINER Emmanuel Frecon <emmanuel@sics.se>


# Set the env variable DEBIAN_FRONTEND to noninteractive to get
# apt-get working without error output.
ENV DEBIAN_FRONTEND noninteractive

# Update underlying ubuntu image and all necessary packages, including
# docker itself so it is possible to run containers for sources or
# destinations.
RUN apt-get update

# COPY code
COPY *.md /opt/htdocker/
COPY forwarder.tcl /opt/htdocker/
COPY docker/ /opt/htdocker/docker/

# Export where we will look for the Docker UNIX socket.
VOLUME ["/tmp/docker.sock"]

# Export the plugin directory to ease testing new plugins
VOLUME ["/opt/htdocker/exts"]

ENTRYPOINT ["tclsh8.6", "/opt/htdocker/forwarder.tcl"]
CMD ["-verbose", "4", "-docker", "unix:///tmp/docker.sock"]