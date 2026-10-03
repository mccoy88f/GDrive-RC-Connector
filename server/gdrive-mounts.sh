#!/bin/sh
# =============================================================================
#  Mount mode: runs in the rclone container and mounts the Google Drive of
#  every connected user as a folder (FUSE).
#
#   /bridge/users/<uid>.conf   rclone config written by Nextcloud
#   /mnt/gdrive/<uid>          mount point (seen by Nextcloud as /gdrive/<uid>)
#   /cache/<uid>/              rclone cache: queued uploads survive restarts
#   /bridge/users/<uid>.errors rclone errors, shown in the user's settings
#
#  Every few seconds it mounts new users, unmounts disconnected ones, and
#  remounts stuck mounts and those whose config changed (e.g. Google Docs choice).
#  Messages in Italian with GDB_LANG=it.
# =============================================================================
L() { if [ "${GDB_LANG:-en}" = it ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }

UIDNC="${NC_UID:-33}"
GIDNC="${NC_GID:-33}"
USERS=/bridge/users
MNT=/mnt/gdrive
CACHE=/cache
mkdir -p "$MNT" "$CACHE"

# In /proc/mounts spaces in paths are written as \040
is_mounted() {
	P=$(printf '%s' "$1" | sed 's/\\/\\134/g; s/ /\\040/g') awk '$2 == ENVIRON["P"] { f = 1 } END { exit !f }' /proc/mounts
}

unmount() {
	fusermount3 -u "$1" 2>/dev/null || umount -l "$1" 2>/dev/null
}

# Fingerprint of the config without the token, which rclone updates itself
conf_hash() {
	grep -v '^token' "$1" | md5sum | cut -d' ' -f1
}

mount_user() {
	u="$1"; c="$USERS/$u.conf"; m="$MNT/$u"; h=$(conf_hash "$c")
	# After a failed attempt retry after 60 seconds, or right away if the config changes
	if [ -f "$CACHE/$u.failed" ] && [ "$(cat "$CACHE/$u.failed")" = "$h" ] \
		&& [ $(( $(date +%s) - $(stat -c %Y "$CACHE/$u.failed") )) -lt 60 ]; then
		return 1
	fi
	mkdir -p "$m" "$CACHE/$u"
	# Startup errors (e.g. invalid token) go to stderr, before the log starts
	if rclone mount gdrive: "$m" --config "$c" --daemon \
		--allow-other --uid "$UIDNC" --gid "$GIDNC" --umask 007 \
		--vfs-cache-mode writes --cache-dir "$CACHE/$u" \
		--dir-cache-time 1m --poll-interval 1m \
		--log-level NOTICE --log-file "$CACHE/$u.log" 2>> "$CACHE/$u.log"; then
		echo "$h" > "$CACHE/$u.hash"
		rm -f "$CACHE/$u.failed"
		echo "$(date '+%F %T') $(L mounted montato): $u"
	else
		echo "$h" > "$CACHE/$u.failed"
		echo "$(date '+%F %T') $(L "mount failed" "mount non riuscito"): $u ($(L "details in the user's settings, error log" "dettagli nelle impostazioni dell'utente, registro errori"))"
		return 1
	fi
}

# Copy the new error lines of the rclone log to the file read by Nextcloud
collect_errors() {
	u="$1"; log="$CACHE/$u.log"; pos_file="$CACHE/$u.logpos"
	[ -f "$log" ] || return 0
	size=$(stat -c %s "$log"); pos=$(cat "$pos_file" 2>/dev/null || echo 0)
	[ "$size" -lt "$pos" ] && pos=0
	if [ "$size" -gt "$pos" ]; then
		tail -c +$((pos + 1)) "$log" | grep -E ' (ERROR|CRITICAL) ?:' >> "$USERS/$u.errors" 2>/dev/null
		[ -f "$USERS/$u.errors" ] && tail -n 50 "$USERS/$u.errors" > "$USERS/$u.errors.tmp" \
			&& chown "$UIDNC:$GIDNC" "$USERS/$u.errors.tmp" && mv "$USERS/$u.errors.tmp" "$USERS/$u.errors"
	fi
	# Log limited to 5 MB
	if [ "$size" -gt 5242880 ]; then : > "$log"; size=0; fi
	echo "$size" > "$pos_file"
}

stop_all() {
	for m in "$MNT"/*; do
		[ -d "$m" ] && is_mounted "$m" && unmount "$m"
	done
	exit 0
}
trap stop_all TERM INT

while true; do
	for c in "$USERS"/*.conf; do
		[ -f "$c" ] || continue
		u=$(basename "$c" .conf); m="$MNT/$u"
		if is_mounted "$m"; then
			if ! ls "$m" >/dev/null 2>&1; then
				echo "$(date '+%F %T') $(L "mount stuck, remounting" "mount bloccato, lo rifaccio"): $u"; unmount "$m"
			elif [ "$(conf_hash "$c")" != "$(cat "$CACHE/$u.hash" 2>/dev/null)" ]; then
				echo "$(date '+%F %T') $(L "config changed, remounting" "configurazione cambiata, rimonto"): $u"; unmount "$m"
			fi
		fi
		is_mounted "$m" || mount_user "$u"
		collect_errors "$u"
	done
	for m in "$MNT"/*; do
		[ -d "$m" ] || is_mounted "$m" || continue
		u=$(basename "$m")
		[ -f "$USERS/$u.conf" ] && continue
		is_mounted "$m" && unmount "$m" && echo "$(date '+%F %T') $(L unmounted smontato): $u"
		rmdir "$m" 2>/dev/null
	done
	sleep 5 &
	wait $!
done
