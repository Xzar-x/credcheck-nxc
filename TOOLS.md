# Tools

credscheck.sh is a Bash script. This file is plain documentation for humans -
it is not consumed by any package manager (unlike a Python `requirements.txt`).

## Required

```bash
sudo apt install -y nmap
pipx install git+https://github.com/Pennyw0rth/NetExec
```

Without these two, the script refuses to start.

## Optional - interactive clients

Used only by the "launch after finding credentials" feature at the end of a
run. Without a given tool installed, the script prints the exact install
command and a manual fallback command instead of failing.

| Protocol | Tool | Install |
|---|---|---|
| SMB | smbclient | `sudo apt install -y smbclient` |
| SSH | sshpass (optional, for auto-login) | `sudo apt install -y sshpass` |
| FTP | lftp | `sudo apt install -y lftp` |
| RDP | xfreerdp | `sudo apt install -y freerdp2-x11` |
| MSSQL / WMI | Impacket | `sudo apt install -y python3-impacket` |
| NFS | showmount | `sudo apt install -y nfs-common` |
| VNC | vncviewer | `sudo apt install -y tigervnc-viewer` |
| WinRM | evil-winrm | `gem install evil-winrm` (requires Ruby) |

LDAP needs no extra client - it's handled directly through `nxc ldap`.
