#!/bin/sh
# Test-only stand-in for sudo, used by tests/rollback.yml when the test is
# already running as root.
#
# The role escalates with `become`, but sudo cannot escalate inside a container
# started with the no_new_privs flag, and it is redundant when the caller is
# already root. This strips the flags sudo would have consumed and runs the
# rest directly.
#
# Never referenced outside tests/.

set -e

while [ $# -gt 0 ]; do
    case "$1" in
        -H|-S|-n|-k|-q|-E) shift ;;
        -u|-p|-g) shift 2 ;;
        --) shift; break ;;
        -*) shift ;;
        *) break ;;
    esac
done

exec "$@"
