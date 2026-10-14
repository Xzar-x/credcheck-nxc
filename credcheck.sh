#!/usr/bin/env bash
# credcheck.sh - skan Nmap portów wybranych protokołów, potem NetExec (nxc)
# Użycie: ./credcheck.sh -t <target> [-u user -p pass] [--protocols smb,ssh] [-o log]
# Opcje: -t/--target, -u/--user, -p/--pass, -m/--max-attempts,
# --delay-min, --delay-max, --protocols, -o/--output, -y/--yes,
# --timeout, --no-launch, --mask, -h/--help
# Używaj wyłącznie na własnej infrastrukturze lub za zgodą właściciela.
# Przeznaczone głównie do labów HTB / własnych testów.

set -u
set -o pipefail

# Kolory ANSI — wyłączane automatycznie gdy stdout nie jest terminalem
if [[ -t 1 ]]; then
	C_RESET='\033[0m'
	C_BOLD='\033[1m'
	C_RED='\033[1;31m'
	C_GREEN='\033[1;32m'
	C_YELLOW='\033[1;33m'
	C_CYAN='\033[1;36m'
	C_WHITE='\033[1;37m'
	C_BG_GREEN='\033[48;5;22m'
	C_BG_YELLOW='\033[48;5;94m'
	C_DIM='\033[2m'
else
	C_RESET='' C_BOLD='' C_RED='' C_GREEN='' C_YELLOW=''
	C_CYAN='' C_WHITE='' C_BG_GREEN='' C_BG_YELLOW='' C_DIM=''
fi

target="" user="" pass="" user_set=0 pass_set=0
max_attempts=15 delay_min=0 delay_max=0.3 protocols_arg="" output_file=""
auto_yes=0 no_mask=1 no_launch=0 nxc_timeout=45

help() {
	cat <<'HELP'
credcheck.sh - najpierw sprawdza Nmapem porty TCP, potem uruchamia nxc tylko
dla protokołów, dla których znaleziono przypisany port OPEN.

-t, --target        IP/host celu (wymagane)
-u, --user          nazwa użytkownika
-p, --pass          hasło (może być puste: -p "")
-m, --max-attempts  maks. liczba wywołań nxc (domyślnie 15)
--delay-min         minimalne opóźnienie w sekundach (domyślnie 0)
--delay-max         maksymalne opóźnienie w sekundach (domyślnie 0.3)
--protocols         protokoły oddzielone przecinkami
-o, --output        plik logu
-y, --yes           pomiń potwierdzenie przy przekroczeniu limitu
--timeout SEC       timeout pojedynczego wywołania nxc w sekundach (domyślnie 45)
-n, --no-launch     nie pytaj o uruchomienie interaktywnego klienta na końcu
--mask              maskuj hasła w logu/terminalu (domyślnie WYŁĄCZONE - hasła
                    są jawne; użyj tej flagi przed udostępnieniem logu komuś
                    innemu lub wrzuceniem go gdziekolwiek poza swój dysk)
-h, --help          pomoc

Przykłady:
  ./credcheck.sh -t 10.10.11.123
  ./credcheck.sh -t 10.10.11.123 -u admin -p 'P@ssw0rd!'
  ./credcheck.sh -t 10.10.11.123 --protocols smb,ssh,ftp --timeout 30 -n
HELP
}

need_value() { if (($# < 2)); then
	echo "Błąd: $1 wymaga wartości." >&2
	exit 1
fi; }
while (($#)); do
	case "$1" in
	-t | --target)
		need_value "$@"
		target="$2"
		shift 2
		;;
	-u | --user)
		need_value "$@"
		user="$2"
		user_set=1
		shift 2
		;;
	-p | --pass)
		need_value "$@"
		pass="$2"
		pass_set=1
		shift 2
		;;
	-m | --max-attempts)
		need_value "$@"
		max_attempts="$2"
		shift 2
		;;
	--delay-min)
		need_value "$@"
		delay_min="$2"
		shift 2
		;;
	--delay-max)
		need_value "$@"
		delay_max="$2"
		shift 2
		;;
	--protocols)
		need_value "$@"
		protocols_arg="$2"
		shift 2
		;;
	-o | --output)
		need_value "$@"
		output_file="$2"
		shift 2
		;;
	--timeout)
		need_value "$@"
		nxc_timeout="$2"
		shift 2
		;;
	-y | --yes)
		auto_yes=1
		shift
		;;
	-n | --no-launch)
		no_launch=1
		shift
		;;
	--mask)
		no_mask=0
		shift
		;;
	-h | --help)
		help
		exit 0
		;;
	*)
		echo "Nieznana opcja: $1 (użyj --help)." >&2
		exit 1
		;;
	esac
