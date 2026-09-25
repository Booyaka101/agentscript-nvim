#!/bin/bash
# Full agentscript-nvim test suite inside a Linux container (node:22-bookworm).
# Expects the repo mounted at /work with:
#   scratch/linux/nvim-linux-x86_64.tar.gz  (Neovim release build)
#   scratch/ts/pkg-<version>/package        (grammar sources; test_treesitter
#                                            fetches them with npm if absent)
#   scratch/nvim-lspconfig                  (clone, with lsp/agentscript.lua)
set -e
export HOME=/tmp/home
mkdir -p "$HOME"
tar xzf /work/scratch/linux/nvim-linux-x86_64.tar.gz -C /tmp
export PATH=/tmp/nvim-linux-x86_64/bin:$PATH
echo "== environment =="
nvim --version | head -1
node --version
gcc --version | head -1
# Run from a container-local copy: on a Docker Desktop Windows bind mount a
# file renamed after dlopen stats as ENOENT, which real Linux never does.
mkdir -p /tmp/w
tar -C /work --exclude=./scratch/zig-extract --exclude=./scratch/zig.zip --exclude='./tests/tmp-*' -cf - . | tar -C /tmp/w -xf -
cd /tmp/w
fail=0
for t in test_treesitter test_install test_lsp test_upstream_config; do
  echo "== $t =="
  if ! nvim -l "tests/$t.lua"; then fail=1; fi
done
if [ "$fail" = "0" ]; then echo "LINUX SUITE: ALL PASSED"; else echo "LINUX SUITE: FAILURES"; exit 1; fi
