#!/bin/bash
# =====================================================================
# docker-audit.sh - Read-only Sicherheits-Audit fuer Docker-Hosts
#                   (fuer SLES 12 / SLES 15, bash >= 4.3)
#
# Das Skript AENDERT NICHTS. Es liest nur die Docker-Konfiguration,
# `docker info` / `docker inspect` und /proc/<pid>/status der
# Container-Prozesse. Benoetigt root (Docker-Socket, /proc fremder PIDs).
#
# Aufruf:
#   sudo ./docker-audit.sh                   Klartext-Bericht
#   sudo ./docker-audit.sh --csv             CSV (eine Zeile je Container)
#   sudo ./docker-audit.sh --csv --no-header
#
# Remote, ohne das Skript zu kopieren:
#   ssh root@server 'bash -s' < docker-audit.sh
#   ssh root@server 'bash -s -- --csv' < docker-audit.sh
#
# Schweregrade: KRITISCH > HOCH > MITTEL > NIEDRIG
# Exit-Code: 0 = keine KRITISCH/HOCH-Befunde, 3 = mind. ein solcher Befund
#            oder ein nicht auswertbarer Container
# =====================================================================
# (kein "set -u": bash 4.3 auf SLES 12 behandelt leere Arrays sonst als Fehler)
export LC_ALL=C

MODE=report
HEADER=1
for a in "$@"; do
  case "$a" in
    --csv)       MODE=csv ;;
    --no-header) HEADER=0 ;;
    -h|--help)   sed -n '2,24p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           echo "Unbekannte Option: $a" >&2; exit 2 ;;
  esac
done

HOST=$(hostname -f 2>/dev/null || hostname)

