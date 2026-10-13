#!/bin/bash
# credcheck.sh - testowanie danych uwierzytelniających na wielu protokołach przez nxc (NetExec)
#
# Użycie:
#   ./credcheck.sh -t <target> -u <user> -p <pass> [opcje]
#   ./credcheck.sh -t <target> [opcje]              # tryb blind (anonymous/guest/null)
#
# Opcje:
#   -t, --target        IP/host celu (wymagane)
#   -u, --user           nazwa użytkownika
#   -p, --pass            hasło
#   -m, --max-attempts   limit prób przed potwierdzeniem (domyślnie 15)
#   --delay-min           minimalne opóźnienie między próbami w sek. (domyślnie 1)
#   --delay-max           maksymalne opóźnienie między próbami w sek. (domyślnie 3)
#   --protocols           lista protokołów oddzielona przecinkami (domyślnie wszystkie)
#   -o, --output          zapisz pełny log do pliku
#   -y, --yes             nie pytaj o potwierdzenie przy przekroczeniu limitu
#   -h, --help            pokaż tę pomoc

set -u

target=""
user=""
pass=""
max_attempts=15
delay_min=1
delay_max=3
protocols_arg=""
output_file=""
auto_yes=0

print_help() {
  awk '/^#!/{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target)
      target="$2"; shift 2 ;;
    -u|--user)
      user="$2"; shift 2 ;;
    -p|--pass)
      pass="$2"; shift 2 ;;
    -m|--max-attempts)
      max_attempts="$2"; shift 2 ;;
    --delay-min)
      delay_min="$2"; shift 2 ;;
    --delay-max)
      delay_max="$2"; shift 2 ;;
    --protocols)
      protocols_arg="$2"; shift 2 ;;
    -o|--output)
      output_file="$2"; shift 2 ;;
    -y|--yes)
      auto_yes=1; shift ;;
    -h|--help)
      print_help; exit 0 ;;
    *)
      echo "Nieznana opcja: $1"
      echo "Użyj -h / --help, żeby zobaczyć dostępne opcje."
      exit 1 ;;
  esac
done

if [[ -z "$target" ]]; then
  echo "Błąd: brak celu."
  echo "Użyj -h / --help, żeby zobaczyć składnię."
  exit 1
fi

if [[ -n "$protocols_arg" ]]; then
  IFS=',' read -r -a protocols <<< "$protocols_arg"
else
  protocols=(smb ssh ftp winrm mssql rdp ldap wmi nfs vnc)
fi

declare -a creds=()
if [[ -n "$user" && -n "$pass" ]]; then
  mode="Test konkretnych credsów"
  creds=("$user $pass")
else
  mode="Blind test (anonymous/guest/null)"
  creds=(
    "anonymous anonymous"
    "anonymous ''"
    "'' ''"
    "guest guest"
    "guest ''"
  )
fi

total_attempts=$(( ${#protocols[@]} * ${#creds[@]} ))

echo ">>> Tryb: $mode"
echo ">>> Cel: $target"
echo ">>> Protokoły: ${protocols[*]}"
echo ">>> Planowanych prób: $total_attempts (limit: $max_attempts)"
echo ">>> Opóźnienie między próbami: ${delay_min}-${delay_max}s (jitter)"
[[ -n "$output_file" ]] && echo ">>> Log zapisywany do: $output_file"
echo

if [[ -n "$output_file" ]]; then
  : > "$output_file"
fi

log() {
  echo "$1"
  [[ -n "$output_file" ]] && echo "$1" >> "$output_file"
}

if (( total_attempts > max_attempts )); then
  echo "⚠️  UWAGA: planowana liczba prób ($total_attempts) przekracza limit ($max_attempts)."
  echo "   Na środowiskach z polityką lockoutu może to zablokować testowane konto"
  echo "   lub wywołać alarmy/throttling po stronie usługi."
  if (( auto_yes == 0 )); then
    read -p "   Kontynuować mimo to? [t/N]: " confirm
    if [[ ! "$confirm" =~ ^[TtYy]$ ]]; then
      echo "Przerwano przez użytkownika."
      exit 1
    fi
  else
    echo "   (--yes podane, kontynuuję automatycznie)"
  fi
  echo
fi

if ! command -v nxc >/dev/null 2>&1; then
  echo "❌ Błąd: 'nxc' nie jest zainstalowany lub nie jest w PATH."
  echo "   Jeśli korzystasz z venv, aktywuj je najpierw (np. komendą 'bb')."
  exit 1
fi

declare -a summary_rows=()
attempt_count=0

for proto in "${protocols[@]}"; do
  for cred in "${creds[@]}"; do
    read -r u p <<< "$cred"
    attempt_count=$((attempt_count + 1))

    log "######### [$attempt_count/$total_attempts] $proto -- $u:$p #########"

    start_ts=$(date +%s.%N)
    output=$(nxc "$proto" "$target" -u "$u" -p "$p" 2>&1)
    exit_code=$?
    end_ts=$(date +%s.%N)
    elapsed=$(awk "BEGIN {printf \"%.2f\", $end_ts - $start_ts}")

    log "$output"
    log ""

    status="BŁĄD NARZĘDZIA"
    error_info=""

    if (( exit_code != 0 )); then
      status="BŁĄD NARZĘDZIA"
      error_info="exit code $exit_code"
    elif echo "$output" | grep -qE '\[\+\]'; then
      status="SUKCES"
    elif echo "$output" | grep -qiE 'connection refused|connection error|timed? ?out|no route to host|network is unreachable'; then
      status="BRAK POŁĄCZENIA"
      error_info=$(echo "$output" | grep -oiE 'connection refused|connection error|timed? ?out|no route to host|network is unreachable' | head -1)
    elif echo "$output" | grep -qE '\[-\]'; then
      status="ODRZUCONO"
    else
      status="NIEZNANY"
    fi

    summary_rows+=("$proto|$u:$p|$status|${elapsed}s|$error_info")

    if (( attempt_count < total_attempts )); then
      delay=$(awk -v min="$delay_min" -v max="$delay_max" 'BEGIN{srand(); printf "%.2f", min+rand()*(max-min)}')
      log "⏳ Czekam ${delay}s przed kolejną próbą..."
      sleep "$delay"
      log ""
    fi
  done
done

log "=================================================================="
log " PODSUMOWANIE"
log "=================================================================="
summary_header=$(printf "%-8s %-25s %-16s %-8s %-s" "PROTO" "CREDS" "STATUS" "CZAS" "INFO")
log "$summary_header"
log "$(printf "%-8s %-25s %-16s %-8s %-s" "-----" "-----" "------" "----" "----")"

success_count=0
for row in "${summary_rows[@]}"; do
  IFS='|' read -r proto creds_s status elapsed info <<< "$row"
  log "$(printf "%-8s %-25s %-16s %-8s %-s" "$proto" "$creds_s" "$status" "$elapsed" "$info")"
  [[ "$status" == "SUKCES" ]] && success_count=$((success_count + 1))
done

log ""
log ">>> Udane logowania: $success_count / ${#summary_rows[@]}"
if (( success_count > 0 )); then
  log ">>> Sukcesy:"
  for row in "${summary_rows[@]}"; do
    IFS='|' read -r proto creds_s status elapsed info <<< "$row"
    [[ "$status" == "SUKCES" ]] && log "    - $proto -> $creds_s"
  done
fi
