# Third-party software and terms

This project (licensed under [CC BY-NC 4.0](LICENSE)) works together with
third-party software and services that keep **their own licenses and terms**.
Using, forking or redistributing this project means respecting those too.

## rclone — MIT License
- Copyright (C) 2012 by Nick Craig-Wood and the rclone contributors.
- https://rclone.org — license: https://github.com/rclone/rclone/blob/master/COPYING
- rclone is **not included** in this repository: `install.sh` downloads the official
  `rclone/rclone` Docker image when it runs. If you redistribute rclone (for example
  inside your own image or package), you must keep its copyright notice and the MIT
  license text, as the MIT license requires.
- The MIT license of rclone allows commercial use of rclone itself: the
  non-commercial restriction of this project applies only to the code in this
  repository, not to rclone.

## Nextcloud — GNU AGPL v3
- https://nextcloud.com — https://github.com/nextcloud/server
- The `gdrivebridge` app runs inside Nextcloud and uses its APIs. Nextcloud is
  licensed under the GNU Affero General Public License v3 (or later): its terms apply
  to Nextcloud and to its official apps (such as External storage) used by this project.

## Google Drive API
- Each user connects with the OAuth client of **their own** Google Cloud project, so
  each user is bound by the [Google APIs Terms of Service](https://developers.google.com/terms)
  and the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy).

---

This project is not affiliated with, endorsed or sponsored by Google, Nextcloud GmbH
or the rclone project. "Google Drive" is a trademark of Google LLC; "Nextcloud" is a
trademark of Nextcloud GmbH.
