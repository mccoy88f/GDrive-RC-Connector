#!/usr/bin/env bash
# =============================================================================
#  Google Drive Bridge - installazione completa in un colpo solo.
#
#  Va lanciato sul SERVER (host Docker), non dentro il container Nextcloud:
#    curl -fsSL https://raw.githubusercontent.com/mccoy88f/gdrive-rc-connector/main/install.sh | sudo bash
#  oppure, indicando il container:
#    curl -fsSL .../install.sh | sudo bash -s -- NOME_CONTAINER_NEXTCLOUD
#
#  Cosa fa (si può rilanciare quante volte vuoi, anche per aggiornare l'app):
#   1. trova il container Nextcloud, la sua cartella dati e l'utente PHP
#   2. crea la cartella condivisa DENTRO la cartella dati di Nextcloud
#      (già persistente: nessun volume da aggiungere, sopravvive agli aggiornamenti)
#   3. scrive l'auth-proxy per rclone sull'host
#   4. scarica l'app in custom_apps, la abilita e la configura
#   5. avvia il container rclone sulla stessa rete di Nextcloud
#
#  Variabili facoltative:
#   REF=main              ramo/tag del repository da cui scaricare l'app
#   REPO=mccoy88f/gdrive-rc-connector
#   RCLONE_NAME=gdrive-rclone   nome del container rclone
#   PROXY_DIR=/data/gdrive-bridge/proxy   dove salvare l'auth-proxy sull'host
#   UPLOAD_WAIT=3600      secondi massimi di attesa degli upload in corso prima di riavviare rclone
#   FORCE=1               riavvia rclone senza aspettare (gli upload in coda vanno persi)
# =============================================================================
set -euo pipefail

REPO="${REPO:-mccoy88f/gdrive-rc-connector}"
REF="${REF:-main}"
RCLONE_NAME="${RCLONE_NAME:-gdrive-rclone}"
PROXY_DIR="${PROXY_DIR:-/data/gdrive-bridge/proxy}"
APP=gdrivebridge
NC="${1:-}"

