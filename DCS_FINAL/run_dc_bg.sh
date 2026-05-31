#!/bin/bash
# Helper to launch DC synthesis detached on the workstation.
set -e
cd "$HOME/Final/02_SYN"
rm -f syn.log syn_split.log
setsid bash ./01_run_dc > syn_split.log 2>&1 < /dev/null &
disown
sleep 3
echo "DC_STARTED"
pgrep -af dcnxt_shell || pgrep -af dc_shell || echo "no dc process found yet"
ls -la syn_split.log
