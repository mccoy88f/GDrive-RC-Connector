#!/usr/bin/env bash
# =============================================================================
#  Prepara sull'HOST le cartelle condivise tra Nextcloud e rclone.
#  Uso:  sudo bash setup-bridge.sh <nome_container_nextcloud>
# =============================================================================
set -euo pipefail

NC="${1:-}"
BASE="${BASE:-/data/gdrive-bridge}"

log() { echo -e "\e[1;34m==>\e[0m $*"; }
err() { echo -e "\e[1;31m[ERRORE]\e[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "Esegui come root"
[[ -n "$NC" ]] || err "Uso: $0 <nome_container_nextcloud>
Container attivi:
$(docker ps --format '  {{.Names}}' | grep -i next || docker ps --format '  {{.Names}}')"

# UID dell'utente con cui gira Nextcloud (www-data = 33 nell'immagine ufficiale)
NC_UID=$(docker exec "$NC" sh -c '
  for f in /var/www/html/config/config.php /config/www/nextcloud/config/config.php /app/www/public/config/config.php; do
    [ -f "$f" ] && stat -c %u "$f" && exit 0
  done; exit 1' 2>/dev/null) || err "Non trovo config.php in $NC: passa l'UID a mano con NC_UID=33 $0 $NC"
NC_UID="${NC_UID_OVERRIDE:-$NC_UID}"
log "Nextcloud gira con UID $NC_UID"

mkdir -p "$BASE/users" "$BASE/proxy"
chown "$NC_UID:$NC_UID" "$BASE/users"
chmod 700 "$BASE/users"
chown root:root "$BASE/proxy"
chmod 755 "$BASE/proxy"

# Auth-proxy per rclone: riceve {"user","pass"} su stdin e restituisce
# la config del remote dell'utente letta dal file scritto da Nextcloud.
cat > "$BASE/proxy/auth-proxy.sh" << 'PROXY'
#!/bin/sh
IN=$(cat)
U=$(printf '%s' "$IN" | sed -n 's/.*"user"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_-]*\)".*/\1/p')
P=$(printf '%s' "$IN" | sed -n 's/.*"pass"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_-]*\)".*/\1/p')
[ -n "$U" ] && [ -n "$P" ] || exit 1
H=$(printf '%s:%s' "$U" "$P" | sha256sum | cut -d' ' -f1)
F="/bridge/users/$H.json"
[ -f "$F" ] || exit 1
cat "$F"
PROXY
chmod 755 "$BASE/proxy/auth-proxy.sh"

log "Fatto:"
echo "   $BASE/users  -> da montare in Nextcloud su /gdrive-bridge (lettura/scrittura)"
echo "   $BASE/users  -> da montare in rclone su /bridge/users (sola lettura)"
echo "   $BASE/proxy  -> da montare in rclone su /bridge/proxy (sola lettura)"
