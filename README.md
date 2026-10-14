# credscheck.sh-nxc

Prosty skrypt bash do szybkiego testowania danych uwierzytelniających na wielu protokołach sieciowych naraz, bazujący na NetExec (nxc): https://github.com/Pennyw0rth/NetExec

## Co robi

Jedna komenda zamiast ręcznego wpisywania nxc smb, nxc ftp, nxc ssh itd. osobno dla każdego protokołu.

Dwa tryby działania:

1. Test konkretnych danych logowania na wszystkich wspieranych protokołach:
   ./credscheck.sh.sh <target> <user> <pass>

2. Blind test - sprawdzenie domyślnych/pustych kont (anonymous, guest, null) na wszystkich protokołach:
   ./credscheck.sh.sh <target>

## Sprawdzane protokoły

smb, ssh, ftp, winrm, mssql, rdp, ldap, wmi, nfs, vnc

## Wymagania

Zobacz requirements.txt

## Instalacja

git clone https://github.com/TWOJ_USER/credscheck.sh-nxc.git
cd credscheck.sh-nxc
chmod +x credscheck.sh.sh

## Użycie

Test konkretnych credsów:
./credscheck.sh.sh 10.129.233.210 join SuperSecurePass123

Blind test (anonymous/guest/null):
./credscheck.sh.sh 10.129.233.210

Zapis wyników i filtrowanie trafień:
./credscheck.sh.sh 10.129.233.210 | tee results.txt
grep -E '\[\+\]' results.txt

## Legalność

Narzędzie przeznaczone wyłącznie do testów na infrastrukturze, do której masz wyraźną, pisemną autoryzację (własne laby, HTB, zakresy pentestów z podpisaną zgodą). Nieautoryzowane użycie jest nielegalne.

## Licencja

MIT
