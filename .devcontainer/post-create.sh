#!/bin/bash
set -euo pipefail

curl https://mise.run | sh
~/.local/bin/mise trust
echo 'eval "$(~/.local/bin/mise activate bash)"' >>~/.bashrc
~/.local/bin/mise install
