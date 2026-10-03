#!/usr/bin/env bash
# =============================================================================
#  Google Drive Bridge - install, update and uninstall.
#
#  Run it on the SERVER (Docker host), not inside the Nextcloud container,
#  saying what to do (it never asks questions while running):
#
#    curl -fsSL https://raw.githubusercontent.com/mccoy88f/gdrive-rc-connector/main/install.sh | sudo bash -s -- install
#
#  Actions:
#    install            install or update; the mode is picked automatically: mount if
#                       Nextcloud already has the /gdrive volume, otherwise webdav
#    install mount      mount mode: rclone mounts the Drive as a folder and Nextcloud shows
#                       it through External storage (recommended; needs one line in the
#                       Nextcloud compose, the script explains which one)
#    install webdav     webdav mode: no change to Nextcloud
#    uninstall          remove the app and the rclone container, keep the users'
#                       connections (after reinstalling, everyone finds their Drive connected)
#    uninstall purge    remove everything: disconnect users from Google and delete
#                       credentials, settings and the app folders
#  Options:
#    en | it            language of the messages (default: system language, otherwise English)
#    CONTAINER_NAME     the Nextcloud container, if the server has more than one
#
#  Optional variables:
#   REF=main              branch/tag of the repository to download the app from
#   REPO=mccoy88f/gdrive-rc-connector
#   SRC_DIR=/path         install from a local copy of the repository instead of GitHub
#   RCLONE_NAME=gdrive-rclone   name of the rclone container
#   BASE_DIR=/data/gdrive-bridge   host folder for auth-proxy, mounts and cache
#   UPLOAD_WAIT=3600      max seconds to wait for running uploads before restarting rclone
#   FORCE=1               restart/remove rclone without waiting for queued uploads (they are lost)
# =============================================================================
set -euo pipefail

REPO="${REPO:-mccoy88f/gdrive-rc-connector}"
REF="${REF:-main}"
RCLONE_NAME="${RCLONE_NAME:-gdrive-rclone}"
BASE_DIR="${BASE_DIR:-/data/gdrive-bridge}"
PROXY_DIR="${PROXY_DIR:-$BASE_DIR/proxy}"
MNT_DIR="${MNT_DIR:-$BASE_DIR/mnt}"        # mount mode: mount points, seen by Nextcloud as /gdrive
CACHE_DIR="${CACHE_DIR:-$BASE_DIR/cache}"  # mount mode: rclone cache (queued uploads)
NC_MNT=/gdrive
MODE=""
APP=gdrivebridge
ACTION=""
UI="${GDB_LANG:-}"
PURGE=0
NC=""
for arg in "$@"; do
	case "$arg" in
		install|uninstall) ACTION="$arg" ;;
		mount|webdav) MODE="$arg" ;;
		purge) PURGE=1 ;;
		en|it) UI="$arg" ;;
		-h|--help|help) ACTION=help ;;
		*) NC="$arg" ;;
	esac
done

# Message language: en/it argument, then GDB_LANG, then the system language
if [[ -z "$UI" ]]; then
	case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in it*) UI=it ;; *) UI=en ;; esac
fi
L() { if [[ "$UI" == it ]]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }

