#!/usr/bin/env bash
# credcheck.sh - sprawdzanie uwierzytelniania przez NetExec (nxc)
#
# Użycie:
#   ./credcheck.sh -t <target> -u <user> -p <pass> [opcje]
#   ./credcheck.sh -t <target> [opcje]  # zestaw prób anonymous/guest/null
#
# Opcje:
#   -t, --target        IP/host celu (wymagane)
#   -u, --user          nazwa użytkownika
#   -p, --pass          hasło (może być puste: -p "")
#   -m, --max-attempts  maksymalna liczba WYWOŁAŃ nxc (domyślnie 15)
#   --delay-min         minimalne opóźnienie w sekundach (domyślnie 1)
#   --delay-max         maksymalne opóźnienie w sekundach (domyślnie 3)
#   --protocols         protokoły oddzielone przecinkami
#   -o, --output        plik logu; hasła maskowane w zapisanym wyjściu
#   -y, --yes           pomiń potwierdzenie, gdy plan przekracza limit
#   -h, --help          pokaż pomoc
#
# UWAGA: używaj wyłącznie na własnej infrastrukturze lub z autoryzacją.

set -u
set -o pipefail

target=""
user=""
pass=""
user_set=0
pass_set=0
max_attempts=15
delay_min=1
delay_max=3
protocols_arg=""
output_file=""
auto_yes=0

print_help() {
  awk '/^#!/{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
}

need_value() {
  if [[ $# -lt 2 ]]; then
    echo "Błąd: $1 wymaga wartości." >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target)
      need_value "$@"; target="$2"; shift 2 ;;
    -u|--user)
      need_value "$@"; user="$2"; user_set=1; shift 2 ;;
    -p|--pass)
      need_value "$@"; pass="$2"; pass_set=1; shift 2 ;;
    -m|--max-attempts)
      need_value "$@"; max_attempts="$2"; shift 2 ;;
    --delay-min)
      need_value "$@"; delay_min="$2"; shift 2 ;;
    --delay-max)
      need_value "$@"; delay_max="$2"; shift 2 ;;
    --protocols)
      need_value "$@"; protocols_arg="$2"; shift 2 ;;
    -o|--output)
      need_value "$@"; output_file="$2"; shift 2 ;;
    -y|--yes) auto_yes=1; shift ;;
    -h|--help) print_help; exit 0 ;;
    *) echo "Nieznana opcja: $1" >&2; echo "Użyj -h / --help." >&2; exit 1 ;;
  esac
done

if [[ -z "$target" ]]; then
  echo "Błąd: brak celu (-t/--target)." >&2
  exit 1
fi

