#!/bin/sh
# Everything CI checks, in the order CI checks it, in one command.
#
# There is no application source here, so "the tests" means the localhost
# Ansible suite plus three linters. All four ran as separate remembered
# commands until 2026-08-22, which is how a release went out with yamllint
# and ansible-lint unrun on the machine that cut it.
#
# Needs no VM, no CEE install, no network, and no Dell artefact in bin/.
#
#   ./scripts/check.sh          run everything, stop at the first failure
#   ./scripts/check.sh --deps   install the galaxy collections first
#
# The galaxy install must precede the syntax check and ansible-lint:
# ansible.posix, community.general, ansible.windows and community.windows are
# not bundled with ansible-core, and without them even --syntax-check fails.
set -eu

cd "$(dirname "$0")/.."

if [ "${1:-}" = "--deps" ]; then
    printf '\n== ansible-galaxy collection install\n'
    ansible-galaxy collection install -r ansible/requirements.yml
fi

missing=''
for t in ansible-playbook yamllint ansible-lint; do
    command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
if [ -n "$missing" ]; then
    printf 'Missing:%s\n' "$missing" >&2
    printf 'Install them, or run the pieces you can — a partial run is not a pass.\n' >&2
    exit 127
fi

printf '\n== yamllint\n'
yamllint ansible/ .github/

printf '\n== ansible-playbook --syntax-check site.yml\n'
( cd ansible && ansible-playbook --syntax-check site.yml )

printf '\n== ansible-lint (production profile)\n'
ansible-lint ansible/

printf '\n== ansible/tests/run.sh\n'
ansible/tests/run.sh

printf '\nAll checks passed.\n'