log()  { echo -e "\e[1;34m==>\e[0m $*"; }
warn() { echo -e "\e[1;33m[ATTENZIONE]\e[0m $*" >&2; }
err()  { echo -e "\e[1;31m[ERRORE]\e[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "Esegui come root (sudo)."
command -v docker >/dev/null || err "Docker non trovato: lancia lo script sul server, non dentro un container."

# --- 1. Container Nextcloud --------------------------------------------------
if [[ -z "$NC" ]]; then
	mapfile -t found < <(docker ps --format '{{.Names}} {{.Image}}' | awk 'tolower($2) ~ /nextcloud/ {print $1}')
	[[ ${#found[@]} -eq 1 ]] || err "Non riesco a scegliere il container Nextcloud, passalo come argomento:
  curl ... | sudo bash -s -- NOME_CONTAINER
Container attivi:
$(docker ps --format '  {{.Names}}  ({{.Image}})')"
	NC="${found[0]}"
fi
docker inspect "$NC" >/dev/null 2>&1 || err "Container '$NC' non trovato."
log "Container Nextcloud: $NC"

WEB=$(docker exec "$NC" sh -c 'for d in /var/www/html /config/www/nextcloud /app/www/public; do [ -f "$d/occ" ] && echo "$d" && exit 0; done; exit 1') \
	|| err "Non trovo occ dentro $NC: è davvero un container Nextcloud?"
NC_UID=$(docker exec "$NC" stat -c %u "$WEB/config/config.php")
NC_GID=$(docker exec "$NC" stat -c %g "$WEB/config/config.php")
log "Nextcloud in $WEB (UID $NC_UID)"

occ() { docker exec -u "$NC_UID" -w "$WEB" "$NC" php occ "$@"; }

DATADIR=$(occ config:system:get datadirectory | tr -d '\r')
[[ -n "$DATADIR" ]] || err "Impossibile leggere datadirectory da config.php."

# Percorso sull'host di un percorso del container (tramite i suoi volumi)
host_path() {
	local target="$1" best_dst="" best_src="" dst src
	while IFS='|' read -r dst src; do
		[[ -z "$dst" ]] && continue
		if [[ "$target" == "$dst" || "$target" == "$dst"/* ]] && (( ${#dst} > ${#best_dst} )); then
			best_dst="$dst"; best_src="$src"
		fi
	done < <(docker inspect -f '{{range .Mounts}}{{.Destination}}|{{.Source}}{{"\n"}}{{end}}' "$NC")
	[[ -n "$best_dst" ]] || return 1
	echo "${best_src}${target#"$best_dst"}"
}

# --- 2. Cartella condivisa (dentro la cartella dati, già persistente) --------
BRIDGE_DIR="$DATADIR/.gdrive-bridge"
USERS_HOST=$(host_path "$BRIDGE_DIR") \
	|| err "La cartella dati $DATADIR non è su un volume persistente: i dati di Nextcloud andrebbero persi a ogni aggiornamento!"
mkdir -p "$USERS_HOST"
chown "$NC_UID:$NC_GID" "$USERS_HOST"
chmod 700 "$USERS_HOST"
log "Cartella condivisa: $BRIDGE_DIR (host: $USERS_HOST)"

# --- 3. Auth-proxy per rclone ------------------------------------------------
mkdir -p "$PROXY_DIR"
cat > "$PROXY_DIR/auth-proxy.sh" << 'PROXY'
#!/bin/sh
# Riceve {"user","pass"} su stdin e restituisce la config del remote dell'utente
IN=$(cat)
U=$(printf '%s' "$IN" | sed -n 's/.*"user"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_-]*\)".*/\1/p')
P=$(printf '%s' "$IN" | sed -n 's/.*"pass"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_-]*\)".*/\1/p')
[ -n "$U" ] && [ -n "$P" ] || exit 1
H=$(printf '%s:%s' "$U" "$P" | sha256sum | cut -d' ' -f1)
F="/bridge/users/$H.json"
[ -f "$F" ] || exit 1
cat "$F"
PROXY
chmod 755 "$PROXY_DIR" "$PROXY_DIR/auth-proxy.sh"
log "Auth-proxy: $PROXY_DIR/auth-proxy.sh"

# --- 4. App Nextcloud --------------------------------------------------------
APPS=$(docker exec "$NC" sh -c "[ -d '$WEB/custom_apps' ] && echo '$WEB/custom_apps' || echo '$WEB/apps'")
host_path "$APPS" >/dev/null || warn "$APPS non è su un volume persistente: dopo un aggiornamento rilancia questo script."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
log "Scarico l'app da github.com/$REPO ($REF)"
curl -fsSL "https://github.com/$REPO/archive/$REF.tar.gz" | tar xz -C "$TMP" --strip-components=1 \
	|| err "Download fallito (il repository è privato? usa REPO/REF corretti)."
[[ -f "$TMP/$APP/appinfo/info.xml" ]] || err "Nell'archivio non c'è $APP/."

docker exec "$NC" rm -rf "$APPS/$APP"
docker cp "$TMP/$APP" "$NC:$APPS/$APP"
docker exec "$NC" chown -R "$NC_UID:$NC_GID" "$APPS/$APP"

if occ status --output=json | grep -q '"needsDbUpgrade":true'; then
	log "Aggiornamento richiesto da Nextcloud: occ upgrade"
	occ upgrade -n
fi
occ app:enable "$APP"
occ config:app:set "$APP" bridge_dir --value="$BRIDGE_DIR" >/dev/null
occ config:app:set "$APP" rclone_host --value="$RCLONE_NAME:8080" >/dev/null
log "App $APP abilitata e configurata"

# --- 5. Container rclone -----------------------------------------------------
mapfile -t NETS < <(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' "$NC" | sed '/^$/d')
[[ ${#NETS[@]} -gt 0 ]] || err "Il container Nextcloud non è su nessuna rete Docker."
for n in "${NETS[@]}"; do
	[[ "$n" == "bridge" || "$n" == "host" ]] && err "Nextcloud usa la rete '$n': serve una rete Docker personalizzata (come quelle di Coolify o docker compose)."
done

# Gli upload vengono messi in cache da rclone e inviati a Google dopo: se rclone
# viene ricreato prima, quelli in coda vanno persi. Si aspetta che finiscano.
pending() {
	docker exec "$RCLONE_NAME" sh -c 'grep -rlE "\"Dirty\": *true" /root/.cache/rclone/vfsMeta 2>/dev/null | wc -l' 2>/dev/null || echo 0
}
if docker inspect "$RCLONE_NAME" >/dev/null 2>&1 && [[ "${FORCE:-0}" != 1 ]]; then
	waited=0
	while (( $(pending) > 0 )); do
		(( waited == 0 )) && log "rclone sta ancora inviando $(pending) file a Google: attendo che finisca (FORCE=1 per non aspettare)"
		(( waited >= ${UPLOAD_WAIT:-3600} )) && err "Upload ancora in corso dopo $waited secondi: riprova più tardi, o rilancia con FORCE=1 (i file in coda andrebbero persi)."
		sleep 10; waited=$((waited + 10))
	done
fi
docker rm -f "$RCLONE_NAME" >/dev/null 2>&1 || true
docker pull -q rclone/rclone:latest >/dev/null
docker run -d --name "$RCLONE_NAME" --restart unless-stopped \
	--network "${NETS[0]}" \
	-v "$PROXY_DIR:/bridge/proxy:ro" \
	-v "$USERS_HOST:/bridge/users:ro" \
	rclone/rclone:latest serve webdav --addr=:8080 \
	--auth-proxy=/bridge/proxy/auth-proxy.sh \
	--vfs-cache-mode=writes --dir-cache-time=1m >/dev/null
for n in "${NETS[@]:1}"; do docker network connect "$n" "$RCLONE_NAME"; done
log "Container rclone '$RCLONE_NAME' avviato sulla rete ${NETS[*]}"

# --- Verifica ----------------------------------------------------------------
STATUS=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
	STATUS=$(docker exec -u "$NC_UID" "$NC" php -r '$h=@get_headers("http://'"$RCLONE_NAME"':8080"); echo $h[0] ?? "";' || true)
	[[ "$STATUS" == *401* ]] && break
	sleep 1
done
if [[ "$STATUS" == *401* ]]; then
	log "Nextcloud raggiunge rclone correttamente."
else
	warn "Nextcloud non riesce a raggiungere $RCLONE_NAME:8080 (risposta: '${STATUS:-nessuna}'). Controlla: docker logs $RCLONE_NAME"
fi

echo
log "Fatto! Ogni utente ora va in Impostazioni personali → Google Drive."
echo "   Se l'URI di reindirizzamento mostrato inizia con http:// ma usi HTTPS:"
echo "   docker exec -u $NC_UID $NC php $WEB/occ config:system:set overwriteprotocol --value=https"
