# docker-audit

Read-only Sicherheits-Audit für Docker-Hosts unter SLES 12 / SLES 15.

- **`docker-audit.sh`**: prüft einen Host (Daemon-Konfiguration, Socket, `docker`-Gruppe) und alle Container
  (root/Host-UID, `--privileged`, Capabilities, Seccomp/AppArmor, no-new-privileges, Host-Namespaces,
  sensible Mounts, offene Ports, Limits). Ändert nichts am System.
- **`collect.sh`**: führt das Audit per SSH auf mehreren Servern aus und erzeugt Einzelberichte sowie eine Gesamt-CSV.
- **`HAERTUNG.md`**: Empfehlungen zur Härtung (daemon.json, Compose-Vorlage, SLES-Besonderheiten).

## Verwendung

```bash
# einzelner Server, ohne das Skript zu kopieren
ssh root@server 'bash -s' < docker-audit.sh
ssh root@server 'bash -s -- --csv' < docker-audit.sh

# mehrere Server (hosts.txt: ein Hostname pro Zeile)
./collect.sh hosts.txt            # Login als root
./collect.sh hosts.txt admin      # Login als admin, sudo NOPASSWD erforderlich
```

Exit-Code von `docker-audit.sh`: `0` = keine KRITISCH/HOCH-Befunde, `3` = mindestens ein solcher Befund,
`1` = Fehler (kein root, Docker nicht erreichbar).
