# Google Drive Bridge per Nextcloud

Ogni utente collega il **proprio** Google Drive usando le credenziali OAuth del
**proprio** progetto Google. Il Drive compare nei File come cartella «Google Drive».

```
Browser ──login Google──▶ Nextcloud (app gdrivebridge)
                              │ scrive /gdrive-bridge/<hash>.json (token dell'utente)
                              │ monta WebDAV con credenziali casuali per utente
                              ▼
                     rclone serve webdav --auth-proxy ──▶ Google Drive dell'utente
```

## Installazione automatica (consigliata)

Dal **terminale del server** (in Coolify: *Servers → il tuo server → Terminal*),
non dal terminale del container Nextcloud:
```bash
curl -fsSL https://raw.githubusercontent.com/mccoy88f/gdrive-rc-connector/main/install.sh | sudo bash
```
Se hai più container Nextcloud aggiungi il nome: `... | sudo bash -s -- NOME_CONTAINER_NEXTCLOUD`.

Lo script trova il container Nextcloud, crea la cartella condivisa dentro la
cartella dati di Nextcloud (già persistente, quindi senza volumi da aggiungere),
installa e abilita l'app, avvia il container rclone sulla stessa rete e verifica il collegamento.
Si può rilanciare in qualsiasi momento, per esempio per aggiornare l'app o se un
aggiornamento di Nextcloud l'ha disattivata.

## Installazione manuale (una volta sola, sul server)

### 1. Cartelle condivise sull'host
Copia `server/setup-bridge.sh` sul server e lancialo:
```bash
sudo bash setup-bridge.sh NOME_CONTAINER_NEXTCLOUD
```
Crea `/data/gdrive-bridge/users` (scrivibile solo da Nextcloud) e
`/data/gdrive-bridge/proxy/auth-proxy.sh`.

### 2. Container rclone (Coolify)
Sostituisci il compose della risorsa rclone con `server/docker-compose.rclone.yml`.
Lascia attiva la rete predefinita di Coolify e fai il deploy.
Non serve più nessun `rclone.conf`.

### 3. Volume in Nextcloud (Coolify)
Nella risorsa Nextcloud aggiungi uno storage persistente di tipo bind:
- sorgente sull'host: `/data/gdrive-bridge/users`
- destinazione nel container: `/gdrive-bridge`

Poi Redeploy.

### 4. Installa l'app
```bash
docker cp gdrivebridge NOME_CONTAINER_NEXTCLOUD:/var/www/html/custom_apps/
docker exec NOME_CONTAINER_NEXTCLOUD chown -R www-data:www-data /var/www/html/custom_apps/gdrivebridge
docker exec -u www-data NOME_CONTAINER_NEXTCLOUD php occ app:enable gdrivebridge
```
(Con l'immagine linuxserver il percorso è diverso, di solito `/config/www/nextcloud/custom_apps`
oppure `/app/www/public/custom_apps`, e l'utente è `abc`.)

### 5. Indirizzo del container rclone
```bash
docker ps --format '{{.Names}}' | grep rclone
docker exec -u www-data NOME_CONTAINER_NEXTCLOUD php occ config:app:set gdrivebridge rclone_host --value=NOME_CONTAINER_RCLONE:8080
```

### Opzioni (facoltative)
```bash
occ config:app:set gdrivebridge mount_name --value="Google Drive"   # nome della cartella
occ config:app:set gdrivebridge bridge_dir --value=/gdrive-bridge     # cartella condivisa
```

## Uso (ogni utente)
Impostazioni personali → **Google Drive**: la pagina contiene la guida per creare il
client OAuth su Google Cloud e mostra l'URI di reindirizzamento da copiare.

## Problemi comuni
- **L'URI di reindirizzamento inizia con `http://`** anche se usi HTTPS: in `config.php`
  aggiungi `'overwriteprotocol' => 'https',`.
- **La cartella non compare o dà errore**: verifica che Nextcloud raggiunga rclone
  (`curl http://NOME_CONTAINER_RCLONE:8080` dal container Nextcloud deve dare 401)
  e guarda i log del container rclone.
- **L'accesso scade dopo 7 giorni**: l'app Google è rimasta in modalità "Test",
  va pubblicata ("In produzione").
- Se hai configurato prima un'archiviazione esterna WebDAV verso rclone, rimuovila.
