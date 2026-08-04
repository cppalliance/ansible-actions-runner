#!/usr/bin/env bash
# Runs the role's offline and rollback checks.
#
#   ./tests/run.sh
#
# tests/normalize.yml is offline. tests/rollback.yml downloads the real runner
# tarball but never registers anything with GitHub.

set -euo pipefail

cd "$(dirname "$0")/.."

# tests/roles/ holds a symlink back to this repo, so the role resolves by name
# no matter what the checkout directory is called.
export ANSIBLE_ROLES_PATH="$PWD/tests/roles"
export ANSIBLE_COLLECTIONS_PATH="$PWD/collections"

# The role escalates with become. That is redundant when these tests already
# run as root, and outright impossible in a container started with no_new_privs.
if [ "$(id -u)" = "0" ]; then
    export ANSIBLE_BECOME_EXE="$PWD/tests/become-shim.sh"
fi

ansible-playbook tests/normalize.yml
ansible-playbook tests/hostname.yml
ansible-playbook tests/plist.yml
ansible-playbook tests/skip.yml
ansible-playbook tests/rollback.yml
