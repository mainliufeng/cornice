"""Remove inherited descriptors before the test sandbox, including any Wayland FD."""
import os
import resource
import sys

if len(sys.argv) < 2:
    raise SystemExit("sandbox-exec needs a command")
null = os.open("/dev/null", os.O_RDONLY)
os.dup2(null, 0)
if null > 2:
    os.close(null)
maximum = resource.getrlimit(resource.RLIMIT_NOFILE)[1]
if maximum == resource.RLIM_INFINITY:
    maximum = os.sysconf("SC_OPEN_MAX")
os.closerange(3, int(maximum))
os.execv(sys.argv[1], sys.argv[1:])
