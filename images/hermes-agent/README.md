# Hermes Agent image

Build with `./test.sh`. The image runs `hermes gateway run` as UID/GID `10000`
without a process supervisor. It needs writable `/opt/data` for Hermes state and
`/tmp` for temporary files; the root filesystem can be read-only.

The image includes Matrix and MCP support. It omits S6, browser/desktop and
computer-use components, Photon, Node, and runtime package installation.
