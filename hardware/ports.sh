# Serial port helpers for flash.sh and flash_ble.sh (sourced). Windows means Git Bash / MSYS2 there.
windows() { [[ $OSTYPE == msys* || $OSTYPE == cygwin* ]]; }

# serial_port VIDS PATHS...: the first USB COM port whose vendor id matches VIDS (e.g. '303A|10C4') on Windows,
# elsewhere the first of PATHS that exists; nothing if none.
serial_port() {
  local vids=$1 p; shift
  if windows; then
    powershell.exe -NoProfile -NonInteractive -Command "Get-CimInstance Win32_PnPEntity | ForEach-Object {
      if (\$_.PNPDeviceID -match 'VID_($vids)' -and \$_.Name -match '\((COM\d+)\)') { \$Matches[1] } }" \
      | tr -d '\r' | head -n 1 || true
    return 0
  fi
  for p in "$@"; do [[ -e $p ]] && { echo "$p"; return 0; }; done
  return 0
}

# touch_1200 PORT: open the port at 1200 baud, which resets a running TinyUSB bridge into the ROM bootloader.
touch_1200() {
  if windows; then
    powershell.exe -NoProfile -NonInteractive -Command "\$p = New-Object System.IO.Ports.SerialPort('$1', 1200)
      \$p.Open(); \$p.DtrEnable = \$false; Start-Sleep -Milliseconds 100; \$p.Close()" >/dev/null 2>&1 || true
  else
    stty -f "$1" 1200 2>/dev/null || stty -F "$1" 1200 2>/dev/null || true
  fi
}
