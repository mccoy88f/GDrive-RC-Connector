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
All'avvio chiede se **installare/aggiornare** o **disinstallare**.
Se hai più container Nextcloud aggiungi il nome: `... | sudo bash -s -- NOME_CONTAINER_NEXTCLOUD`.
Per saltare la domanda: `... | sudo bash -s -- install` (o `uninstall`).

Lo script trova il container Nextcloud, crea la cartella condivisa dentro la
cartella dati di Nextcloud (già persistente, quindi senza volumi da aggiungere),
installa e abilita l'app, avvia il container rclone sulla stessa rete e verifica il collegamento.
Si può rilanciare in qualsiasi momento, per esempio per aggiornare l'app o se un
aggiornamento di Nextcloud l'ha disattivata.

### Disinstallazione
Con lo stesso comando, scegliendo *Disinstalla*, si può:
1. **rimuovere app e rclone conservando i collegamenti**: reinstallando, ogni utente
   ritrova il proprio Google Drive già collegato;
2. **rimuovere tutto**: gli utenti vengono scollegati da Google (l'accesso viene revocato)
   e si cancellano credenziali OAuth, scelte, registro errori e cartelle di collegamento.

In entrambi i casi i file su Google Drive non vengono toccati, e lo script aspetta che rclone
abbia finito di inviare eventuali upload in coda. Senza terminale (es. in automatico):
`... | sudo YES=1 bash -s -- uninstall`, aggiungendo `PURGE=1` per rimuovere tutto.

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
occ config:app:set gdrivebridge previews --value=yes                # anteprime nella cartella (spente di default:
                                                                    # ognuna scarica il file intero da Google)
occ config:app:set gdrivebridge gdocs --value=skip                   # scelta predefinita per Documenti/Fogli Google:
                                                                    # link (default, file .link.html che aprono il
                                                                    # documento su Google) o skip (nascosti)
```
Ogni utente può comunque cambiare la scelta per i documenti Google nelle proprie
impostazioni, dove trova anche il **registro errori** della cartella Google Drive.

## Uso (ogni utente)
Impostazioni personali → **Google Drive**: la pagina contiene la guida per creare il
client OAuth su Google Cloud e mostra l'URI di reindirizzamento da copiare.

## File grandi
- **Download**: il file arriva all'utente mentre scende da Google (nessuna attesa iniziale,
  nessun limite di durata). Si interrompe solo se Google/rclone restano fermi per 120 secondi.
- **Upload**: Nextcloud consegna il file a rclone, che lo mette nella sua cache e lo invia a
  Google subito dopo, in background. Il caricamento risulta quindi completato in Nextcloud
  prima che il file sia davvero su Google: per i file molto grandi può servire qualche minuto.
  Serve spazio su disco per circa due volte la dimensione del file (temporanei di Nextcloud
  e cache di rclone). Limite di tempo per la consegna a rclone: 1 ora
  (`occ config:app:set gdrivebridge upload_timeout --value=SECONDI`).
- **Non riavviare rclone mentre carica** (`docker restart gdrive-rclone`): i file ancora in coda
  andrebbero persi. Lo script di installazione aspetta da solo che gli invii finiscano.
  Per vedere se ci sono invii in corso: `docker logs -f gdrive-rclone`.
- **Video**: si possono guardare, ma ogni spostamento nella riproduzione riparte a scaricare
  dal file da Google, quindi con video lunghi è lento.

## Problemi comuni
- **L'URI di reindirizzamento inizia con `http://`** anche se usi HTTPS: in `config.php`
  aggiungi `'overwriteprotocol' => 'https',`.
- **La cartella non compare o dà errore**: verifica che Nextcloud raggiunga rclone
  (`curl http://NOME_CONTAINER_RCLONE:8080` dal container Nextcloud deve dare 401)
  e guarda i log del container rclone.
- **L'accesso scade dopo 7 giorni**: l'app Google è rimasta in modalità "Test",
  va pubblicata ("In produzione").
- Se hai configurato prima un'archiviazione esterna WebDAV verso rclone, rimuovila.
