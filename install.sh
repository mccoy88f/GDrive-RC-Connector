#!/usr/bin/env bash
# =============================================================================
#  Google Drive Bridge - installazione, aggiornamento e disinstallazione.
#
#  Va lanciato sul SERVER (host Docker), non dentro il container Nextcloud:
#    curl -fsSL https://raw.githubusercontent.com/mccoy88f/gdrive-rc-connector/main/install.sh | sudo bash
#  All'avvio chiede se installare/aggiornare o disinstallare. Senza chiedere:
#    ... | sudo bash -s -- install   [NOME_CONTAINER_NEXTCLOUD]
#    ... | sudo bash -s -- uninstall [NOME_CONTAINER_NEXTCLOUD]
#
#  Installazione (si può rilanciare quante volte vuoi, anche per aggiornare l'app):
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
#
#  Disinstallazione senza domande (es. in automatico):
#   PURGE=1               rimuove anche collegamenti, credenziali e dati degli utenti
#   YES=1                 non chiede conferma
# =============================================================================
set -euo pipefail

REPO="${REPO:-mccoy88f/gdrive-rc-connector}"
REF="${REF:-main}"
RCLONE_NAME="${RCLONE_NAME:-gdrive-rclone}"
PROXY_DIR="${PROXY_DIR:-/data/gdrive-bridge/proxy}"
APP=gdrivebridge
ACTION="${ACTION:-}"
NC=""
for arg in "$@"; do
	case "$arg" in
		install|uninstall) ACTION="$arg" ;;
		*) NC="$arg" ;;
	esac
done

log()  { echo -e "\e[1;34m==>\e[0m $*"; }
warn() { echo -e "\e[1;33m[ATTENZIONE]\e[0m $*" >&2; }
err()  { echo -e "\e[1;31m[ERRORE]\e[0m $*" >&2; exit 1; }

# Con "curl | bash" lo script arriva da stdin: le risposte si leggono dal terminale
has_tty() { { : < /dev/tty; } 2>/dev/null; }
ask() {
	local answer=""
	has_tty && { read -r -p "$1" answer < /dev/tty || true; }
	echo "${answer:-$2}"
}

[[ $EUID -eq 0 ]] || err "Esegui come root (sudo)."
command -v docker >/dev/null || err "Docker non trovato: lancia lo script sul server, non dentro un container."

if [[ -z "$ACTION" ]]; then
	if has_tty; then
		echo
		echo "Google Drive Bridge per Nextcloud"
		echo "  1) Installa o aggiorna"
		echo "  2) Disinstalla"
		case "$(ask 'Scelta [1]: ' 1)" in
			1) ACTION=install ;;
			2) ACTION=uninstall ;;
			*) err "Scelta non valida." ;;
		esac
	else
		ACTION=install
	fi
fi

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

# Gli upload vengono messi in cache da rclone e inviati a Google dopo: se rclone
# viene ricreato o rimosso prima, quelli in coda vanno persi. Si aspetta che finiscano.
pending() {
	docker exec "$RCLONE_NAME" sh -c 'grep -rlE "\"Dirty\": *true" /root/.cache/rclone/vfsMeta 2>/dev/null | wc -l' 2>/dev/null || echo 0
}
wait_uploads() {
	docker inspect "$RCLONE_NAME" >/dev/null 2>&1 || return 0
	[[ "${FORCE:-0}" == 1 ]] && return 0
	local waited=0
	while (( $(pending) > 0 )); do
		(( waited == 0 )) && log "rclone sta ancora inviando $(pending) file a Google: attendo che finisca (FORCE=1 per non aspettare)"
		(( waited >= ${UPLOAD_WAIT:-3600} )) && err "Upload ancora in corso dopo $waited secondi: riprova più tardi, o rilancia con FORCE=1 (i file in coda andrebbero persi)."
		sleep 10; waited=$((waited + 10))
	done
}

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

APPS=$(docker exec "$NC" sh -c "[ -d '$WEB/custom_apps' ] && echo '$WEB/custom_apps' || echo '$WEB/apps'")

