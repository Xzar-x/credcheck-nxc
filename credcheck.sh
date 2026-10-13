#!/bin/bash
# Użycie:
#   ./credcheck.sh <target> <user> <pass>   -> test konkretnych credsów na wszystkich protokołach
#   ./credcheck.sh <target>                 -> blind test (guest/anonymous/null) na wszystkich protokołach

target="$1"
user="$2"
pass="$3"

if [[ -z "$target" ]]; then
  echo "Użycie:"
  echo "  $0 <target> <user> <pass>   # test konkretnych credsów"
  echo "  $0 <target>                 # blind test (guest/anonymous/null)"
  exit 1
fi

protocols=(smb ssh ftp winrm mssql rdp ldap wmi nfs vnc)

if [[ -n "$user" && -n "$pass" ]]; then
  echo ">>> Tryb: test credsów $user:$pass na $target"
  echo

  for proto in "${protocols[@]}"; do
    echo "######### $proto #########"
    nxc $proto $target -u "$user" -p "$pass" 2>/dev/null
    echo
  done

else
  echo ">>> Tryb: blind test na $target"
  echo

  declare -a creds=(
    "anonymous anonymous"
    "anonymous ''"
    "'' ''"
    "guest guest"
    "guest ''"
  )

  for proto in "${protocols[@]}"; do
    echo "######### $proto #########"
    for cred in "${creds[@]}"; do
      read -r u p <<< "$cred"
      echo "--- $u:$p ---"
      nxc $proto $target -u "$u" -p "$p" 2>/dev/null
    done
    echo
  done
fi