done
[[ -n "$target" ]] || {
	echo "Błąd: wymagane -t/--target." >&2
	exit 1
}
[[ "$max_attempts" =~ ^[0-9]+ ]] && ((10#$max_attempts >= 1)) || {
	echo "Błąd: --max-attempts musi być >= 1." >&2
	exit 1
}
max_attempts=$((10#$max_attempts))
[[ "$nxc_timeout" =~ ^[0-9]+ ]] && ((10#$nxc_timeout >= 5)) || {
	echo "Błąd: --timeout musi być liczbą >= 5." >&2
	exit 1
}
nxc_timeout=$((10#$nxc_timeout))
valid_num() { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
valid_num "$delay_min" && valid_num "$delay_max" || {
	echo "Błąd: opóźnienia muszą być liczbami nieujemnymi." >&2
	exit 1
}
awk -v a="$delay_min" -v b="$delay_max" 'BEGIN{exit !(a<=b)}' || {
	echo "Błąd: delay-min > delay-max." >&2
	exit 1
}
((user_set == pass_set)) || {
	echo "Błąd: podaj jednocześnie -u i -p albo pomiń oba." >&2
	exit 1
}

if [[ -n "$protocols_arg" ]]; then
	IFS=',' read -r -a protocols <<<"$protocols_arg"
	for i in "${!protocols[@]}"; do
		protocols[$i]="${protocols[$i]//[[:space:]]/}"
		protocols[$i]="${protocols[$i],,}"
		[[ -n "${protocols[$i]}" ]] || {
			echo "Błąd: pusta nazwa protokołu." >&2
			exit 1
		}
	done
else
	protocols=(smb ssh ftp winrm mssql rdp ldap wmi nfs vnc)
fi

# Typowe porty TCP. OPEN to tylko filtr wstępny, nie dowód, że działa właściwy protokół.
declare -A proto_ports=(
	[smb]="445" [ssh]="22" [ftp]="21" [winrm]="5985,5986"
	[mssql]="1433" [rdp]="3389" [ldap]="389,636,3268,3269"
	[wmi]="135,139,445" [nfs]="111,2049" [vnc]="5900-5903"
)
declare -A port_set=()
for proto in "${protocols[@]}"; do
	[[ -n "${proto_ports[$proto]+x}" ]] || {
		echo "Błąd: nieobsługiwany protokół '$proto'. Dozwolone: ${!proto_ports[*]}" >&2
		exit 1
	}
	IFS=',' read -r -a pp <<<"${proto_ports[$proto]}"
	for port in "${pp[@]}"; do port_set["$port"]=1; done
done
port_list="$(printf '%s\n' "${!port_set[@]}" | sort -n | paste -sd, -)"

command -v nmap >/dev/null 2>&1 || {
	echo "Błąd: brak nmap w PATH." >&2
	exit 1
}
command -v nxc >/dev/null 2>&1 || {
	echo "Błąd: brak nxc w PATH." >&2
	exit 1
}
if [[ -n "$output_file" ]]; then
	: >"$output_file" 2>/dev/null || {
		echo "Błąd: nie można zapisać logu: $output_file" >&2
		exit 1
	}
fi

strip_ansi() { sed 's/\x1b\[[0-9;]*m//g' <<<"$1"; }
log() {
	printf '%b\n' "$1"
	[[ -n "$output_file" ]] && printf '%s\n' "$(strip_ansi "$1")" >>"$output_file"
}
clog() {
	printf '%b\n' "${1}${2}${C_RESET}"
	[[ -n "$output_file" ]] && printf '%s\n' "$(strip_ansi "$2")" >>"$output_file"
}

clog "$C_CYAN" ">>> Nmap sprawdza w tle porty TCP: $port_list"
clog "$C_CYAN" ">>> Cel: $target"
scan_tmp="$(mktemp)" || exit 1
trap 'rm -f "$scan_tmp"' EXIT
nmap -n -Pn -sT --open -p "$port_list" -oG - "$target" >"$scan_tmp" 2>&1 &
nmap_pid=$!
wait "$nmap_pid"
nmap_rc=$?
if ((nmap_rc != 0)); then
	printf '%b\n' "${C_RED}Błąd Nmap (kod $nmap_rc): ${C_RESET}" >&2
	cat "$scan_tmp" >&2
	exit 1
fi

open_ports=""
while IFS= read -r line; do
	[[ "$line" == *"Ports:"* ]] || continue
	field="${line#*Ports: }"
	IFS=',' read -r -a entries <<<"$field"
	for entry in "${entries[@]}"; do
		if [[ "$entry" =~ ^[[:space:]]*([0-9]+)/open/tcp/ ]]; then
			port="${BASH_REMATCH[1]}"
			[[ ",$open_ports," == *,$port,* ]] || open_ports+="${open_ports:+,}$port"
		fi
	done
done <"$scan_tmp"
if [[ -z "$open_ports" ]]; then
	clog "$C_YELLOW" ">>> Brak wykrytych otwartych portów z wybranej listy. Nie uruchamiam nxc."
	[[ -n "$output_file" ]] && printf 'Cel: %s\nSkanowane porty: %s\nWynik: brak OPEN\n' "$target" "$port_list" >>"$output_file"
	exit 0
fi
clog "$C_GREEN" ">>> Otwarte porty TCP: $open_ports"

declare -a active_protocols=()
for proto in "${protocols[@]}"; do
	found=0
	IFS=',' read -r -a pp <<<"${proto_ports[$proto]}"
	for port in "${pp[@]}"; do
		if [[ "$port" == *-* ]]; then
			lo=$((10#${port%-*}))
			hi=$((10#${port#*-}))
			for n in $(seq "$lo" "$hi"); do
				[[ ",$open_ports," == *,$n,* ]] && found=1
			done
		else
			[[ ",$open_ports," == *,$port,* ]] && found=1
		fi
	done
	if ((found)); then
		active_protocols+=("$proto")
	else
		clog "$C_DIM" ">>> Pomijam $proto — przypisane porty nie są OPEN."
	fi
done
((${#active_protocols[@]})) || {
	echo ">>> Nic do sprawdzenia."
	exit 0
}
protocols=("${active_protocols[@]}")

# Protokoły, dla których anonymous/guest/null nie mają sensu protokołowego
# (SSH/WinRM/RDP wymagają realnego konta - nie ma w nich pojęcia "anonimowy
# login"). W trybie blind dostają tylko jedną sondę sprawdzającą dostępność
# usługi, zamiast pełnej listy 6 prób, które i tak nie mają szans powieść się
# inaczej niż przez czysty przypadek błędnej konfiguracji.
declare -A blind_minimal=([ssh]=1 [winrm]=1 [rdp]=1)

# Dodatkowe, powszechnie znane domyślne credsy producenta/instalatora - celowo
# TYLKO dla mssql (SQL Server auth rzadko ma politykę lockoutu). Świadomie
# pomijam SMB/WinRM/RDP - tam konta zwykle żyją w Active Directory z
# polityką lockoutu, a zgadywanie "admin:admin" niesie realne ryzyko
# zablokowania czyjegoś konta, nie tylko techniczną porażkę próby.
declare -A extra_defaults=([mssql]="sa:sa sa: sa:Password123 sa:admin")

if ((user_set)); then
	mode="Test podanych poświadczeń"
else
	mode="Test anonymous/guest/null (SSH/WinRM/RDP: tylko sonda dostępności)"
fi

get_creds_for_proto() {
	local proto="$1"
	if ((user_set)); then
		proto_users=("$user")
		proto_passwords=("$pass")
	elif [[ -n "${blind_minimal[$proto]:-}" ]]; then
		proto_users=("")
		proto_passwords=("")
	else
		proto_users=(anonymous anonymous "" guest guest null)
		proto_passwords=(anonymous "" "" guest "" null)
		if [[ -n "${extra_defaults[$proto]:-}" ]]; then
			local pair u2 p2
			for pair in ${extra_defaults[$proto]}; do
				IFS=':' read -r u2 p2 <<<"$pair"
				proto_users+=("$u2")
				proto_passwords+=("$p2")
			done
		fi
	fi
}

planned=0
for proto in "${protocols[@]}"; do
	get_creds_for_proto "$proto"
	planned=$((planned + ${#proto_users[@]}))
done
run_count=$planned
if ((planned > max_attempts)); then
	echo "Plan po filtracji: $planned wywołań nxc; limit: $max_attempts."
	if ((auto_yes == 0)); then
		read -r -p "Kontynuować z limitem? [t/N]: " confirm
		[[ "$confirm" =~ ^[TtYy] ]] || {
			echo "Przerwano."
			exit 1
		}
	fi
	run_count=$max_attempts
fi

mask_pass() {
	local p="$1"
	if [[ -z "$p" ]]; then printf '(puste)'; else printf '%*s' "${#p}" '' | tr ' ' '*'; fi
}

# Sortuje tablicę (przez nameref) malejąco wg długości stringów - czysty bash,
# bez pipe'owania przez zewnętrzne narzędzia (bezpieczne nawet dla sekretów
# zawierających spacje/znaki specjalne). Potrzebne, żeby maskowanie krótszego
# hasła (np. "pass") nie psuło fragmentu dłuższego hasła (np. "password").
sort_by_length_desc() {
	local -n arr_ref=$1
	local i j tmp n=${#arr_ref[@]}
	for ((i = 1; i < n; i++)); do
		tmp="${arr_ref[i]}"
		j=$((i - 1))
		while ((j >= 0)) && ((${#arr_ref[j]} < ${#tmp})); do
			arr_ref[j + 1]="${arr_ref[j]}"
			j=$((j - 1))
		done
		arr_ref[j + 1]="$tmp"
	done
}
literal_replace() {
	local text="$1" needle="$2" replacement="$3" before rest
	[[ -z "$needle" ]] && {
		printf '%s' "$text"
		return
	}
	while [[ "$text" == *"$needle"* ]]; do
		before="${text%%"$needle"*}"
		printf '%s%s' "$before" "$replacement"
		rest="${text#*"$needle"}"
		text="$rest"
	done
	printf '%s' "$text"
}

log "${C_CYAN}Tryb: ${C_RESET}$mode"
log "${C_CYAN}Cel:${C_RESET}$target"
log "${C_CYAN}Otwarte porty:${C_RESET}$open_ports"
log "${C_CYAN}Protokoły po filtracji:${C_RESET} ${protocols[*]}"
log "${C_CYAN}Wywołania nxc: ${C_RESET}$run_count z $planned"
log "${C_CYAN}Opóźnienie:${C_RESET}${delay_min}-${delay_max}s"
log "${C_CYAN}Timeout nxc: ${C_RESET}${nxc_timeout}s"
if [[ -n "$output_file" ]]; then
	if ((no_mask)); then
		log "${C_CYAN}Log: ${C_RESET}$output_file ${C_YELLOW}(hasła JAWNE - użyj --mask, jeśli ten plik może trafić gdzieś dalej) ${C_RESET}"
	else
		log "${C_CYAN}Log: ${C_RESET}$output_file (hasła maskowane)"
	fi
fi

declare -a rows=()
declare -a raw_protos=()
declare -a raw_users=()
declare -a raw_passes=()
declare -a raw_statuses=()

attempt=0
for proto in "${protocols[@]}"; do
	get_creds_for_proto "$proto"
	for idx in "${!proto_users[@]}"; do
		((attempt < run_count)) || break
		u="${proto_users[$idx]}"
		p="${proto_passwords[$idx]}"
		if ((no_mask)); then pm="${p:-(puste)}"; else pm="$(mask_pass "$p")"; fi
		((attempt += 1))
		probe_note=""
		((user_set == 0)) && [[ -n "${blind_minimal[$proto]:-}" ]] && probe_note=" ${C_DIM}(sonda dostępności, nie zgadywanie credsów)${C_RESET}"
		log "${C_BOLD}${C_WHITE}######### [$attempt/$run_count] $proto -- $u:$pm #########${probe_note}${C_RESET}"
		start=$(date +%s)
		# timeout chroni przed wiszącymi połączeniami (szczególnie HTB VPN / wolna sieć)
		output=$(timeout "${nxc_timeout}s" nxc "$proto" "$target" -u "$u" -p "$p" 2>&1)
		rc=$?
		end=$(date +%s)
		masked="$output"
		if ((no_mask == 0)); then
			mask_targets=()
			for secret in "$p" "${proto_passwords[@]}"; do
				[[ -z "$secret" ]] && continue
				already=0
				for seen in "${mask_targets[@]:-}"; do [[ "$seen" == "$secret" ]] && {
					already=1
					break
				}; done
				((already)) || mask_targets+=("$secret")
			done
			sort_by_length_desc mask_targets
			for secret in "${mask_targets[@]}"; do masked="$(literal_replace "$masked" "$secret" "$(mask_pass "$secret")")"; done
		fi
		log "$masked"
		log ""
		status="NIEZNANY"
		info=""
		if ((rc == 124)); then
			status="TIMEOUT"
			info="przekroczono ${nxc_timeout}s"
		elif grep -qiE 'connection refused|connection error|timed? ?out|no route to host|network is unreachable|could not connect' <<<"$output"; then
			status="BRAK POŁĄCZENIA"
			info="$(grep -oiE 'connection refused|connection error|timed? ?out|no route to host|network is unreachable|could not connect' <<<"$output" | head -1)"
		elif ((rc != 0)); then
			status="BŁĄD NXC"
			info="exit code $rc"
		elif grep -qiE '\[\+\].*(Pwn3d!|logged in|login successful|authenticated|anonymous login)' <<<"$output"; then
			status="SUKCES - WZORZEC POTWIERDZONY"
		elif grep -qE '\[\+\]' <<<"$output"; then
			status="MOŻLIWY SUKCES - WYMAGA WERYFIKACJI"
		elif grep -qE '\[-\]' <<<"$output"; then
			status="ODRZUCONO / BRAK SUKCESU"
		fi
		rows+=("$proto|$u:$pm|$status|$((end - start))s|$info")

		raw_protos+=("$proto")
		raw_users+=("$u")
		raw_passes+=("$p")
		raw_statuses+=("$status")

		if ((attempt < run_count)); then
			delay=$(awk -v r="$RANDOM" -v min="$delay_min" -v max="$delay_max" 'BEGIN{srand(r); printf "%.2f", min+rand()*(max-min)}')
			log "Czekam ${delay}s..."
			sleep "$delay"
		fi
	done
	((attempt >= run_count)) && break
done
if ((planned > run_count)); then log "Zatrzymano po $run_count wywołaniach; pominięto $((planned - run_count)) kombinacji."; fi
log "${C_BOLD}${C_CYAN}==================================================================${C_RESET}"
log "${C_BOLD}${C_WHITE}                        PODSUMOWANIE${C_RESET}"
log "${C_BOLD}${C_CYAN}==================================================================${C_RESET}"
header="$(printf '%-8s %-25s %-32s %-8s %-s' PROTO CREDS STATUS CZAS INFO)"
log "${C_BOLD}${C_WHITE}${header}${C_RESET}"
log "${C_DIM}$(printf '%0.s─' {1..85})${C_RESET}"
confirmed=0 uncertain=0
for row in "${rows[@]}"; do
	IFS='|' read -r proto creds status elapsed info <<<"$row"
	line="$(printf '%-8s %-25s %-32s %-8s %-s' "$proto" "$creds" "$status" "$elapsed" "$info")"
	if [[ "$status" == "SUKCES - WZORZEC POTWIERDZONY" ]]; then
		log "${C_BG_GREEN}${C_WHITE}${C_BOLD}${line}${C_RESET}"
		((confirmed += 1))
	elif [[ "$status" == "MOŻLIWY SUKCES - WYMAGA WERYFIKACJI" ]]; then
		log "${C_BG_YELLOW}${C_BOLD}${line}${C_RESET}"
		((uncertain += 1))
	elif [[ "$status" == "ODRZUCONO / BRAK SUKCESU" ]]; then
		log "${C_RED}${line}${C_RESET}"
	elif [[ "$status" == "BRAK POŁĄCZENIA" ]] || [[ "$status" == "BŁĄD NXC" ]] || [[ "$status" == "TIMEOUT" ]]; then
		log "${C_DIM}${line}${C_RESET}"
	else
		log "$line"
	fi
done
log "${C_DIM}$(printf '%0.s─' {1..85})${C_RESET}"
if ((confirmed > 0)); then
	log "${C_BG_GREEN}${C_WHITE}${C_BOLD} ✔ Sukcesy z potwierdzonym wzorcem: $confirmed / ${#rows[@]} ${C_RESET}"
else
	log "${C_DIM}  Sukcesy z potwierdzonym wzorcem: $confirmed / ${#rows[@]}${C_RESET}"
fi
if ((uncertain > 0)); then
	log "${C_BG_YELLOW}${C_BOLD} ⚠ Możliwe sukcesy wymagające ręcznej weryfikacji: $uncertain / ${#rows[@]} ${C_RESET}"
else
	log "${C_DIM}  Możliwe sukcesy wymagające ręcznej weryfikacji: $uncertain / ${#rows[@]}${C_RESET}"
fi
log "${C_CYAN}Uwaga: ${C_RESET} znaczenie \"[+]\" różni się między protokołami; weryfikuj wyniki ręcznie."

declare -a valid_indices=()
for i in "${!raw_statuses[@]}"; do
	st="${raw_statuses[$i]}"
	if [[ "$st" == "SUKCES - WZORZEC POTWIERDZONY" ]] || [[ "$st" == "MOŻLIWY SUKCES - WYMAGA WERYFIKACJI" ]]; then
		valid_indices+=("$i")
	fi
done

if ((${#valid_indices[@]} > 0)) && ((no_launch == 0)); then
	echo ""
	clog "$C_GREEN" ">>> Wykryto pasujące poświadczenia lub potencjalne sukcesy!"
	read -r -p "Czy chcesz uruchomić zewnętrzne narzędzie i zalogować się do któregoś z serwisów? [t/N]: " launch_choice
	if [[ "$launch_choice" =~ ^[TtYy] ]]; then
		echo ""
		clog "$C_CYAN" "Wybierz pozycję do połączenia:"

		for opt_num in "${!valid_indices[@]}"; do
			idx="${valid_indices[$opt_num]}"
			p_proto="${raw_protos[$idx]}"
			p_user="${raw_users[$idx]}"
			p_pass="${raw_passes[$idx]}"
			p_stat="${raw_statuses[$idx]}"
			display_u="${p_user:-<pusty>}"
			display_p="${p_pass:-<puste>}"
			printf "  [%d] Protokół: %s | Użytkownik: %s | Hasło: %s (%s)\n" "$((opt_num + 1))" "$p_proto" "$display_u" "$display_p" "$p_stat"
		done

		read -r -p "Wpisz numer opcji (lub wciśnij Enter, aby anulować): " choice_idx
		if [[ "$choice_idx" =~ ^[0-9]+ ]] && ((choice_idx >= 1 && choice_idx <= ${#valid_indices[@]})); then
			selected_array_idx="${valid_indices[$((choice_idx - 1))]}"
			s_proto="${raw_protos[$selected_array_idx]}"
			s_user="${raw_users[$selected_array_idx]}"
			s_pass="${raw_passes[$selected_array_idx]}"

			echo ""
			clog "$C_CYAN" ">>> Wybrano: protokół $s_proto dla celu $target (użytkownik: ${s_user:-<pusty>})"

			case "$s_proto" in
			rdp)
				if command -v xfreerdp >/dev/null 2>&1; then
					clog "$C_GREEN" "Uruchamiam xfreerdp..."
					if [[ -n "$s_pass" ]]; then
						xfreerdp /v:"$target" /u:"$s_user" /p:"$s_pass" /dynamic-resolution +clipboard /cert:ignore
					else
						xfreerdp /v:"$target" /u:"$s_user" /dynamic-resolution +clipboard /cert:ignore
					fi
				else
					clog "$C_RED" "Błąd: Narzędzie 'xfreerdp' nie zostało znalezione w PATH."
					clog "$C_YELLOW" "Zainstaluj je poleceniem:"
					echo "  sudo apt update && sudo apt install -y freerdp2-x11"
				fi
				;;
			ssh)
				# Preferuj sshpass (automatyczne podanie hasła) – przyspiesza workflow HTB.
				# Fallback do zwykłego ssh (hasło wpisywane ręcznie).
				if [[ -n "$s_pass" ]] && command -v sshpass >/dev/null 2>&1; then
					clog "$C_GREEN" "Uruchamiam ssh + sshpass (hasło podawane automatycznie)..."
					if [[ -n "$s_user" ]]; then
						sshpass -p "$s_pass" ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no "${s_user}@${target}"
					else
						sshpass -p "$s_pass" ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password -o PubkeyAuthentication=no "$target"
					fi
				elif command -v ssh >/dev/null 2>&1; then
					if [[ -n "$s_pass" ]]; then
						clog "$C_YELLOW" "Uwaga: 'sshpass' nie znaleziony – hasło trzeba będzie wpisać ręcznie."
						clog "$C_YELLOW" "Aby automatycznie podawać hasło, zainstaluj:"
						echo "  sudo apt update && sudo apt install -y sshpass"
					fi
					clog "$C_GREEN" "Uruchamiam ssh (wpisz hasło ręcznie)..."
					if [[ -n "$s_user" ]]; then
						ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null "${s_user}@${target}"
					else
						ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null "$target"
					fi
				else
					clog "$C_RED" "Błąd: Narzędzie 'ssh' nie zostało znalezione w PATH."
					clog "$C_YELLOW" "Zainstaluj: sudo apt install openssh-client"
					if [[ -n "$s_pass" ]]; then
						clog "$C_YELLOW" "Dodatkowo do automatycznego hasła: sudo apt install sshpass"
					fi
				fi
				;;
			smb)
				if command -v smbclient >/dev/null 2>&1; then
					clog "$C_GREEN" "Uruchamiam smbclient..."
					# Nowoczesne smbclient obsługuje --password= (bezpieczniejsze przy znakach specjalnych niż user%pass)
					if smbclient --help 2>&1 | grep -q -- '--password'; then
						smbclient -L "//$target" -U "$s_user" --password="$s_pass"
					else
						# Fallback dla starszych wersji
						smbclient -L "//$target" -U "$s_user%$s_pass"
					fi
				else
					clog "$C_RED" "Błąd: Narzędzie 'smbclient' nie zostało znalezione w PATH."
					clog "$C_YELLOW" "Zainstaluj je poleceniem:"
					echo "  sudo apt update && sudo apt install -y smbclient"
				fi
				;;
			ftp)
				if ! command -v lftp >/dev/null 2>&1; then
					clog "$C_RED" "Błąd: Narzędzie 'lftp' nie zostało znalezione w PATH."
					clog "$C_YELLOW" "Zainstaluj je poleceniem: sudo apt update && sudo apt install -y lftp"
				else
					clog "$C_GREEN" "Uruchamiam lftp (auto‑login, sesja interaktywna)..."
					# Konfiguracja lftp:
					# - net:timeout 20: serwery FTP (np. ProFTPD) wykonują reverse DNS na IP klienta
					#   VPN (10.10.x.x), co w labach HTB powoduje opóźnienie ~10s przed wysłaniem bannera 220.
					#   Wcześniejszy timeout 5s powodował natychmiastowy błąd "max-retries exceeded".
					# - net:max-retries 2: zapobiega ucinaniu sesji przy chwilowym lagu.
					# - ftp:fix-pasv-address yes: koryguje błędne prywatne IP zwracane przez serwer w PASV.
					# - ftp:auto-passive-mode yes: domyślnie używa PASV, z fallbackiem do trybu aktywnego (PORT).
					# - ftp:ssl-allow no: pomija niepotrzebne próby negocjacji TLS dla czystego FTP.
					lftp_tune="set net:timeout 20; set net:max-retries 2; set net:reconnect-interval-base 2; set ftp:ssl-allow no; set ftp:fix-pasv-address yes; set ftp:auto-passive-mode yes;"
					if [[ -n "$s_user" ]]; then
						if [[ "$s_pass" == *","* ]]; then
							# Gdy hasło zawiera przecinek, przełącznik -u user,pass traktuje to błędnie.
							# Komenda lftp 'user' przyjmuje osobne argumenty i poprawnie obsługuje przecinki.
							lftp -e "${lftp_tune} user \"${s_user//\"/\\\"}\" \"${s_pass//\"/\\\"}\";" "$target"
						else
							lftp -u "$s_user","$s_pass" -e "$lftp_tune" "$target"
						fi
					else
						lftp -e "$lftp_tune" "$target"
					fi
				fi
				;;
			vnc)
				if command -v vncviewer >/dev/null 2>&1; then
					clog "$C_GREEN" "Uruchamiam vncviewer..."
					# Większość vncviewer i tak zapyta o hasło interaktywnie
					vncviewer "$target"
				else
					clog "$C_RED" "Błąd: Narzędzie 'vncviewer' nie zostało znalezione w PATH."
					clog "$C_YELLOW" "Zainstaluj je poleceniem: sudo apt install tigervnc-viewer"
				fi
				;;
			winrm)
				if command -v evil-winrm >/dev/null 2>&1; then
					clog "$C_GREEN" "Uruchamiam evil-winrm..."
					if [[ -n "$s_pass" ]]; then
						evil-winrm -i "$target" -u "$s_user" -p "$s_pass"
					else
						evil-winrm -i "$target" -u "$s_user"
					fi
				else
					clog "$C_RED" "Błąd: Narzędzie 'evil-winrm' nie zostało znalezione w PATH."
					clog "$C_YELLOW" "Zainstaluj je poleceniem:"
					echo "  gem install evil-winrm"
				fi
				;;
			mssql)
				if command -v impacket-mssqlclient >/dev/null 2>&1; then
					clog "$C_GREEN" "Uruchamiam impacket-mssqlclient..."
					# Format user:pass@host - dwukropek w haśle psuje parser.
					# Gdy wykryjemy ':', ostrzegamy i próbujemy i tak (użytkownik może poprawić ręcznie).
					if [[ "$s_pass" == *":"* ]]; then
						clog "$C_YELLOW" "Uwaga: hasło zawiera ':' - format user:pass@host może się popsuć."
						clog "$C_YELLOW" "Rozważ ręczne: impacket-mssqlclient '$s_user'@$target  (i podaj hasło)"
					fi
					impacket-mssqlclient "${s_user}:${s_pass}@${target}"
				else
					clog "$C_RED" "Błąd: Narzędzie 'impacket-mssqlclient' nie zostało znalezione w PATH."
					clog "$C_YELLOW" "Zainstaluj pakiety Impacket:"
					echo "  pip install impacket"
				fi
				;;
			*)
				clog "$C_YELLOW" "Brak predefiniowanego klienta interaktywnego dla protokołu: $s_proto"
				clog "$C_CYAN" "Możesz użyć nxc: nxc $s_proto $target -u \"$s_user\" -p \"$s_pass\""
				;;
			esac
		else
			echo "Anulowano lub wybrano niepoprawny numer."
		fi
	fi
fi
