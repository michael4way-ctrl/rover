#!/bin/zsh
set -euo pipefail

if ! command -v iproxy >/dev/null 2>&1; then
  echo "Не найден iproxy. Установите его командой: brew install libimobiledevice"
  exit 1
fi

echo "USB-шлюз запущен: http://127.0.0.1:17777"
echo "Не закрывайте это окно, пока управляете ровером с Mac."
exec iproxy 17777:17777
