# docker-audit

Read-only Sicherheits-Audit für Docker-Hosts unter SLES 12 / SLES 15.

- **`docker-audit.sh`**: prüft einen Host (Daemon-Konfiguration, Socket, `docker`-Gruppe) und alle Container
  (root/Host-UID, `--privileged`, Capabilities, Seccomp/AppArmor, no-new-privileges, Host-Namespaces,
  sensible Mounts, offene Ports, Limits). Ändert nichts am System.
- **`HAERTUNG.md`**: Empfehlungen zur Härtung (daemon.json, Compose-Vorlage, SLES-Besonderheiten).

## Verwendung

```bash
# Skript auf dem Server abgelegt (z. B. im eigenen Home), Aufruf mit sudo
sudo bash ~/docker-audit.sh
sudo bash ~/docker-audit.sh > ~/docker-audit-$(hostname -s).txt        # Bericht in Datei
sudo bash ~/docker-audit.sh --csv > ~/docker-audit-$(hostname -s).csv  # CSV (Trennzeichen ';')

# remote, ohne das Skript auf den Server zu kopieren
ssh root@server 'bash -s' < docker-audit.sh                                  # als root
ssh user@server 'sudo -n bash -s' < docker-audit.sh                          # sudo ohne Passwort (NOPASSWD)
ssh -t user@server "sudo bash -c $(printf '%q' "$(cat docker-audit.sh)")"    # sudo mit Passwortabfrage
```

Bei `bash -s` ist die Standardeingabe schon durch das Skript belegt; sudo kann dort kein Passwort
abfragen. Die letzte Variante übergibt das Skript deshalb als Argument, und `-t` stellt ein Terminal für die
Passwortabfrage bereit. Ihre Ausgabe enthält Windows-Zeilenenden und die Passwortabfrage selbst. Für
einen Bericht in einer Datei besser die NOPASSWD-Variante oder den Aufruf auf dem Server nutzen.

Exit-Code von `docker-audit.sh`: `0` = keine KRITISCH/HOCH-Befunde, `3` = mindestens ein solcher Befund,
`1` = Abbruch (kein root, Docker nicht installiert, Docker-Dienst nicht aktiv oder nicht erreichbar).

Da das Skript als root läuft, sollte es nur für dich beschreibbar sein (`chmod go-w docker-audit.sh`).
