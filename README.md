# credscheck-nxc

Skrypt bash do błyskawicznego sprawdzania i weryfikacji poświadczeń (oraz kont domyślnych/anonimowych) na wielu protokołach sieciowych naraz, zintegrowany z [NetExec (nxc)](https://github.com/Pennyw0rth/NetExec).

Przed wywołaniem `nxc`, skrypt wykonuje szybki skan wstępny Nmapem (`TCP connect`), filtrując tylko te usługi, których porty są rzeczywiście **OPEN**. Na koniec prezentuje czytelne podsumowanie i pozwala na **bezpośrednie, interaktywne zalogowanie się** do potwierdzonych serwisów.

---

## Główne możliwości

* **Filtracja Nmap**: Testuje tylko te protokoły, które faktycznie nasłuchują na celu (oszczędność czasu i unikanie zbędnego hałasu w sieci).
* **Dwa tryby pracy**:
  1. **Weryfikacja podanych poświadczeń**: `-u <user> -p <pass>` na wszystkich otwartych usługach.
  2. **Blind test**: automatyczne sprawdzenie kont `anonymous`, `guest`, `null` oraz domyślnych haseł serwisowych (np. `sa` dla MSSQL).
* **Interaktywny launcher**:
  * **SMB**: listuje udziały (`-L`), a następnie pyta, do którego udziału chcesz wejść interaktywnie (`smbclient`).
  * **SSH**: automatyczne logowanie przez `sshpass` (lub zwykłe `ssh`).
  * **FTP**: auto-login przez `lftp` z automatyczną korektą adresów PASV i odpornością na wolne bannery DNS.
  * **RDP**: uruchomienie `xfreerdp` w stabilnym trybie z obsługą domen.
  * **WinRM / WMI**: logowanie przez `evil-winrm` lub `impacket-wmiexec`.
  * **MSSQL**: interaktywna konsola `impacket-mssqlclient`.
  * **NFS / LDAP**: automatyczny listing eksportów (`showmount`) oraz użytkowników domeny (`nxc ldap`).
* **Maskowanie haseł (`--mask`)**: bezpieczne ukrywanie wrażliwych danych w logach i na ekranie.

---

## Sprawdzane protokoły

`smb` (445), `ssh` (22), `ftp` (21), `winrm` (5985, 5986), `mssql` (1433), `rdp` (3389), `ldap` (389, 636, 3268, 3269), `wmi` (135, 139, 445), `nfs` (111, 2049), `vnc` (5900-5903)

---

## Wymagania

* `bash`, `nmap`, `netexec` (`nxc`)
* Opcjonalni klienci do sesji interaktywnych:
  * `smbclient`
  * `sshpass`, `openssh-client`
  * `lftp`
  * `freerdp2-x11` lub `freerdp3-x11` (`xfreerdp`)
  * `evil-winrm`
  * `python3-impacket` (dla MSSQL i WMI)

---

## Instalacja

```bash
git clone https://github.com/TWOJ_USER/credcheck-nxc.git
cd credcheck-nxc
chmod +x credscheck.sh

# Utworzenie skrótu w systemie (opcjonalnie):
ln -sf "$(pwd)/credscheck.sh" ~/.local/bin/credscheck
```

---

## Użycie

```bash
# Test konkretnych poświadczeń na celu:
credscheck -t 10.129.99.64 -u john -p 'SuperSecurePass123'

# Wybór tylko wybranych protokołów:
credscheck -t 10.129.99.64 -u john -p 'SuperSecurePass123' --protocols smb,ssh,ftp

# Blind test (konta domyślne / anonimowe):
credscheck -t 10.129.99.64

# Zapis do pliku logu z maskowaniem haseł:
credscheck -t 10.129.99.64 -u admin -p 'P@ssw0rd!' --mask -o scan.log
```

---

## Legalność

Narzędzie przeznaczone wyłącznie do legalnych testów bezpieczeństwa na infrastrukturze, do której posiadasz wyraźną zgodę (własne laby, platformy edukacyjne typu Hack The Box / TryHackMe, zlecenia pentestowe z podpisanym zakresem prac).
