<?php

declare(strict_types=1);

namespace OCA\GDriveBridge\AppInfo;

use OCA\GDriveBridge\Mount\MountProvider;
use OCP\AppFramework\App;
use OCP\AppFramework\Bootstrap\IBootContext;
use OCP\AppFramework\Bootstrap\IBootstrap;
use OCP\AppFramework\Bootstrap\IRegistrationContext;
use OCP\Files\Config\IMountProviderCollection;

class Application extends App implements IBootstrap {
	public const APP_ID = 'gdrivebridge';

	public function __construct() {
		parent::__construct(self::APP_ID);
	}

	public function register(IRegistrationContext $context): void {
	}

	public function boot(IBootContext $context): void {
		// Monta "Google Drive" nei File degli utenti collegati
		$context->injectFn(function (IMountProviderCollection $collection, MountProvider $provider): void {
			$collection->registerProvider($provider);
		});
	}
}