# =============================================================================
#  Disinstallazione
# =============================================================================
if [[ "$ACTION" == uninstall ]]; then
	PURGE="${PURGE:-}"
	if [[ -z "$PURGE" ]]; then
		if has_tty; then
			echo
			echo "Cosa vuoi rimuovere?"
			echo "  1) App e container rclone, ma conserva i collegamenti degli utenti"
			echo "     (reinstallando, ognuno ritrova il proprio Google Drive già collegato)"
			echo "  2) Tutto: scollega gli utenti da Google (revoca l'accesso), cancella le loro"
			echo "     credenziali OAuth, il registro errori e le cartelle di collegamento"
			case "$(ask 'Scelta [1]: ' 1)" in
				1) PURGE=0 ;;
				2) PURGE=1 ;;
				*) err "Scelta non valida." ;;
			esac
		else
			PURGE=0
		fi
	fi
	if [[ "${YES:-0}" != 1 ]]; then
		has_tty || err "Per disinstallare senza terminale aggiungi YES=1 (e PURGE=1 per rimuovere anche i dati)."
		[[ "$PURGE" == 1 ]] && what="TUTTO (collegamenti e credenziali degli utenti compresi)" || what="app e rclone (i collegamenti restano)"
		[[ "$(ask "Confermi la rimozione di: $what? [s/N] " n)" =~ ^[sSyY] ]] || { log "Annullato."; exit 0; }
	fi

	BRIDGE_DIR=$(occ config:app:get "$APP" bridge_dir 2>/dev/null | tr -d '\r' || true)
	BRIDGE_DIR="${BRIDGE_DIR:-$DATADIR/.gdrive-bridge}"

	# Gli upload in coda vanno lasciati finire prima di fermare rclone
	wait_uploads

	if [[ "$PURGE" == 1 ]] && docker exec "$NC" test -f "$APPS/$APP/appinfo/info.xml"; then
		log "Scollego gli utenti da Google e cancello i loro dati"
		docker exec -i -u "$NC_UID" "$NC" sh -c "cat > /tmp/gdrivebridge-purge.php" << 'PHP'
<?php
require $argv[1] . '/lib/base.php';
$app = 'gdrivebridge';
$db = \OCP\Server::get(\OCP\IDBConnection::class);
$bridge = \OCP\Server::get(\OCA\GDriveBridge\Service\BridgeService::class);
$host = $bridge->getRcloneHost();

// Utenti collegati: revoca del token Google e rimozione del file per rclone
$qb = $db->getQueryBuilder();
$qb->selectDistinct('userid')->from('preferences')->where($qb->expr()->eq('appid', $qb->createNamedParameter($app)));
$users = $qb->executeQuery()->fetchAll(\PDO::FETCH_COLUMN);
foreach ($users as $uid) {
	if ($bridge->isConnected($uid)) {
		$bridge->disconnect($uid);
		echo "  scollegato: $uid\n";
	}
}
\OCP\Server::get(\OCP\IConfig::class)->deleteAppFromAllUsers($app);

// Cache dei file della cartella Google Drive
$qb = $db->getQueryBuilder();
$qb->select('id')->from('storages')->where($qb->expr()->like('id', $qb->createNamedParameter('webdav::%@' . $db->escapeLikeParameter($host) . '/%')));
foreach ($qb->executeQuery()->fetchAll(\PDO::FETCH_COLUMN) as $id) {
	\OC\Files\Cache\Storage::remove($id);
}
echo '  utenti: ' . count($users) . "\n";
PHP
		docker exec -u "$NC_UID" "$NC" php /tmp/gdrivebridge-purge.php "$WEB" || warn "Pulizia dei dati utente non completata."
		docker exec "$NC" rm -f /tmp/gdrivebridge-purge.php
	fi

	log "Disattivo e rimuovo l'app"
	occ app:disable "$APP" >/dev/null 2>&1 || true
	docker exec "$NC" rm -rf "$APPS/$APP"
	if [[ "$PURGE" == 1 ]]; then
		docker exec -u "$NC_UID" "$NC" php -r 'require $argv[1] . "/lib/base.php"; \OCP\Server::get(\OCP\IAppConfig::class)->deleteApp("gdrivebridge");' "$WEB" \
			|| warn "Impostazioni dell'app non rimosse."
	fi

	log "Rimuovo il container rclone"
	docker rm -f "$RCLONE_NAME" >/dev/null 2>&1 || true

	if [[ "$PURGE" == 1 ]]; then
		USERS_HOST=$(host_path "$BRIDGE_DIR" || true)
		[[ -n "$USERS_HOST" && -d "$USERS_HOST" ]] && rm -rf "$USERS_HOST"
		rm -rf "$PROXY_DIR"
		rmdir "$(dirname "$PROXY_DIR")" 2>/dev/null || true
		log "Rimossi anche collegamenti, credenziali e cartelle"
	else
		log "Collegamenti conservati in $BRIDGE_DIR: rilancia lo script per reinstallare"
	fi
	echo
	log "Disinstallazione completata. L'immagine rclone/rclone resta sul server: docker rmi rclone/rclone per toglierla."
	exit 0
fi

# =============================================================================
#  Installazione / aggiornamento
# =============================================================================

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

wait_uploads
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
