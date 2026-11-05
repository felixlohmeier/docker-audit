#!/bin/bash
# =====================================================================
# collect.sh - fuehrt docker-audit.sh per SSH auf mehreren Servern aus
#
#   ./collect.sh hosts.txt [ssh-user]
#
# hosts.txt: ein Hostname pro Zeile, '#' = Kommentar.
# Ergebnis in ./audit-JJJJMMTT/:
#   <host>.txt            Klartext-Bericht je Server
#   alle-container.csv    alle Container aller Server (Excel: Trennzeichen ';')
#   fehler.log            nicht erreichbare Server / Fehler
#
# Voraussetzung: SSH-Key-Login; ist der Benutzer nicht root, wird
# 'sudo -n' verwendet (NOPASSWD fuer bash noetig) - sonst als root anmelden.
# =====================================================================
HOSTS=${1:?Aufruf: $0 hosts.txt [ssh-user]}
SSHUSER=${2:-root}
DIR=$(cd "$(dirname "$0")" && pwd)
AUDIT="$DIR/docker-audit.sh"
OUT="audit-$(date +%Y%m%d)"
CSV="$OUT/alle-container.csv"
mkdir -p "$OUT"
: > "$OUT/fehler.log"

SUDO=""; [ "$SSHUSER" = root ] || SUDO="sudo -n"
SSHOPTS="-o BatchMode=yes -o ConnectTimeout=10"

[ -r "$AUDIT" ] || { echo "docker-audit.sh nicht gefunden" >&2; exit 1; }

header_done=0
while read -r h <&3; do
  h=${h%%#*}; h=$(echo "$h" | tr -d '[:space:]')
  [ -n "$h" ] || continue
  printf '%-40s ' "$h"

  ssh $SSHOPTS "$SSHUSER@$h" "$SUDO bash -s" < "$AUDIT" > "$OUT/$h.txt" 2>>"$OUT/fehler.log"
  rc=$?
  if [ $rc -ne 0 ] && [ $rc -ne 3 ]; then
    echo "FEHLER (rc=$rc, siehe fehler.log)"; echo "[$h] rc=$rc" >> "$OUT/fehler.log"; continue
  fi

  if [ $header_done -eq 0 ]; then
    ssh $SSHOPTS "$SSHUSER@$h" "$SUDO bash -s -- --csv" < "$AUDIT" > "$CSV" 2>>"$OUT/fehler.log"
    header_done=1
  else
    ssh $SSHOPTS "$SSHUSER@$h" "$SUDO bash -s -- --csv --no-header" < "$AUDIT" >> "$CSV" 2>>"$OUT/fehler.log"
  fi
  grep -E '^  Befunde:' "$OUT/$h.txt" | sed 's/^ *Befunde: *//'
done 3< "$HOSTS"

echo
echo "Berichte: $OUT/   Gesamt-CSV: $CSV"
if [ -s "$CSV" ]; then
  echo
  echo "Container, die als root laufen (Host-UID 0):"
  awk -F'";"' 'NR>1 && $9=="0" {printf "  %-30s %-30s %s\n", substr($1,2), $5, $6}' "$CSV"
fi
