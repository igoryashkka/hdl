#!/bin/bash
# helper: build both role images (run via: wsl -u root bash <path>/run_fw.sh)
cd "$(dirname "$0")"
for r in rx tx; do ROLE=$r ./build_frm.sh 2>&1 | tail -12; done
