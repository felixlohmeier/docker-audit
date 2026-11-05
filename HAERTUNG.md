# Docker-Härtung auf SLES 12 / SLES 15

## 1. Bestandsaufnahme

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

Die CSV-Ausgaben mehrerer Server lassen sich zu einer Datei zusammenfügen
(bei weiteren Servern `--csv --no-header`) und in Excel filtern.

**So erkennt das Skript Root-Container:** Es liest die *tatsächliche* UID des
Container-Hauptprozesses auf dem Host aus `/proc/<pid>/status`. Die Angabe in
`docker inspect` allein reicht nicht. Damit wird auch sichtbar, ob userns-remap
greift: Ein Container läuft dann intern als root, auf dem Host aber z. B. als UID 100000.
Einschränkung: Geprüft wird nur der Hauptprozess. Bei Images wie nginx/apache läuft
der Master als root und die Worker als unprivilegierter Benutzer.

## 2. Reihenfolge der Maßnahmen (nach Wirkung/Aufwand)

| Prio | Maßnahme | Risiko für Bestand |
|---|---|---|
| 1 | `--privileged`, gemounteten `docker.sock`, TCP-API ohne TLS beseitigen | mittel, Einzelfallprüfung |
| 2 | Log-Rotation (`max-size`) setzen | keins |
| 3 | `no-new-privileges` als Daemon-Default | gering (sudo/su im Container geht nicht mehr) |
| 4 | Container ohne root (`user:`) + `cap_drop: ALL` | je Container testen |
| 5 | Ports nur an benötigte IPs binden | gering |
| 6 | Memory-/PIDs-Limits | gering |
| 7 | `icc: false`, `live-restore` | gering |
| 8 | userns-remap bzw. rootless | **hoch** (siehe unten) |

## 3. Daemon-Konfiguration `/etc/docker/daemon.json`

Empfohlener Ausgangspunkt (getestet mit Docker 29):

```json
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "no-new-privileges": true,
  "icc": false,
  "live-restore": true
}
```

Danach `systemctl restart docker`. Mit aktivem `live-restore` laufen die Container bei
künftigen Neustarts weiter. Beim ersten Neustart ist das noch nicht der Fall.

Hinweise:
- **SLES-Besonderheit:** Optionen können auch in `/etc/sysconfig/docker` (`DOCKER_OPTS=`)
  stehen. Doppelt gesetzte Optionen (dort *und* in daemon.json) verhindern den Start des Daemons.
- `icc: false` betrifft nur das Default-Bridge-Netz. Compose-Projekte nutzen eigene
  Netze und funktionieren weiter.
- `log-opts` gilt nur für **neu erstellte** Container (`docker compose up -d --force-recreate`).
- `live-restore` ist nicht mit Swarm-Mode kompatibel.
- `no-new-privileges` bricht Container, die intern `sudo`/`su` bzw. setuid-Binaries
  nutzen. `gosu`/`su-exec` (root → User) funktionieren weiterhin.

### userns-remap (`"userns-remap": "default"`)

Damit wird root im Container auf eine unprivilegierte Host-UID abgebildet, z. B. 100000.
Auf Serverebene ist das die wirksamste Absicherung gegen Root-Container. Folgen:
- Docker nutzt ein **neues Datenverzeichnis** (`/var/lib/docker/100000.100000`).
  Bestehende Container und Images sind danach **nicht mehr sichtbar** (im Test bestätigt).
  Images müssen neu gezogen und Container neu erstellt werden. Volumes müssen umziehen.
- Bind-Mounts brauchen passende Eigentümer (`chown 100000:100000 …`).
- Nicht kombinierbar mit `--privileged`, `--net=host` und `--pid=host`, außer der
  Container bekommt `--userns=host`.
- Voraussetzung: Einträge für `dockremap` in `/etc/subuid` und `/etc/subgid` (legt Docker selbst an).

→ Nur pro Server geplant einführen, am besten zuerst auf einem Testsystem.

## 4. Container härten (docker-compose)

```yaml
services:
  app:
    image: vendor/app:1.4.2          # feste Version statt latest
    user: "1000:1000"                # nicht root
    read_only: true
    tmpfs: [/tmp, /run]
    cap_drop: [ALL]
    # cap_add: [NET_BIND_SERVICE]    # nur falls Port < 1024 nötig
    security_opt:
      - no-new-privileges:true
    mem_limit: 512m
    pids_limit: 200
    ports:
      - "127.0.0.1:8080:8080"        # nur lokal, z. B. hinter Reverse-Proxy
```

Vorgehen bei Root-Containern (in dieser Reihenfolge prüfen):
1. Bietet das Image einen non-root-Modus an (Doku, Variante `-unprivileged` oder
   `-rootless`, z. B. `nginxinc/nginx-unprivileged`, Bitnami-Images)? Dann `user:` setzen
   und die Volume-Rechte anpassen.
2. Eigenes Image mit `USER` im Dockerfile ableiten.
3. Wenn root nicht zu vermeiden ist: `cap_drop: ALL` + minimale `cap_add`, `read_only`,
   `no-new-privileges`. Das begrenzt den Schaden erheblich.
4. Auf Serverebene: userns-remap (s. o.) oder Umstieg auf rootless Podman
   (in SLES 15 unterstützt).

## 5. Firewall-Falle auf SLES

Docker schreibt eigene iptables/nftables-Regeln. Mit `-p 8080:80` veröffentlichte Ports
sind deshalb **von außen erreichbar, auch wenn firewalld (SLES 15) bzw.
SuSEfirewall2 (SLES 12) sie blockieren sollte**. Gegenmaßnahmen:
- Ports an `127.0.0.1` oder eine interne IP binden (`"127.0.0.1:8080:80"`).
- Eigene Filterregeln in die Kette `DOCKER-USER` legen.

## 6. Zugriff auf Docker selbst

- Wer zur Gruppe `docker` gehört oder auf `docker.sock` zugreift, hat **root auf dem Host**.
  Die Gruppe also klein halten und regelmäßig prüfen (`getent group docker`).
- Den `docker.sock` nicht in Container mounten (Portainer, Traefik, Watchtower …). Falls
  doch nötig: Socket-Proxy mit Lesezugriff vorschalten (z. B. `tecnativa/docker-socket-proxy`).
- TCP-API (`-H tcp://`) nur mit `--tlsverify` und Client-Zertifikaten.

## 7. SLES 12

General Support ist beendet, Docker wird nur noch mit LTSS aktualisiert. Die Kernel 4.4
kennen manche Schutzmechanismen nicht oder nur eingeschränkt (z. B. erscheint
`NoNewPrivs` nicht in `/proc`). Das Skript zeigt dort `-`. Empfehlung: Migration
auf SLES 15 einplanen und bis dahin wenigstens Docker aus dem Containers-Module
aktuell halten (`zypper lu | grep -i docker`).

## 8. Ergänzend

Den kompletten CIS Docker Benchmark prüft `docker/docker-bench-security`. Er ist
umfangreicher, aber nicht auf SLES zugeschnitten (Audit-/Pfadregeln für
Debian/RHEL erzeugen dort Fehlalarme).