if ! [[ "$max_attempts" =~ ^[0-9]+$ ]] || (( 10#$max_attempts < 1 )); then
  echo "Błąd: --max-attempts musi być liczbą całkowitą >= 1." >&2
  exit 1
fi
max_attempts=$((10#$max_attempts))

valid_number() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}
if ! valid_number "$delay_min" || ! valid_number "$delay_max"; then
  echo "Błąd: opóźnienia muszą być nieujemnymi liczbami." >&2
  exit 1
fi
if ! awk -v a="$delay_min" -v b="$delay_max" 'BEGIN {exit !(a <= b)}'; then
  echo "Błąd: --delay-min nie może być większe niż --delay-max." >&2
  exit 1
fi

if (( user_set != pass_set )); then
  echo "Błąd: podaj jednocześnie -u i -p albo pomiń oba, aby użyć trybu blind." >&2
  exit 1
fi

if [[ -n "$protocols_arg" ]]; then
  IFS=',' read -r -a protocols <<< "$protocols_arg"
  if (( ${#protocols[@]} == 0 )); then
    echo "Błąd: lista protokołów jest pusta." >&2
    exit 1
  fi
  for i in "${!protocols[@]}"; do
    protocols[$i]="${protocols[$i]//[[:space:]]/}"
    if [[ -z "${protocols[$i]}" ]]; then
      echo "Błąd: pusta nazwa protokołu w --protocols." >&2
      exit 1
    fi
  done
else
  protocols=(smb ssh ftp winrm mssql rdp ldap wmi nfs vnc)
fi

declare -a users=() passwords=()
if (( user_set == 1 && pass_set == 1 )); then
  mode="Test podanych poświadczeń"
  users=("$user")
  passwords=("$pass")
else
  mode="Test anonymous/guest/null"
  users=(anonymous anonymous "" guest guest null)
  passwords=(anonymous "" "" guest "" null)
fi

planned_attempts=$(( ${#protocols[@]} * ${#users[@]} ))
run_attempts=$planned_attempts

if (( planned_attempts > max_attempts )); then
  echo "Plan: $planned_attempts wywołań nxc; twardy limit: $max_attempts."
  echo "Uwaga: limit dotyczy wywołań nxc, niekoniecznie prób wewnętrznych narzędzia."
  if (( auto_yes == 0 )); then
    read -r -p "Kontynuować z twardym limitem? [t/N]: " confirm
    if [[ ! "$confirm" =~ ^[TtYy]$ ]]; then
      echo "Przerwano przez użytkownika."
      exit 1
    fi
  fi
  run_attempts=$max_attempts
fi

if ! command -v nxc >/dev/null 2>&1; then
  echo "Błąd: 'nxc' nie jest zainstalowany lub nie jest w PATH." >&2
  exit 1
fi

if [[ -n "$output_file" ]]; then
  if ! : > "$output_file" 2>/dev/null; then
    echo "Błąd: nie można utworzyć/wyczyścić pliku logu: $output_file" >&2
    exit 1
  fi
fi

mask_pass() {
  local p="$1" len
  len=${#p}
  if (( len == 0 )); then
    printf '(puste)'
  else
    printf '%*s' "$len" '' | tr ' ' '*'
  fi
}

literal_replace() {
  local text="$1" needle="$2" replacement="$3" before rest
  [[ -z "$needle" ]] && { printf '%s' "$text"; return; }
  while [[ "$text" == *"$needle"* ]]; do
    before="${text%%"$needle"*}"
    printf '%s%s' "$before" "$replacement"
    rest="${text#*"$needle"}"
    text="$rest"
  done
  printf '%s' "$text"
}

log() {
  printf '%s\n' "$1"
  if [[ -n "$output_file" ]]; then
    printf '%s\n' "$1" >> "$output_file"
  fi
}

echo ">>> Tryb: $mode"
echo ">>> Cel: $target"
echo ">>> Protokoły: ${protocols[*]}"
echo ">>> Wywołania nxc: $run_attempts z $planned_attempts możliwych"
echo ">>> Opóźnienie: ${delay_min}-${delay_max}s"
[[ -n "$output_file" ]] && echo ">>> Log: $output_file (poświadczenia maskowane)"
echo

declare -a summary_rows=()
attempt_count=0
stop_all=0

for proto in "${protocols[@]}"; do
  for idx in "${!users[@]}"; do
    if (( attempt_count >= run_attempts )); then
      stop_all=1
      break
    fi

    u="${users[$idx]}"
    p="${passwords[$idx]}"
    p_masked="$(mask_pass "$p")"
    attempt_count=$((attempt_count + 1))
    log "######### [$attempt_count/$run_attempts] $proto -- $u:$p_masked #########"

    start_ts=$(date +%s)
    output=$(nxc "$proto" "$target" -u "$u" -p "$p" 2>&1)
    exit_code=$?
    end_ts=$(date +%s)
    elapsed=$((end_ts - start_ts))

    masked_output="$output"
    if [[ -n "$p" ]]; then
      masked_output="$(literal_replace "$masked_output" "$p" "$p_masked")"
    fi
    for secret in "${passwords[@]}"; do
      if [[ -n "$secret" ]]; then
        masked_output="$(literal_replace "$masked_output" "$secret" "$(mask_pass "$secret")")"
      fi
    done
    log "$masked_output"
    log ""

    status="NIEZNANY"
    error_info=""
    if echo "$output" | grep -qiE 'connection refused|connection error|timed? ?out|no route to host|network is unreachable|could not connect'; then
      status="BRAK POŁĄCZENIA"
      error_info=$(echo "$output" | grep -oiE 'connection refused|connection error|timed? ?out|no route to host|network is unreachable|could not connect' | head -1)
    elif (( exit_code != 0 )); then
      status="BŁĄD NXC"
      error_info="exit code $exit_code"
    elif echo "$output" | grep -qiE '\[\+\].*(Pwn3d!|logged in|login successful|authenticated|anonymous login)'; then
      status="PRAWDOPODOBNY SUKCES"
    elif echo "$output" | grep -qE '\[\+\]'; then
      # [+] bez rozpoznanego słowa kluczowego - prawdopodobny sukces (konwencja
      # nxc: [+] = udana autoryzacja), ale wymaga ręcznego potwierdzenia, bo nie
      # pasuje do znanych wzorców.
      status="SUKCES (NIEPOTWIERDZONY WZORZEC)"
    elif echo "$output" | grep -qE '\[-\]'; then
      status="ODRZUCONO / BRAK SUKCESU"
    fi

    summary_rows+=("$proto|$u:$p_masked|$status|${elapsed}s|$error_info")

    if (( attempt_count < run_attempts )); then
      delay=$(awk -v r="$RANDOM" -v min="$delay_min" -v max="$delay_max" \
        'BEGIN {srand(r); printf "%.2f", min + rand() * (max - min)}')
      log "Czekam ${delay}s przed kolejnym wywołaniem..."
      sleep "$delay"
      log ""
    fi
  done
  (( stop_all == 1 )) && break
done

if (( planned_attempts > run_attempts )); then
  log "Zatrzymano po $run_attempts wywołaniach nxc; pominięto $((planned_attempts-run_attempts)) kombinacji."
  log ""
fi

log "=================================================================="
log "PODSUMOWANIE"
log "=================================================================="
log "$(printf '%-8s %-25s %-24s %-8s %-s' "PROTO" "CREDS" "STATUS" "CZAS" "INFO")"
log "$(printf '%-8s %-25s %-24s %-8s %-s' "-----" "-----" "------" "----" "----")"

success_count=0
for row in "${summary_rows[@]}"; do
  IFS='|' read -r proto creds_s status elapsed info <<< "$row"
  log "$(printf '%-8s %-25s %-24s %-8s %-s' "$proto" "$creds_s" "$status" "$elapsed" "$info")"
  [[ "$status" == "PRAWDOPODOBNY SUKCES" || "$status" == "SUKCES (NIEPOTWIERDZONY WZORZEC)" ]] && success_count=$((success_count + 1))
done

log ""
log ">>> Prawdopodobne sukcesy: $success_count / ${#summary_rows[@]}"
log ">>> Statusy są heurystyczne; sprawdź pełny wynik modułu, jeśli wynik jest niejednoznaczny."