die() { echo "[$HOST] FEHLER: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ]              || die "Bitte als root ausfuehren (sudo)."
command -v docker >/dev/null 2>&1 || die "docker ist nicht installiert."
DOCKER_INFO=$(docker info 2>&1)   || die "Docker-Daemon nicht erreichbar."

# --------------------------------------------------------------------
# Hilfsfunktionen
# --------------------------------------------------------------------
SEVS="KRITISCH HOCH MITTEL NIEDRIG"
declare -A TOTAL=([KRITISCH]=0 [HOCH]=0 [MITTEL]=0 [NIEDRIG]=0)

rank() { case "$1" in KRITISCH) echo 4;; HOCH) echo 3;; MITTEL) echo 2;; NIEDRIG) echo 1;; *) echo 0;; esac; }
out()  { [ "$MODE" = report ] && printf '%s\n' "$*"; return 0; }
ok()   { [ "$MODE" = report ] && printf '  %-11s %s\n' "[OK]" "$1"; return 0; }
info() { [ "$MODE" = report ] && printf '  %-11s %s\n' "[INFO]" "$1"; return 0; }
hfind() {   # Host-Befund: hfind SCHWERE "Text"
  TOTAL[$1]=$(( ${TOTAL[$1]} + 1 ))
  [ "$MODE" = report ] && printf '  %-11s %s\n' "[$1]" "$2"
  return 0
}
dinfo() { docker info --format "$1" 2>/dev/null; }
csvq()  { local s=${1//\"/\"\"}; printf '"%s"' "$s"; }

# --------------------------------------------------------------------
# Host-Daten sammeln
# --------------------------------------------------------------------
osr() { sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" /etc/os-release 2>/dev/null; }
OS=$(osr PRETTY_NAME);  [ -n "$OS" ] || OS=unbekannt
OS_VER=$(osr VERSION_ID)

DVER=$(docker version --format '{{.Server.Version}}' 2>/dev/null); [ -n "$DVER" ] || DVER=unbekannt
LOGDRV=$(dinfo '{{.LoggingDriver}}')
STORDRV=$(dinfo '{{.Driver}}')
LIVE=$(dinfo '{{.LiveRestoreEnabled}}')
SECOPTS=$(dinfo '{{range .SecurityOptions}}{{.}} {{end}}')
if [ -z "$SECOPTS" ]; then   # Fallback fuer sehr alte Docker-Versionen
  SECOPTS=$(printf '%s\n' "$DOCKER_INFO" | grep -Eio 'apparmor|seccomp|selinux|userns|rootless' | sort -u | tr '\n' ' ')
fi
secopt_has() { case " $SECOPTS " in *"$1"*) return 0;; esac; return 1; }

if secopt_has rootless; then USERNS=rootless
elif secopt_has userns; then USERNS=userns-remap
else USERNS=nein; fi

# Gesamte Daemon-Konfiguration (daemon.json, SLES-sysconfig, systemd, Prozess)
DAEMON_JSON=/etc/docker/daemon.json
CFG="$(cat "$DAEMON_JSON" 2>/dev/null)
$(grep -E '^[[:space:]]*DOCKER_OPTS' /etc/sysconfig/docker 2>/dev/null)
$(systemctl cat docker.service 2>/dev/null | grep -E '^[[:space:]]*ExecStart')
$(ps -C dockerd -o args= 2>/dev/null)"
cfg_has() { printf '%s\n' "$CFG" | grep -Eq -- "$1"; }

DAEMON_NNP=0
cfg_has '"no-new-privileges"[[:space:]]*:[[:space:]]*true|--no-new-privileges' && DAEMON_NNP=1

HOSTCAP=$(awk '/^CapEff:/{print $2; exit}' /proc/1/status 2>/dev/null)

# --------------------------------------------------------------------
# Host-Pruefungen
# --------------------------------------------------------------------
host_checks() {
  out "=================================================================="
  out " Docker-Audit  $HOST   $(date '+%Y-%m-%d %H:%M')"
  out "=================================================================="
  out "  Betriebssystem : $OS"
  out "  Docker-Version : $DVER"
  out "  Storage/Logging: ${STORDRV:-?} / ${LOGDRV:-?}"
  out "  Security-Opts  : ${SECOPTS:-keine}"
  out ""
  out "--- Host / Daemon -------------------------------------------------"

  case "$OS_VER" in
    12*) hfind MITTEL "SLES $OS_VER: General Support beendet (nur noch LTSS), Docker-Pakete veraltet. Migration auf SLES 15 planen." ;;
  esac

  local major=${DVER%%.*}
  if [[ "$major" =~ ^[0-9]+$ ]] && [ "$major" -lt 20 ]; then
    hfind HOCH "Docker $DVER ist stark veraltet (< 20.10). Aus dem SUSE-Containers-Module aktualisieren."
  fi

  case "$USERNS" in
    rootless)     ok "Daemon laeuft rootless." ;;
    userns-remap) ok "userns-remap aktiv (root im Container ist nicht root auf dem Host)." ;;
    *)            hfind MITTEL "Weder userns-remap noch rootless: UID 0 im Container = UID 0 auf dem Host." ;;
  esac

  if secopt_has seccomp; then
    case "$SECOPTS" in
      *profile=unconfined*) hfind HOCH "Seccomp-Default-Profil des Daemons ist 'unconfined'." ;;
      *)                    ok "Seccomp aktiv." ;;
    esac
  else
    hfind HOCH "Seccomp ist im Daemon nicht aktiv."
  fi

  if secopt_has apparmor || secopt_has selinux; then
    ok "AppArmor/SELinux im Daemon aktiv."
  else
    hfind MITTEL "Weder AppArmor noch SELinux aktiv (SLES 15: 'systemctl status apparmor' pruefen)."
  fi

  if [ "$DAEMON_NNP" = 1 ]; then ok "no-new-privileges ist Daemon-Default."
  else hfind MITTEL "no-new-privileges ist nicht als Daemon-Default gesetzt."; fi

  if cfg_has '"icc"[[:space:]]*:[[:space:]]*false|--icc=false'; then ok "icc=false (Default-Bridge isoliert)."
  else hfind NIEDRIG "icc nicht deaktiviert: Container im Default-Bridge-Netz erreichen sich gegenseitig."; fi

  if [ "$LIVE" = true ]; then ok "live-restore aktiv."
  else hfind NIEDRIG "live-restore nicht aktiv: Container stoppen bei Neustart/Update des Daemons."; fi

  if [ "$LOGDRV" = json-file ] && ! cfg_has 'max-size'; then
    hfind MITTEL "Logging-Driver json-file ohne max-size: Container-Logs wachsen unbegrenzt."
  fi

  # Docker-API ueber TCP?
  local tcpl
  tcpl=$(ss -ltnp 2>/dev/null | grep -E 'dockerd' | awk '{print $4}' | tr '\n' ' ')
  if cfg_has 'tcp://' || [ -n "$tcpl" ]; then
    if cfg_has 'tlsverify'; then
      hfind NIEDRIG "Docker-API per TCP mit TLS-Client-Auth erreichbar ($tcpl). Zertifikate/Zugriff pruefen."
    else
      hfind KRITISCH "Docker-API per TCP OHNE tlsverify erreichbar ($tcpl) = root-Zugriff ueber das Netz!"
    fi
  else
    ok "Docker-API nur ueber Unix-Socket."
  fi

  # Socket-Rechte
  local sock=/var/run/docker.sock sperm sown sgrp
  if [ -S "$sock" ]; then
    read -r sperm sown sgrp < <(stat -Lc '%a %U %G' "$sock")
    case "$sperm" in
      *[1-7]) hfind KRITISCH "docker.sock ist fuer alle Benutzer zugreifbar (Rechte $sperm)." ;;
      *)      ok "docker.sock: $sperm $sown:$sgrp" ;;
    esac
  fi

  # Gruppe docker
  local dgrp
  dgrp=$(getent group docker 2>/dev/null | cut -d: -f4)
  if [ -n "$dgrp" ]; then
    hfind MITTEL "Mitglieder der Gruppe 'docker' haben faktisch root-Rechte: $dgrp"
  else
    ok "Gruppe 'docker' hat keine Mitglieder."
  fi

  # daemon.json
  if [ -f "$DAEMON_JSON" ]; then
    if [ -n "$(find "$DAEMON_JSON" \( -perm -020 -o -perm -002 \) 2>/dev/null)" ] || \
       [ "$(stat -c %U "$DAEMON_JSON")" != root ]; then
      hfind HOCH "$DAEMON_JSON ist nicht root-eigen oder von Gruppe/allen beschreibbar."
    fi
  else
    info "Keine $DAEMON_JSON vorhanden, alle Daemon-Defaults aktiv."
  fi
  out ""
}

