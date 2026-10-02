<?php

declare(strict_types=1);

namespace OCA\GDriveBridge\Mount;

use OC\Files\Mount\MountPoint;
use OC\Files\Storage\DAV;
use OCA\GDriveBridge\Service\BridgeService;
use OCP\Files\Config\IMountProvider;
use OCP\Files\Storage\IStorageFactory;
use OCP\IUser;

/**
 * Monta il WebDAV di rclone (con le credenziali dell'utente) come cartella
 * "Google Drive" nei suoi File.
 */
class MountProvider implements IMountProvider {
	public function __construct(
		private BridgeService $bridge,
	) {
	}

	public function getMountsForUser(IUser $user, IStorageFactory $loader): array {
		$uid = $user->getUID();
		$creds = $this->bridge->getDavCredentials($uid);
		if ($creds === null) {
			return [];
		}

		return [
			new MountPoint(
				DAV::class,
				'/' . $uid . '/files/' . $this->bridge->getMountName(),
				[
					'host' => $this->bridge->getRcloneHost(),
					'user' => $creds['user'],
					'password' => $creds['password'],
					'root' => '/',
					'secure' => false,
				],
				$loader,
				['filesystem_check_changes' => 1],
				null,
				self::class
			),
		];
	}
}
