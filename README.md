# Google Drive Bridge for Nextcloud

*[Italiano](README.it.md)*

Each user connects **their own** Google Drive using the OAuth credentials of **their own**
Google project. The Drive shows up in Files as the folder “Google Drive”.

```
Browser ──Google login──▶ Nextcloud (gdrivebridge app) ── writes the user's rclone config
                                                            │
                          ┌─────────────────────────────────┴─────────────────────────┐
             mount mode:  rclone mounts the Drive as a folder (FUSE) ─▶ External storage
            webdav mode:  rclone serve webdav ─▶ folder mounted by the app
                                                            │
                                                            ▼
                                                  the user's Google Drive
```

## Install, update, uninstall

From the **server terminal** (in Coolify: *Servers → your server → Terminal*), not from the
Nextcloud container terminal:
```bash
curl -fsSL https://raw.githubusercontent.com/mccoy88f/gdrive-rc-connector/main/install.sh | sudo bash -s -- install
```
The script asks no questions: what to do goes at the end of the command.

| End of the command | What it does |
|---|---|
| `install` | install or update; mount mode if Nextcloud already has the `/gdrive` volume, otherwise webdav |
| `install mount` | install or update in mount mode (recommended) |
| `install webdav` | install or update in webdav mode |
| `uninstall` | remove the app and rclone, keep the users' connections |
| `uninstall purge` | remove everything, including the users' connections and credentials |

Options that can be added: `en` / `it` (language of the messages, default: system language,
otherwise English) and the name of the Nextcloud container if the server has more than one,
e.g. `... | sudo bash -s -- install mount it`.

The script finds the Nextcloud container (official or linuxserver image), creates the shared
folder inside the Nextcloud data folder (already persistent), installs and enables the app,
starts the rclone container and checks the connection. Run it again at any time, for example
to update the app or after a Nextcloud update. Users stay connected.

### Modes

- **Mount (recommended)**: rclone mounts each user's Google Drive as a folder (FUSE) and
  Nextcloud shows it through the official *External storage* app (Local type, only for the
  “Google Drive” group, which the app adds connected users to). Files behave like local
  files: seeking in videos works, large files are streamed, queued uploads survive rclone
  restarts. The script enables External storage by itself.
  It needs **one line in the Nextcloud compose**, added once (it stays after updates).
  Run `install mount` first: it prepares the host folder and, if the line is missing, shows
  it and meanwhile installs in webdav mode. Then in Coolify: Nextcloud resource →
  *Edit Compose File* → in the **`nextcloud`** service (not the database), under `volumes:`
  ```yaml
        - '/data/gdrive-bridge/mnt:/gdrive:rslave'
  ```
  save, *Restart* the resource and run `install mount` again.
- **WebDAV**: the app mounts rclone's WebDAV. No change to Nextcloud.

### Uninstall
- `uninstall`: removes the app and rclone, keeps the connections: after reinstalling, every
  user finds their Google Drive already connected.
- `uninstall purge`: disconnects users from Google (access is revoked) and deletes OAuth
  credentials, choices, error log and link folders. In mount mode, first remove the
  `/gdrive` line from the Nextcloud compose: the script tells you if it is still there.

In both cases the files on Google Drive are not touched, and the script waits for rclone to
finish sending any queued upload.

## Usage (each user)
Personal settings → **Google Drive**: the page has the guide to create the OAuth client on
Google Cloud and shows the redirect URI to copy. On the same page:
- **Google Docs, Sheets and Slides**: they are not real files and through rclone they would
  appear empty, so they are shown as `.link.html` links that open the document on Google,
  or hidden;
- **Error log**: the latest problems of the folder (rclone unreachable, expired token,
  failed downloads…), explained, with repeated errors grouped;
- the check that the Google login is still valid every time the page is opened.

The app is in English with an Italian translation: everyone sees it in the language of
their Nextcloud profile.

## Options
Run from the server (with the linuxserver image use `-u 1000` or the right user and
`/app/www/public/occ`):
```bash
occ config:app:set gdrivebridge previews --value=yes   # previews in the folder (off by default: each one
                                                       # downloads the whole file from Google)
occ config:app:set gdrivebridge gdocs --value=skip     # default choice for Google Docs: link or skip
occ config:app:set gdrivebridge mount_name --value="Google Drive"   # folder name
occ config:app:set gdrivebridge upload_timeout --value=3600         # webdav mode: max seconds per upload to rclone
```
After changing `previews` or `mount_name`, run the script again so it applies them.

## Large files
- **Download**: the file reaches the user while it comes down from Google, with no waiting
  and no duration limit.
- **Upload**: rclone puts the file in its cache and sends it to Google right after, in the
  background: in Nextcloud the upload is complete before the file is really on Google.
  Disk space needed: about twice the file size (Nextcloud temporary files and rclone cache).
- **Do not restart rclone while it is uploading** in webdav mode: queued files would be lost
  (in mount mode they resume). The script waits by itself. To see what is being sent:
  `docker logs -f gdrive-rclone`.

## Troubleshooting
- **The redirect URI starts with `http://`** although you use HTTPS: in `config.php` add
  `'overwriteprotocol' => 'https',`.
- **The folder does not appear or shows an error**: look at the error log in the user's
  settings and at `docker logs gdrive-rclone`.
- **Access expires after 7 days**: the Google app is still in “Testing”, publish it
  (“In production”), then reconnect once.