# --------------------------------------------------------------------
# Container-Pruefungen
# --------------------------------------------------------------------
# Hinweis: Felder, die null sein koennen (z. B. bei docker-compose), sind mit
# {{if}} abgesichert - 'len'/'join' auf null bricht das Template sonst ab.
FMT='{{.Name}}|{{.Config.Image}}|{{.State.Running}}|{{.State.Pid}}|{{.Config.User}}|{{.HostConfig.Privileged}}|{{.HostConfig.NetworkMode}}|{{.HostConfig.PidMode}}|{{.HostConfig.IpcMode}}|{{.HostConfig.UsernsMode}}|{{.HostConfig.ReadonlyRootfs}}|{{if .HostConfig.CapAdd}}{{join .HostConfig.CapAdd ","}}{{end}}|{{if .HostConfig.CapDrop}}{{join .HostConfig.CapDrop ","}}{{end}}|{{if .HostConfig.SecurityOpt}}{{join .HostConfig.SecurityOpt ","}}{{end}}|{{.HostConfig.Memory}}|{{.HostConfig.PidsLimit}}|{{range .Mounts}}{{.Source}}:{{.Destination}}:{{if .RW}}rw{{else}}ro{{end}},{{end}}|{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{.HostIp}}:{{.HostPort}}->{{$p}},{{end}}{{end}}|{{if .HostConfig.Devices}}{{len .HostConfig.Devices}}{{else}}0{{end}}'

DANGEROUS_CAPS=" ALL SYS_ADMIN SYS_MODULE SYS_PTRACE SYS_RAWIO SYS_BOOT SYS_TIME DAC_READ_SEARCH NET_ADMIN MAC_ADMIN MAC_OVERRIDE BPF PERFMON "
N_CONT=0; N_RUN=0; N_ROOT=0; N_ERR=0
ROOT_LIST=()

