FROM efrecon/mini-tcl
MAINTAINER Emmanuel Frecon <emmanuel@sics.se>

# Ensure we have socat since nc on busybox does not support UNIX
# domain sockets.
RUN apk add --update-cache socat && \
    rm -rf /var/cache/apk/*

# COPY code
COPY *.md /opt/htdocker/
COPY forwarder.tcl /opt/htdocker/
COPY docker/ /opt/htdocker/docker/

# Export where we will look for the Docker UNIX socket.
VOLUME ["/tmp/docker.sock"]

# Export the plugin directory to ease testing new plugins
VOLUME ["/opt/htdocker/exts"]

ENTRYPOINT ["tclsh8.6", "/opt/htdocker/forwarder.tcl", "-docker", "unix:///tmp/docker.sock"]
CMD ["-verbose", "4"]