log()  { echo -e "\e[1;34m==>\e[0m $*"; }
warn() { echo -e "\e[1;33m[$(L WARNING ATTENZIONE)]\e[0m $*" >&2; }
err()  { echo -e "\e[1;31m[$(L ERROR ERRORE)]\e[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "$(L "Run as root (sudo)." "Esegui come root (sudo).")"
command -v docker >/dev/null || err "$(L "Docker not found: run the script on the server, not inside a container." "Docker non trovato: lancia lo script sul server, non dentro un container.")"

if [[ -z "$ACTION" || "$ACTION" == help ]]; then
	if [[ "$UI" == it ]]; then
	cat << 'USO'
Uso (sul server, non nel container Nextcloud):
  curl -fsSL https://raw.githubusercontent.com/mccoy88f/gdrive-rc-connector/main/install.sh | sudo bash -s -- AZIONE [it|en]

AZIONE:
  install            installa o aggiorna (modalità mount se Nextcloud ha il volume /gdrive, altrimenti webdav)
  install mount      installa o aggiorna in modalità mount (consigliata)
  install webdav     installa o aggiorna in modalità webdav
  uninstall          rimuove app e rclone, conserva i collegamenti degli utenti
  uninstall purge    rimuove tutto, compresi collegamenti e credenziali degli utenti

Aggiungi "it" o "en" per scegliere la lingua dei messaggi.
USO
	else
	cat << 'USAGE'
Usage (on the server, not inside the Nextcloud container):
  curl -fsSL https://raw.githubusercontent.com/mccoy88f/gdrive-rc-connector/main/install.sh | sudo bash -s -- ACTION [en|it]

ACTION:
  install            install or update (mount mode if Nextcloud has the /gdrive volume, otherwise webdav)
  install mount      install or update in mount mode (recommended)
  install webdav     install or update in webdav mode
  uninstall          remove the app and rclone, keep the users' connections
  uninstall purge    remove everything, including the users' connections and credentials

Add "en" or "it" to choose the language of the messages.
USAGE
	fi
	[[ "$ACTION" == help ]] && exit 0 || exit 1
fi
[[ "$PURGE" == 1 && "$ACTION" != uninstall ]] && err "$(L "'purge' only works with 'uninstall'." "'purge' vale solo con 'uninstall'.")"
[[ -n "$MODE" && "$ACTION" != install ]] && err "$(L "'$MODE' only works with 'install'." "'$MODE' vale solo con 'install'.")"

# --- 1. Nextcloud container --------------------------------------------------
if [[ -z "$NC" ]]; then
	mapfile -t found < <(docker ps --format '{{.Names}} {{.Image}}' | awk 'tolower($2) ~ /nextcloud/ {print $1}')
	[[ ${#found[@]} -eq 1 ]] || err "$(L "Cannot pick the Nextcloud container, pass it as an argument:" "Non riesco a scegliere il container Nextcloud, passalo come argomento:")
  curl ... | sudo bash -s -- install $(L CONTAINER_NAME NOME_CONTAINER)
$(L "Running containers:" "Container attivi:")
$(docker ps --format '  {{.Names}}  ({{.Image}})')"
	NC="${found[0]}"
fi
docker inspect "$NC" >/dev/null 2>&1 || err "$(L "Container '$NC' not found." "Container '$NC' non trovato.")"
log "Container Nextcloud: $NC"

WEB=$(docker exec "$NC" sh -c 'for d in /var/www/html /config/www/nextcloud /app/www/public; do [ -f "$d/occ" ] && echo "$d" && exit 0; done; exit 1') \
	|| err "$(L "occ not found in $NC: is it really a Nextcloud container?" "Non trovo occ dentro $NC: è davvero un container Nextcloud?")"
NC_UID=$(docker exec "$NC" stat -c %u "$WEB/config/config.php")
NC_GID=$(docker exec "$NC" stat -c %g "$WEB/config/config.php")
log "Nextcloud in $WEB (UID $NC_UID)"

occ() { docker exec -u "$NC_UID" -w "$WEB" "$NC" php occ "$@"; }

DATADIR=$(occ config:system:get datadirectory | tr -d '\r')
[[ -n "$DATADIR" ]] || err "$(L "Cannot read datadirectory from config.php." "Impossibile leggere datadirectory da config.php.")"

# rclone caches uploads and sends them to Google afterwards: if rclone is
# recreated or removed before that, the queued ones are lost. Wait for them.
pending() {
	docker exec "$RCLONE_NAME" sh -c 'grep -rlE "\"Dirty\": *true" /root/.cache/rclone/vfsMeta /cache/*/vfsMeta 2>/dev/null | wc -l' 2>/dev/null || echo 0
}
wait_uploads() {
	docker inspect "$RCLONE_NAME" >/dev/null 2>&1 || return 0
	[[ "${FORCE:-0}" == 1 ]] && return 0
	local waited=0
	while (( $(pending) > 0 )); do
		(( waited == 0 )) && log "$(L "rclone is still sending $(pending) file(s) to Google: waiting for it to finish (FORCE=1 to skip waiting)" "rclone sta ancora inviando $(pending) file a Google: attendo che finisca (FORCE=1 per non aspettare)")"
		(( waited >= ${UPLOAD_WAIT:-3600} )) && err "$(L "Uploads still running after $waited seconds: try again later, or rerun with FORCE=1 (queued files would be lost)." "Upload ancora in corso dopo $waited secondi: riprova più tardi, o rilancia con FORCE=1 (i file in coda andrebbero persi).")"
		sleep 10; waited=$((waited + 10))
	done
}

# Stop rclone after the queued uploads; in mount mode unmount the folders first
remove_rclone() {
	docker inspect "$RCLONE_NAME" >/dev/null 2>&1 || return 0
	wait_uploads
	docker stop -t 30 "$RCLONE_NAME" >/dev/null 2>&1 || true
	docker rm -f "$RCLONE_NAME" >/dev/null 2>&1 || true
	# mounts left hanging on the host (e.g. rclone killed)
	if [[ -d "$MNT_DIR" ]]; then
		for m in "$MNT_DIR"/*; do
			mountpoint -q "$m" 2>/dev/null && umount -l "$m" 2>/dev/null || true
		done
	fi
}

# The Nextcloud /gdrive volume, with mount propagation (mount mode)
nc_mount_ok() {
	docker inspect -f '{{range .Mounts}}{{.Destination}}|{{.Source}}|{{.Propagation}}{{"\n"}}{{end}}' "$NC" \
		| awk -F'|' -v d="$NC_MNT" -v s="$MNT_DIR" '$1 == d && $2 == s && $3 ~ /^r?(slave|shared)$/ { f = 1 } END { exit !f }'
}

# Id of the external storage created for mount mode (empty if missing)
gd_storage_id() {
	occ files_external:list --output=json 2>/dev/null | docker exec -i -u "$NC_UID" "$NC" php -r '
		foreach (json_decode(stream_get_contents(STDIN), true) ?: [] as $m) {
			if (($m["configuration"]["datadir"] ?? "") === "/gdrive/\$user") { echo $m["mount_id"]; break; }
		}' 2>/dev/null || true
}

# Run a BridgeService method for every connected user
for_each_user() {
	docker exec -u "$NC_UID" "$NC" php -r '
		require $argv[1] . "/lib/base.php";
		$db = \OCP\Server::get(\OCP\IDBConnection::class);
		$b = \OCP\Server::get(\OCA\GDriveBridge\Service\BridgeService::class);
		$qb = $db->getQueryBuilder();
		$qb->selectDistinct("userid")->from("preferences")->where($qb->expr()->eq("appid", $qb->createNamedParameter("gdrivebridge")));
		$n = 0;
		foreach ($qb->executeQuery()->fetchAll(\PDO::FETCH_COLUMN) as $uid) {
			if ($b->isConnected($uid)) { $b->{$argv[2]}($uid); $n++; }
		}
		echo $n;' "$WEB" "$1"
}

# Host path of a container path (through its volumes)
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
#  Uninstall
# =============================================================================
if [[ "$ACTION" == uninstall ]]; then
	[[ "$PURGE" == 1 ]] && log "$(L "Full uninstall (purge)" "Disinstallazione completa (purge)")" || log "$(L "Uninstall (user connections are kept)" "Disinstallazione (i collegamenti degli utenti restano)")"

	BRIDGE_DIR=$(occ config:app:get "$APP" bridge_dir 2>/dev/null | tr -d '\r' || true)
	BRIDGE_DIR="${BRIDGE_DIR:-$DATADIR/.gdrive-bridge}"

	# Let queued uploads finish before stopping rclone
	wait_uploads

	SID=$(gd_storage_id)
	if [[ -n "$SID" ]]; then
		log "$(L "Removing the folder from External storage" "Rimuovo la cartella dall'Archiviazione esterna")"
		occ files_external:delete -y "$SID" >/dev/null || warn "$(L "External storage $SID not removed." "Archiviazione esterna $SID non rimossa.")"
	fi

	if [[ "$PURGE" == 1 ]] && docker exec "$NC" test -f "$APPS/$APP/appinfo/info.xml"; then
		log "$(L "Disconnecting users from Google and deleting their data" "Scollego gli utenti da Google e cancello i loro dati")"
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
		echo ($argv[2] === 'it' ? '  scollegato: ' : '  disconnected: ') . $uid . "\n";
	}
}
\OCP\Server::get(\OCP\IConfig::class)->deleteAppFromAllUsers($app);

// Cache dei file della cartella Google Drive
$qb = $db->getQueryBuilder();
$qb->select('id')->from('storages')->where($qb->expr()->like('id', $qb->createNamedParameter('webdav::%@' . $db->escapeLikeParameter($host) . '/%')));
foreach ($qb->executeQuery()->fetchAll(\PDO::FETCH_COLUMN) as $id) {
	\OC\Files\Cache\Storage::remove($id);
}
echo ($argv[2] === 'it' ? '  utenti: ' : '  users: ') . count($users) . "\n";
PHP
		docker exec -u "$NC_UID" "$NC" php /tmp/gdrivebridge-purge.php "$WEB" "$UI" || warn "$(L "User data cleanup not completed." "Pulizia dei dati utente non completata.")"
		docker exec "$NC" rm -f /tmp/gdrivebridge-purge.php
	fi

	log "$(L "Disabling and removing the app" "Disattivo e rimuovo l'app")"
	occ app:disable "$APP" >/dev/null 2>&1 || true
	docker exec "$NC" rm -rf "$APPS/$APP"
	if [[ "$PURGE" == 1 ]]; then
		docker exec -u "$NC_UID" "$NC" php -r 'require $argv[1] . "/lib/base.php"; \OCP\Server::get(\OCP\IAppConfig::class)->deleteApp("gdrivebridge");' "$WEB" \
			|| warn "$(L "App settings not removed." "Impostazioni dell'app non rimosse.")"
	fi

	log "$(L "Removing the rclone container" "Rimuovo il container rclone")"
	remove_rclone

	if [[ "$PURGE" == 1 ]]; then
		USERS_HOST=$(host_path "$BRIDGE_DIR" || true)
		[[ -n "$USERS_HOST" && -d "$USERS_HOST" ]] && rm -rf "$USERS_HOST"
		occ group:delete gdrive >/dev/null 2>&1 || true
		rm -rf "$PROXY_DIR" "$CACHE_DIR"
		if nc_mount_ok || docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' "$NC" | grep -qw "$NC_MNT"; then
			# Without the (shared) folder Nextcloud might not start again
			warn "$(L "Nextcloud still uses $MNT_DIR: remove the line '$MNT_DIR:$NC_MNT:rslave' from the Nextcloud compose, restart it and run 'uninstall purge' again to remove that folder too." "Nextcloud usa ancora $MNT_DIR: togli la riga '$MNT_DIR:$NC_MNT:rslave' dal compose di Nextcloud, riavvialo (Restart) e rilancia 'uninstall purge' per rimuovere anche quella cartella.")"
		else
			if [[ -f /etc/systemd/system/gdrive-bridge-mnt.service ]]; then
				systemctl disable --now gdrive-bridge-mnt.service >/dev/null 2>&1 || true
				rm -f /etc/systemd/system/gdrive-bridge-mnt.service
				systemctl daemon-reload 2>/dev/null || true
			fi
			mountpoint -q "$MNT_DIR" 2>/dev/null && umount -l "$MNT_DIR" 2>/dev/null
			rm -rf "$MNT_DIR" 2>/dev/null || true
		fi
		rmdir "$BASE_DIR" 2>/dev/null || true
		log "$(L "Connections, credentials and folders removed too" "Rimossi anche collegamenti, credenziali e cartelle")"
	else
		log "$(L "Connections kept in $BRIDGE_DIR: run the script again to reinstall" "Collegamenti conservati in $BRIDGE_DIR: rilancia lo script per reinstallare")"
	fi
	echo
	log "$(L "Uninstall complete. The rclone/rclone image stays on the server: docker rmi rclone/rclone to remove it." "Disinstallazione completata. L'immagine rclone/rclone resta sul server: docker rmi rclone/rclone per toglierla.")"
	exit 0
fi

# =============================================================================
#  Install / update
# =============================================================================

# --- Mode --------------------------------------------------------------------
if [[ -z "$MODE" ]]; then
	nc_mount_ok && MODE=mount || MODE=webdav
fi

if [[ "$MODE" == mount ]]; then
	[[ -e /dev/fuse ]] || err "$(L "This server has no FUSE (/dev/fuse): use 'install webdav'." "Questo server non ha FUSE (/dev/fuse): usa 'install webdav'.")"

	# The host mount folder must be "shared", so that the mounts made by rclone
	# reach Nextcloud. It must be prepared BEFORE adding the volume to Nextcloud:
	# otherwise Docker might refuse to start it.
	mkdir -p "$MNT_DIR"
	if [[ "$(findmnt -no PROPAGATION --target "$MNT_DIR" 2>/dev/null)" != shared ]]; then
		mountpoint -q "$MNT_DIR" || mount --bind "$MNT_DIR" "$MNT_DIR"
		mount --make-rshared "$MNT_DIR"
		if [[ -d /run/systemd/system ]]; then
			cat > /etc/systemd/system/gdrive-bridge-mnt.service << UNIT
[Unit]
Description=Google Drive Bridge: mount folder shared with the containers
Before=docker.service
RequiresMountsFor=$(dirname "$MNT_DIR")

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'mkdir -p "$MNT_DIR"; mountpoint -q "$MNT_DIR" || mount --bind "$MNT_DIR" "$MNT_DIR"; mount --make-rshared "$MNT_DIR"'

[Install]
WantedBy=multi-user.target
UNIT
			{ systemctl daemon-reload && systemctl enable gdrive-bridge-mnt.service; } >/dev/null 2>&1 \
				|| warn "$(L "Boot service not enabled: after a server reboot run this script again." "Servizio di avvio non attivato: dopo un riavvio del server rilancia questo script.")"
		else
			warn "$(L "Without systemd the shared folder does not survive a server reboot: after a reboot run this script again." "Senza systemd la cartella condivisa non sopravvive a un riavvio del server: dopo un riavvio rilancia questo script.")"
		fi
		log "$(L "Shared mount folder: $MNT_DIR" "Cartella dei mount condivisa: $MNT_DIR")"
	fi

	if ! nc_mount_ok; then
		echo
		warn "$(L "A volume is missing in Nextcloud. It has to be added once (it stays after updates):" "Manca un volume in Nextcloud. Va aggiunto una volta sola (resta anche dopo gli aggiornamenti):")"
		if [[ "$UI" == it ]]; then
		cat << HELP

  In Coolify: risorsa Nextcloud → "Edit Compose File" → nel servizio "nextcloud"
  (non nel database), sotto "volumes:", aggiungi questa riga (stesso rientro delle altre):

        - '$MNT_DIR:$NC_MNT:rslave'

  Salva, riavvia la risorsa Nextcloud (Restart) e poi rilancia questo script con 'install mount'.
  (Con docker compose o altri gestori: stesso volume, poi ricrea il container.)

HELP
		else
		cat << HELP

  In Coolify: Nextcloud resource → "Edit Compose File" → in the "nextcloud" service
  (not the database), under "volumes:", add this line (same indentation as the others):

        - '$MNT_DIR:$NC_MNT:rslave'

  Save, restart the Nextcloud resource (Restart) and then run this script again with 'install mount'.
  (With docker compose or other managers: same volume, then recreate the container.)

HELP
		fi
		log "$(L "Meanwhile installing/updating in webdav mode, so Google Drive keeps working." "Intanto installo/aggiorno in modalità webdav, così Google Drive continua a funzionare.")"
		MODE=webdav
	fi
fi
log "$(L "Mode: $MODE" "Modalità: $MODE")"

# --- 2. Shared folder (inside the data folder, already persistent) ----------
BRIDGE_DIR="$DATADIR/.gdrive-bridge"
USERS_HOST=$(host_path "$BRIDGE_DIR") \
	|| err "$(L "The data folder $DATADIR is not on a persistent volume: Nextcloud data would be lost at every update!" "La cartella dati $DATADIR non è su un volume persistente: i dati di Nextcloud andrebbero persi a ogni aggiornamento!")"
mkdir -p "$USERS_HOST"
chown "$NC_UID:$NC_GID" "$USERS_HOST"
chmod 700 "$USERS_HOST"
log "$(L "Shared folder: $BRIDGE_DIR (host: $USERS_HOST)" "Cartella condivisa: $BRIDGE_DIR (host: $USERS_HOST)")"

# --- 3. Auth-proxy for rclone ------------------------------------------------
mkdir -p "$PROXY_DIR"
cat > "$PROXY_DIR/auth-proxy.sh" << 'PROXY'
#!/bin/sh
# Reads {"user","pass"} on stdin and returns the user's remote config
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

# --- 4. Nextcloud app --------------------------------------------------------
host_path "$APPS" >/dev/null || warn "$(L "$APPS is not on a persistent volume: after an update run this script again." "$APPS non è su un volume persistente: dopo un aggiornamento rilancia questo script.")"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
if [[ -n "${SRC_DIR:-}" ]]; then
	log "$(L "Using local files in $SRC_DIR" "Uso i file locali in $SRC_DIR")"
	cp -r "$SRC_DIR/$APP" "$SRC_DIR/server" "$TMP/"
else
	log "$(L "Downloading the app from github.com/$REPO ($REF)" "Scarico l'app da github.com/$REPO ($REF)")"
	curl -fsSL "https://github.com/$REPO/archive/$REF.tar.gz" | tar xz -C "$TMP" --strip-components=1 \
		|| err "$(L "Download failed (is the repository private? use the right REPO/REF)." "Download fallito (il repository è privato? usa REPO/REF corretti).")"
fi
[[ -f "$TMP/$APP/appinfo/info.xml" ]] || err "$(L "$APP/ is missing from the archive." "Nell'archivio non c'è $APP/.")"

docker exec "$NC" rm -rf "$APPS/$APP"
docker cp "$TMP/$APP" "$NC:$APPS/$APP"
docker exec "$NC" chown -R "$NC_UID:$NC_GID" "$APPS/$APP"

if occ status --output=json | grep -q '"needsDbUpgrade":true'; then
	log "$(L "Nextcloud requires an upgrade: occ upgrade" "Aggiornamento richiesto da Nextcloud: occ upgrade")"
	occ upgrade -n
fi
occ app:enable "$APP"
occ config:app:set "$APP" bridge_dir --value="$BRIDGE_DIR" >/dev/null
occ config:app:set "$APP" rclone_host --value="$RCLONE_NAME:8080" >/dev/null
log "$(L "App $APP enabled and configured" "App $APP abilitata e configurata")"

# --- 5. rclone container and folder in Files ----------------------------------
docker pull -q rclone/rclone:latest >/dev/null || warn "$(L "Could not download the rclone image: using the one already present." "Download dell'immagine rclone non riuscito: uso quella già presente.")"
remove_rclone

if [[ "$MODE" == mount ]]; then
	occ config:app:set "$APP" mode --value=mount >/dev/null
	cp "$TMP/server/gdrive-mounts.sh" "$PROXY_DIR/gdrive-mounts.sh"
	chmod 755 "$PROXY_DIR/gdrive-mounts.sh"
	mkdir -p "$CACHE_DIR"

	docker run -d --name "$RCLONE_NAME" --restart unless-stopped \
		--device /dev/fuse --cap-add SYS_ADMIN --security-opt apparmor=unconfined \
		-e NC_UID="$NC_UID" -e NC_GID="$NC_GID" -e GDB_LANG="$UI" \
		-v "$PROXY_DIR:/bridge/proxy:ro" \
		-v "$USERS_HOST:/bridge/users" \
		-v "$MNT_DIR:/mnt/gdrive:rshared" \
		-v "$CACHE_DIR:/cache" \
		--entrypoint /bridge/proxy/gdrive-mounts.sh \
		rclone/rclone:latest >/dev/null
	log "$(L "rclone container '$RCLONE_NAME' started (mounts the users' Drives in $MNT_DIR)" "Container rclone '$RCLONE_NAME' avviato (monta il Drive degli utenti in $MNT_DIR)")"

	# "Local" external storage on /gdrive/$user, only for the "Google Drive" group
	occ app:enable files_external >/dev/null
	occ group:add gdrive --display-name "Google Drive" >/dev/null 2>&1 || true
	MOUNT_NAME=$(occ config:app:get "$APP" mount_name 2>/dev/null | tr -d '\r' || true)
	MOUNT_NAME="${MOUNT_NAME:-Google Drive}"
	SID=$(gd_storage_id)
	if [[ -z "$SID" ]]; then
		SID=$(occ files_external:create "/$MOUNT_NAME" local null::null -c "datadir=$NC_MNT/\$user" | grep -o '[0-9]*$')
		occ files_external:applicable "$SID" --add-group gdrive >/dev/null
		log "$(L "External storage created: '$MOUNT_NAME' for the Google Drive group" "Archiviazione esterna creata: «$MOUNT_NAME» per il gruppo Google Drive")"
	fi
	[[ "$(occ config:app:get "$APP" previews 2>/dev/null | tr -d '\r' || true)" == yes ]] && PREVIEWS=true || PREVIEWS=false
	occ files_external:option "$SID" previews "$PREVIEWS" >/dev/null
	occ files_external:option "$SID" filesystem_check_changes 1 >/dev/null

	# Already connected users: rclone mount config and group
	N=$(for_each_user syncUser)
	log "$(L "Connected users: ${N:-0}" "Utenti collegati: ${N:-0}")"

	# Check: Nextcloud must see the mounted Drive of every connected user
	EXPECTED=$(find "$USERS_HOST" -maxdepth 1 -name '*.conf' | wc -l)
	SEEN=0
	for _ in $(seq 1 30); do
		SEEN=$(docker exec "$NC" sh -c "grep -c ' $NC_MNT/' /proc/mounts" 2>/dev/null || true)
		SEEN=${SEEN:-0}
		(( SEEN >= EXPECTED )) && break
		sleep 1
	done
	if (( SEEN >= EXPECTED )); then
		log "$(L "Nextcloud sees the mounted Drive of $SEEN user(s)." "Nextcloud vede il Drive montato di $SEEN utenti.")"
	else
		warn "$(L "Nextcloud sees the mounted Drive of $SEEN of $EXPECTED connected user(s): for the others check the error log in their settings, or docker logs $RCLONE_NAME" "Nextcloud vede il Drive montato di $SEEN utenti su $EXPECTED collegati: per gli altri controlla il registro errori nelle loro impostazioni, o docker logs $RCLONE_NAME")"
	fi
else
	occ config:app:set "$APP" mode --value=webdav >/dev/null
	SID=$(gd_storage_id)
	if [[ -n "$SID" ]]; then
		occ files_external:delete -y "$SID" >/dev/null && log "$(L "Removed the mount mode external storage" "Rimossa l'archiviazione esterna della modalità mount")"
	fi

	mapfile -t NETS < <(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' "$NC" | sed '/^$/d')
	[[ ${#NETS[@]} -gt 0 ]] || err "$(L "The Nextcloud container is not on any Docker network." "Il container Nextcloud non è su nessuna rete Docker.")"
	for n in "${NETS[@]}"; do
		[[ "$n" == "bridge" || "$n" == "host" ]] && err "$(L "Nextcloud uses the '$n' network: a custom Docker network is needed (like those of Coolify or docker compose)." "Nextcloud usa la rete '$n': serve una rete Docker personalizzata (come quelle di Coolify o docker compose).")"
	done

	docker run -d --name "$RCLONE_NAME" --restart unless-stopped \
		--network "${NETS[0]}" \
		-v "$PROXY_DIR:/bridge/proxy:ro" \
		-v "$USERS_HOST:/bridge/users:ro" \
		rclone/rclone:latest serve webdav --addr=:8080 \
		--auth-proxy=/bridge/proxy/auth-proxy.sh \
		--vfs-cache-mode=writes --dir-cache-time=1m >/dev/null
	for n in "${NETS[@]:1}"; do docker network connect "$n" "$RCLONE_NAME"; done
	log "$(L "rclone container '$RCLONE_NAME' started on network ${NETS[*]}" "Container rclone '$RCLONE_NAME' avviato sulla rete ${NETS[*]}")"

	N=$(for_each_user syncUser)
	STATUS=""
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		STATUS=$(docker exec -u "$NC_UID" "$NC" php -r '$h=@get_headers("http://'"$RCLONE_NAME"':8080"); echo $h[0] ?? "";' || true)
		[[ "$STATUS" == *401* ]] && break
		sleep 1
	done
	if [[ "$STATUS" == *401* ]]; then
		log "$(L "Nextcloud reaches rclone correctly." "Nextcloud raggiunge rclone correttamente.")"
	else
		warn "$(L "Nextcloud cannot reach $RCLONE_NAME:8080 (answer: '${STATUS:-none}'). Check: docker logs $RCLONE_NAME" "Nextcloud non riesce a raggiungere $RCLONE_NAME:8080 (risposta: '${STATUS:-nessuna}'). Controlla: docker logs $RCLONE_NAME")"
	fi
fi

echo
log "$(L "Done (mode $MODE)! Each user now goes to Personal settings → Google Drive." "Fatto (modalità $MODE)! Ogni utente ora va in Impostazioni personali → Google Drive.")"
[[ "$MODE" == webdav ]] && echo "$(L "   For mount mode (recommended): run again with 'install mount', the script explains what is needed." "   Per la modalità mount (consigliata): rilancia con 'install mount', lo script spiega cosa serve.")"
echo "$(L "   If the redirect URI shown starts with http:// but you use HTTPS:" "   Se l'URI di reindirizzamento mostrato inizia con http:// ma usi HTTPS:")"
echo "   docker exec -u $NC_UID $NC php $WEB/occ config:system:set overwriteprotocol --value=https"