audit_container() {
  local id=$1 line
  if ! line=$(docker inspect --format "$FMT" "$id" 2>&1); then
    # Nie stillschweigend ueberspringen: Fehler sichtbar melden
    local cname err f
    cname=$(docker inspect --format '{{.Name}}' "$id" 2>/dev/null); cname=${cname#/}
    [ -n "$cname" ] || cname=${id:0:12}
    err=$(printf '%s' "$line" | tr '\n' ' ')
    N_CONT=$((N_CONT + 1)); N_ERR=$((N_ERR + 1))
    if [ "$MODE" = report ]; then
      printf '\n>>> %s  [NICHT AUSWERTBAR]\n  %-11s %s\n' "$cname" "[FEHLER]" "docker inspect fehlgeschlagen: $err"
    else
      for f in "$HOST" "$OS" "$DVER" "$USERNS" "$cname" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "" "FEHLER"; do
        csvq "$f"; printf ';'
      done
      csvq "docker inspect fehlgeschlagen: $err"; printf '\n'
    fi
    return
  fi
  local name image running pid user priv netmode pidmode ipcmode usernsmode rofs \
        capadd capdrop secopt mem pids mounts ports ndev
  IFS='|' read -r name image running pid user priv netmode pidmode ipcmode usernsmode rofs \
                  capadd capdrop secopt mem pids mounts ports ndev <<<"$line"
  name=${name#/}
  N_CONT=$((N_CONT + 1))

  local F_SEV=() F_MSG=() maxr=0
  addf() {
    F_SEV+=("$1"); F_MSG+=("$2")
    TOTAL[$1]=$(( ${TOTAL[$1]} + 1 ))
    local r; r=$(rank "$1"); [ "$r" -gt "$maxr" ] && maxr=$r
    return 0
  }

  # ---- Laufzeitwerte aus /proc (nur laufende Container) ----
  local huid=- seccomp=- nnp=- aa=- capeff=-
  if [ "$running" = true ] && [ -r "/proc/$pid/status" ]; then
    N_RUN=$((N_RUN + 1))
    huid=$(awk '/^Uid:/{print $3; exit}' "/proc/$pid/status")
    seccomp=$(awk '/^Seccomp:/{print $2; exit}' "/proc/$pid/status")
    nnp=$(awk '/^NoNewPrivs:/{print $2; exit}' "/proc/$pid/status")   # fehlt bei Kernel < 4.10 (SLES 12)
    capeff=$(awk '/^CapEff:/{print $2; exit}' "/proc/$pid/status")
    aa=$(tr -d '\0' < "/proc/$pid/attr/current" 2>/dev/null)
    [ -n "$seccomp" ] || seccomp=-
    [ -n "$nnp" ] || nnp=-
    [ -n "$aa" ] || aa=-
  fi

  # ---- Root? ----
  local cfg_root=0
  case "$user" in ""|0|0:*|root|root:*) cfg_root=1 ;; esac

  if [ "$priv" = true ]; then
    addf KRITISCH "--privileged: voller Zugriff auf Host-Devices und alle Capabilities."
  fi

  if [ "$huid" = 0 ]; then
    addf HOCH "Hauptprozess laeuft als root (Host-UID 0)."
    N_ROOT=$((N_ROOT + 1)); ROOT_LIST+=("$name")
  elif [ "$huid" != - ] && [ "$cfg_root" = 1 ]; then
    addf NIEDRIG "root im Container, per userns auf Host-UID $huid gemappt."
  elif [ "$huid" = - ] && [ "$cfg_root" = 1 ] && [ "$USERNS" = nein ]; then
    addf MITTEL "(gestoppt) Kein USER konfiguriert, wuerde als root starten."
    N_ROOT=$((N_ROOT + 1)); ROOT_LIST+=("$name (gestoppt)")
  fi

  if [ "$priv" != true ] && [ "$capeff" != - ] && [ -n "$HOSTCAP" ] && [ "$capeff" = "$HOSTCAP" ]; then
    addf HOCH "Prozess besitzt alle Capabilities des Hosts (CapEff=$capeff)."
  fi

  # ---- Host-Namespaces ----
  [ "$netmode" = host ] && addf HOCH "network=host: teilt den Netzwerk-Stack des Hosts."
  [ "$pidmode" = host ] && addf HOCH "pid=host: sieht und beeinflusst alle Host-Prozesse."
  [ "$ipcmode" = host ] && addf HOCH "ipc=host: teilt IPC/Shared Memory mit dem Host."
  [ "$usernsmode" = host ] && [ "$USERNS" = userns-remap ] && addf MITTEL "userns=host: userns-remap fuer diesen Container abgeschaltet."

  # ---- Capabilities ----
  local c cc
  if [ -n "$capadd" ]; then
    IFS=',' read -ra _caps <<<"$capadd"
    for c in "${_caps[@]}"; do
      cc=${c#CAP_}
      case "$DANGEROUS_CAPS" in
        *" $cc "*) addf HOCH "Gefaehrliche Capability hinzugefuegt: $cc" ;;
        *)         addf NIEDRIG "Capability hinzugefuegt: $cc" ;;
      esac
    done
  fi
  case ",$capdrop," in
    *,ALL,*|*,all,*|*,CAP_ALL,*) ;;
    *) [ "$priv" != true ] && addf NIEDRIG "Kein cap_drop: ALL (nur benoetigte Capabilities erlauben)." ;;
  esac

  # ---- Seccomp / AppArmor / no-new-privileges ----
  case "$secopt" in
    *seccomp=unconfined*|*seccomp:unconfined*) addf HOCH "Seccomp explizit deaktiviert (seccomp=unconfined)." ;;
    *) [ "$seccomp" = 0 ] && [ "$priv" != true ] && addf HOCH "Prozess laeuft ohne Seccomp-Filter." ;;
  esac
  if secopt_has apparmor; then
    case "$secopt" in
      *apparmor=unconfined*|*apparmor:unconfined*) addf MITTEL "AppArmor explizit deaktiviert (apparmor=unconfined)." ;;
      *) [ "$aa" = unconfined ] && [ "$priv" != true ] && addf MITTEL "Prozess laeuft ohne AppArmor-Profil." ;;
    esac
  fi
  local nnp_set=0
  case "$secopt" in *no-new-privileges*false*) ;; *no-new-privileges*) nnp_set=1 ;; esac
  [ "$nnp" = 1 ] && nnp_set=1
  [ "$nnp" = - ] && [ "$DAEMON_NNP" = 1 ] && nnp_set=1
  [ "$nnp_set" = 0 ] && addf MITTEL "no-new-privileges nicht gesetzt (setuid-Eskalation moeglich)."

  # ---- Ressourcen / Dateisystem ----
  [ "$rofs" != true ] && addf NIEDRIG "Root-Dateisystem nicht read-only."
  [ "$mem" = 0 ] && addf MITTEL "Kein Memory-Limit."
  case "$pids" in ""|0|-1|"<nil>"|"<no value>") addf NIEDRIG "Kein PIDs-Limit (Fork-Bomb-Schutz)." ;; esac
  [ "${ndev:-0}" -gt 0 ] 2>/dev/null && addf MITTEL "$ndev Host-Device(s) durchgereicht."

  # ---- Mounts ----
  local m mode rest src sens_list=""
  IFS=',' read -ra _mnts <<<"$mounts"
  for m in "${_mnts[@]}"; do
    [ -n "$m" ] || continue
    mode=${m##*:}; rest=${m%:*}; src=${rest%%:*}
    case "$src" in
      *docker.sock|*containerd.sock|*podman.sock|/run/docker|/var/run/docker|/run|/var/run)
        addf KRITISCH "Container-Runtime-Socket gemountet ($src, $mode) = root auf dem Host."
        sens_list+="$src:$mode " ;;
      /var/lib/docker/volumes/*) ;;   # benannte Volumes
      /|/etc|/etc/*|/root|/root/*|/boot|/boot/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/home|/var/lib/docker|/var/lib/docker/*|/usr|/lib*|/bin|/sbin)
        if [ "$mode" = rw ]; then addf HOCH "Sensibler Host-Pfad beschreibbar gemountet: $src"
        else addf MITTEL "Sensibler Host-Pfad gemountet (ro): $src"; fi
        sens_list+="$src:$mode " ;;
    esac
  done

  # ---- Ports ----
  local p hp hip open_ports=""
  IFS=',' read -ra _ports <<<"$ports"
  for p in "${_ports[@]}"; do
    [ -n "$p" ] || continue
    hp=${p%%->*}; hip=${hp%:*}
    case "$hip" in ""|0.0.0.0|::|"[::]") open_ports+="${p} " ;; esac
  done
  [ -n "$open_ports" ] && addf MITTEL "Ports auf allen Interfaces (umgeht firewalld/SuSEfirewall2!): ${open_ports% }"

  # ---- Image ----
  case "$image" in
    *@sha256:*) ;;
    *:latest) addf NIEDRIG "Image mit Tag 'latest' (nicht reproduzierbar)." ;;
    *) case "${image##*/}" in *:*) ;; *) addf NIEDRIG "Image ohne Tag (= latest)." ;; esac ;;
  esac

  # ---- Ausgabe ----
  local smode=$seccomp
  case "$seccomp" in 0) smode=aus;; 1) smode=strict;; 2) smode=filter;; esac
  local status=gestoppt; [ "$running" = true ] && status=laeuft
  local maxsev=OK s i
  for s in $SEVS; do [ "$(rank "$s")" = "$maxr" ] && maxsev=$s; done

  if [ "$MODE" = report ]; then
    printf '\n>>> %s  (%s)  [%s]\n' "$name" "$image" "$status"
    printf '    USER=%s  Host-UID=%s  Seccomp=%s  NoNewPrivs=%s  AppArmor=%s\n' \
           "${user:-<leer>}" "$huid" "$smode" "$nnp" "$aa"
    if [ ${#F_SEV[@]} -eq 0 ]; then
      printf '  %-11s %s\n' "[OK]" "keine Befunde"
    fi
    for s in $SEVS; do
      for i in "${!F_SEV[@]}"; do
        [ "${F_SEV[$i]}" = "$s" ] && printf '  %-11s %s\n' "[$s]" "${F_MSG[$i]}"
      done
    done
  else
    local all="" sep=""
    for s in $SEVS; do
      for i in "${!F_SEV[@]}"; do
        [ "${F_SEV[$i]}" = "$s" ] && { all+="$sep$s: ${F_MSG[$i]}"; sep=" | "; }
      done
    done
    local f
    for f in "$HOST" "$OS" "$DVER" "$USERNS" "$name" "$image" "$status" "${user:-}" "$huid" \
             "$priv" "$netmode" "$pidmode" "$capadd" "$capdrop" "$smode" "$nnp" "$aa" "$rofs" \
             "$mem" "$pids" "${open_ports% }" "${sens_list% }" "$maxsev"; do
      csvq "$f"; printf ';'
    done
    csvq "$all"; printf '\n'
  fi
}

# --------------------------------------------------------------------
# Hauptprogramm
# --------------------------------------------------------------------
if [ "$MODE" = csv ] && [ "$HEADER" = 1 ]; then
  echo '"host";"os";"docker_version";"userns";"container";"image";"status";"config_user";"host_uid";"privileged";"network";"pid_mode";"cap_add";"cap_drop";"seccomp";"no_new_privs";"apparmor";"readonly_rootfs";"memory_limit";"pids_limit";"offene_ports";"sensible_mounts";"max_schwere";"befunde"'
fi

host_checks

out "--- Container -----------------------------------------------------"
while read -r cid; do
  [ -n "$cid" ] && audit_container "$cid"
done < <(docker ps -aq --no-trunc 2>/dev/null)

if [ "$MODE" = report ]; then
  [ "$N_CONT" -eq 0 ] && info "Keine Container vorhanden."
  out ""
  out "=================================================================="
  out " Zusammenfassung $HOST"
  out "=================================================================="
  out "  Container gesamt: $N_CONT  (laufend: $N_RUN)"
  out "  Als root:         $N_ROOT ${ROOT_LIST[*]:+-> ${ROOT_LIST[*]}}"
  [ "$N_ERR" -gt 0 ] && out "  NICHT AUSWERTBAR: $N_ERR Container (siehe [FEHLER] oben) - bitte melden!"
  out "  Befunde:          KRITISCH=${TOTAL[KRITISCH]}  HOCH=${TOTAL[HOCH]}  MITTEL=${TOTAL[MITTEL]}  NIEDRIG=${TOTAL[NIEDRIG]}"
fi

[ $(( ${TOTAL[KRITISCH]} + ${TOTAL[HOCH]} + N_ERR )) -gt 0 ] && exit 3
exit 0
