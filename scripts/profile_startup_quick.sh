#!/bin/bash
NVIM='/mnt/c/Program Files/Neovim/bin/nvim.exe'
LOG='C:\Users\hana-alice\AppData\Local\Temp\nvim_profile\after_wa.log'
WIN_LOG='/mnt/c/Users/hana-alice/AppData/Local/Temp/nvim_profile/after_wa.log'
for i in 1 2 3 4; do
  rm -f "$WIN_LOG"
  "$NVIM" --headless --startuptime "$LOG" -c "qa" >/dev/null 2>&1
  total=$(tr -d '\r' < "$WIN_LOG" 2>/dev/null | grep -E "^[0-9]+\." | tail -1 | awk '{print $1}')
  echo "  run $i: ${total}ms"
done
