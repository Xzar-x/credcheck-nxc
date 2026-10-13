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
#   -m, --max-attempts   TWARDY limit prób - skrypt zatrzyma się po jego osiągnięciu (domyślnie 15)
#   --delay-min           minimalne opóźnienie między próbami w sek. (domyślnie 1)
#   --delay-max           maksymalne opóźnienie między próbami w sek. (domyślnie 3)
#   --protocols           lista protokołów oddzielona przecinkami (domyślnie wszystkie)
#   -o, --output          zapisz pełny log do pliku (hasła maskowane)
#   -y, --yes             nie pytaj o potwierdzenie, gdy planowanych prób jest więcej niż limit
#   -h, --help            pokaż tę pomoc
#
# UWAGA: używaj wyłącznie na własnej infrastrukturze lub z wyraźną, pisemną autoryzacją.

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
      if [[ $# -lt 2 || "$2" == -* ]]; then echo "Błąd: $1 wymaga wartości."; exit 1; fi
      target="$2"; shift 2 ;;
    -u|--user)
      if [[ $# -lt 2 || "$2" == -* ]]; then echo "Błąd: $1 wymaga wartości."; exit 1; fi
      user="$2"; shift 2 ;;
    -p|--pass)
      if [[ $# -lt 2 || "$2" == -* ]]; then echo "Błąd: $1 wymaga wartości."; exit 1; fi
      pass="$2"; shift 2 ;;
    -m|--max-attempts)
      if [[ $# -lt 2 || "$2" == -* ]]; then echo "Błąd: $1 wymaga wartości."; exit 1; fi
      max_attempts="$2"; shift 2 ;;
    --delay-min)
      if [[ $# -lt 2 || "$2" == -* ]]; then echo "Błąd: $1 wymaga wartości."; exit 1; fi
      delay_min="$2"; shift 2 ;;
    --delay-max)
      if [[ $# -lt 2 || "$2" == -* ]]; then echo "Błąd: $1 wymaga wartości."; exit 1; fi
      delay_max="$2"; shift 2 ;;
    --protocols)
      if [[ $# -lt 2 || "$2" == -* ]]; then echo "Błąd: $1 wymaga wartości."; exit 1; fi
      protocols_arg="$2"; shift 2 ;;
    -o|--output)
      if [[ $# -lt 2 || "$2" == -* ]]; then echo "Błąd: $1 wymaga wartości."; exit 1; fi
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
  echo "Błąd: brak celu (-t/--target)."
  echo "Użyj -h / --help, żeby zobaczyć składnię."
  exit 1
fi

if ! [[ "$max_attempts" =~ ^[0-9]+$ ]] || (( max_attempts < 1 )); then
  echo "Błąd: --max-attempts musi być liczbą całkowitą >= 1."
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
    "null null"
  )
fi

planned_attempts=$(( ${#protocols[@]} * ${#creds[@]} ))

# Jeśli plan przekracza limit, pytamy o zgodę; po zgodzie TWARDO tniemy do limitu.
run_attempts=$planned_attempts
if (( planned_attempts > max_attempts )); then
  echo ">>> Tryb: $mode"
  echo ">>> Cel: $target"
  echo ">>> Planowanych prób (wszystkie kombinacje): $planned_attempts"
  echo "⚠️  UWAGA: przekracza to ustawiony limit ($max_attempts)."
  echo "   Na środowiskach z polityką lockoutu zbyt wiele prób może zablokować"
  echo "   testowane konto lub wywołać alarmy/throttling po stronie usługi."
  echo "   Skrypt wykona maksymalnie $max_attempts prób i się zatrzyma."
  if (( auto_yes == 0 )); then
    read -p "   Kontynuować z tym twardym limitem? [t/N]: " confirm
    if [[ ! "$confirm" =~ ^[TtYy]$ ]]; then
      echo "Przerwano przez użytkownika."
      exit 1
    fi
  else
    echo "   (--yes podane, kontynuuję automatycznie)"
  fi
  run_attempts=$max_attempts
  echo
fi

echo ">>> Tryb: $mode"
echo ">>> Cel: $target"
echo ">>> Protokoły: ${protocols[*]}"
echo ">>> Próby do wykonania: $run_attempts (z $planned_attempts możliwych, twardy limit: $max_attempts)"
echo ">>> Opóźnienie między próbami: ${delay_min}-${delay_max}s (jitter)"
[[ -n "$output_file" ]] && echo ">>> Log zapisywany do: $output_file (hasła maskowane)"
echo

# Sprawdzamy dostępność nxc PRZED jakimkolwiek dotknięciem systemu plików (output_file)
if ! command -v nxc >/dev/null 2>&1; then
  echo "❌ Błąd: 'nxc' nie jest zainstalowany lub nie jest w PATH."
  echo "   Jeśli korzystasz z venv, aktywuj je najpierw (np. komendą 'bb')."
  exit 1
fi

# Dopiero teraz, po walidacji wszystkiego, dotykamy pliku wyjściowego
if [[ -n "$output_file" ]]; then
  if ! : > "$output_file" 2>/dev/null; then
    echo "❌ Błąd: nie można utworzyć/wyczyścić pliku logu: $output_file"
    exit 1
  fi
fi

# Maskowanie hasła do logów/podsumowania: pokazujemy tylko długość i gwiazdki
mask_pass() {
  local p="$1" len
  len=${#p}
  if (( len == 0 )); then
    echo "(puste)"
  else
    printf '*%.0s' $(seq 1 "$len")
  fi
}

log() {
  echo "$1"
  [[ -n "$output_file" ]] && echo "$1" >> "$output_file"
}

declare -a summary_rows=()
attempt_count=0

outer_break=0
for proto in "${protocols[@]}"; do
  (( outer_break == 1 )) && break
  for cred in "${creds[@]}"; do
    if (( attempt_count >= run_attempts )); then
      outer_break=1
      break
    fi

    read -r u p <<< "$cred"
    attempt_count=$((attempt_count + 1))
    p_masked=$(mask_pass "$p")

    log "######### [$attempt_count/$run_attempts] $proto -- $u:$p_masked #########"

    start_ts=$(date +%s.%N)
    output=$(nxc "$proto" "$target" -u "$u" -p "$p" 2>&1)
    exit_code=$?
    end_ts=$(date +%s.%N)
    elapsed=$(awk "BEGIN {printf \"%.2f\", $end_ts - $start_ts}")

    # Maskujemy hasło także w surowym outpucie nxc, zanim trafi do logu
    if [[ -n "$p" ]]; then
      masked_output="${output//$p/$p_masked}"
    else
      masked_output="$output"
    fi
    log "$masked_output"
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

    summary_rows+=("$proto|$u:$p_masked|$status|${elapsed}s|$error_info")

    if (( attempt_count < run_attempts )); then
      delay=$(awk -v min="$delay_min" -v max="$delay_max" 'BEGIN{srand(); printf "%.2f", min+rand()*(max-min)}')
      log "⏳ Czekam ${delay}s przed kolejną próbą..."
      sleep "$delay"
      log ""
    fi
  done
done

if (( planned_attempts > run_attempts )); then
  log "ℹ️  Zatrzymano po $run_attempts próbach (twardy limit --max-attempts)."
  log "   Pozostało niewykonanych kombinacji: $(( planned_attempts - run_attempts ))"
  log ""
fi

log "=================================================================="
log " PODSUMOWANIE"
log "=================================================================="
log "$(printf "%-8s %-25s %-16s %-8s %-s" "PROTO" "CREDS" "STATUS" "CZAS" "INFO")"
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
  log ">>> Sukcesy (hasła zamaskowane w logu - sprawdź pełny output nxc powyżej przy potrzebie):"
  for row in "${summary_rows[@]}"; do
    IFS='|' read -r proto creds_s status elapsed info <<< "$row"
    [[ "$status" == "SUKCES" ]] && log "    - $proto -> $creds_s"
  done
fi
