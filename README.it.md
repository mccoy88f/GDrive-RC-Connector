# Google Drive Bridge per Nextcloud

*[English](README.md)*

Ogni utente collega il **proprio** Google Drive usando le credenziali OAuth del **proprio**
progetto Google. Il Drive compare nei File come cartella «Google Drive».

```
Browser ──login Google──▶ Nextcloud (app gdrivebridge) ── scrive la configurazione rclone dell'utente
                                                            │
                          ┌─────────────────────────────────┴─────────────────────────┐
         modalità mount:  rclone monta il Drive come cartella (FUSE) ─▶ Archiviazione esterna
        modalità webdav:  rclone serve webdav ─▶ cartella montata dall'app
                                                            │
                                                            ▼
                                                il Google Drive dell'utente
```

## Installare, aggiornare, disinstallare

Dal **terminale del server** (in Coolify: *Servers → il tuo server → Terminal*), non dal
terminale del container Nextcloud:
```bash
curl -fsSL https://raw.githubusercontent.com/mccoy88f/gdrive-rc-connector/main/install.sh | sudo bash -s -- install it
```
Lo script non fa domande: cosa fare si indica alla fine del comando.

| Fine del comando | Cosa fa |
|---|---|
| `install` | installa o aggiorna; modalità mount se Nextcloud ha già il volume `/gdrive`, altrimenti webdav |
| `install mount` | installa o aggiorna in modalità mount (consigliata) |
| `install webdav` | installa o aggiorna in modalità webdav |
| `uninstall` | rimuove app e rclone, conserva i collegamenti degli utenti |
| `uninstall purge` | rimuove tutto, compresi collegamenti e credenziali degli utenti |

Si possono aggiungere: `it` / `en` (lingua dei messaggi; di default quella del sistema,
altrimenti inglese) e il nome del container Nextcloud se sul server ce n'è più d'uno, per
esempio `... | sudo bash -s -- install mount it`.

Lo script trova il container Nextcloud (immagine ufficiale o linuxserver), crea la cartella
condivisa dentro la cartella dati di Nextcloud (già persistente), installa e abilita l'app,
avvia il container rclone e verifica il collegamento. Si può rilanciare in qualsiasi momento,
per esempio per aggiornare l'app o dopo un aggiornamento di Nextcloud. Gli utenti restano collegati.

### Modalità

- **Mount (consigliata)**: rclone monta il Google Drive di ogni utente come cartella (FUSE) e
  Nextcloud la vede con l'app ufficiale *Archiviazione esterna* (tipo Locale, solo per il
  gruppo «Google Drive», a cui l'app aggiunge chi si collega). I file si comportano come file
  locali: ci si sposta nei video, i file grandi arrivano in streaming, gli upload in coda
  sopravvivono ai riavvii di rclone. L'Archiviazione esterna la attiva lo script.
  Serve **una riga nel compose di Nextcloud**, da aggiungere una volta sola (resta anche dopo
  gli aggiornamenti). Lancia prima `install mount`: prepara la cartella sull'host e, se la riga
  manca, te la mostra e intanto installa in modalità webdav. Poi in Coolify: risorsa
  Nextcloud → *Edit Compose File* → nel servizio **`nextcloud`** (non nel database), sotto `volumes:`
  ```yaml
        - '/data/gdrive-bridge/mnt:/gdrive:rslave'
  ```
  salva, fai *Restart* della risorsa e rilancia `install mount`.
- **WebDAV**: l'app monta il WebDAV di rclone. Nessuna modifica a Nextcloud.

### Disinstallazione
- `uninstall`: rimuove app e rclone conservando i collegamenti: reinstallando, ogni utente
  ritrova il proprio Google Drive già collegato.
- `uninstall purge`: scollega gli utenti da Google (l'accesso viene revocato) e cancella
  credenziali OAuth, scelte, registro errori e cartelle di collegamento. In modalità mount
  togli prima la riga `/gdrive` dal compose di Nextcloud: lo script ti avvisa se c'è ancora.

In entrambi i casi i file su Google Drive non vengono toccati, e lo script aspetta che rclone
abbia finito di inviare eventuali upload in coda.

## Uso (ogni utente)
Impostazioni personali → **Google Drive**: la pagina contiene la guida per creare il client
OAuth su Google Cloud e mostra l'URI di reindirizzamento da copiare. Nella stessa pagina:
- **Documenti, Fogli e Presentazioni Google**: non sono file veri e tramite rclone
  risulterebbero vuoti, quindi si mostrano come collegamenti `.link.html` che aprono il
  documento su Google, oppure si nascondono;
- **Registro errori**: gli ultimi problemi della cartella (rclone non raggiungibile, token
  scaduto, download non riusciti…), spiegati, con gli errori ripetuti raggruppati;
- la verifica che il login Google sia ancora valido, a ogni apertura della pagina.

L'app è in inglese con traduzione italiana: ognuno la vede nella lingua del proprio profilo
Nextcloud.

## Opzioni
Da lanciare sul server (con l'immagine linuxserver usa `-u 1000` o l'utente giusto e
`/app/www/public/occ`):
```bash
occ config:app:set gdrivebridge previews --value=yes   # anteprime nella cartella (spente di default:
                                                       # ognuna scarica il file intero da Google)
occ config:app:set gdrivebridge gdocs --value=skip     # scelta predefinita per i documenti Google: link o skip
occ config:app:set gdrivebridge mount_name --value="Google Drive"   # nome della cartella
occ config:app:set gdrivebridge upload_timeout --value=3600         # modalità webdav: secondi massimi per upload verso rclone
```
Dopo aver cambiato `previews` o `mount_name`, rilancia lo script perché le applichi.

## File grandi
- **Download**: il file arriva all'utente mentre scende da Google, senza attese e senza
  limiti di durata.
- **Upload**: rclone mette il file nella sua cache e lo invia a Google subito dopo, in
  background: in Nextcloud il caricamento risulta completato prima che il file sia davvero
  su Google. Spazio su disco necessario: circa il doppio del file (temporanei di Nextcloud e
  cache di rclone).
- **Non riavviare rclone mentre carica** in modalità webdav: i file in coda andrebbero persi
  (in modalità mount riprendono). Lo script aspetta da solo. Per vedere cosa sta inviando:
  `docker logs -f gdrive-rclone`.

## Problemi comuni
- **L'URI di reindirizzamento inizia con `http://`** anche se usi HTTPS: in `config.php`
  aggiungi `'overwriteprotocol' => 'https',`.
- **La cartella non compare o dà errore**: guarda il registro errori nelle impostazioni
  dell'utente e `docker logs gdrive-rclone`.
- **L'accesso scade dopo 7 giorni**: l'app Google è rimasta in "Test", pubblicala
  ("In produzione") e ricollegati una volta.
