#!/bin/bash
# Full agentscript-nvim test suite inside a Linux container (node:22-bookworm).
# Expects the repo mounted at /work with:
#   scratch/linux/nvim-linux-x86_64.tar.gz  (Neovim release build)
#   scratch/ts/package                      (extracted grammar sources)
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
cd /work
fail=0
for t in test_treesitter test_install test_lsp test_upstream_config; do
  echo "== $t =="
  if ! nvim -l "tests/$t.lua"; then fail=1; fi
done
if [ "$fail" = "0" ]; then echo "LINUX SUITE: ALL PASSED"; else echo "LINUX SUITE: FAILURES"; exit 1; fi
