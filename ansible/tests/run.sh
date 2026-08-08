#!/bin/sh
# Runs every localhost test playbook. No VM or CEE install required.
set -e
cd "$(dirname "$0")"
for t in test_*.yml; do
    printf '\n== %s\n' "$t"
    ansible-playbook "$t"
done
printf '\nAll Ansible tests passed.\n'
