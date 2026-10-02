<?php

declare(strict_types=1);

namespace OCA\GDriveBridge\Settings;

use OCA\GDriveBridge\AppInfo\Application;
use OCA\GDriveBridge\Service\BridgeService;
use OCP\AppFramework\Http\TemplateResponse;
use OCP\IURLGenerator;
use OCP\IUserSession;
use OCP\Settings\ISettings;
use OCP\Util;

class Personal implements ISettings {
	public function __construct(
		private BridgeService $bridge,
		private IUserSession $userSession,
		private IURLGenerator $urlGenerator,
	) {
	}

	public function getForm(): TemplateResponse {
		$uid = $this->userSession->getUser()?->getUID() ?? '';
		Util::addStyle(Application::APP_ID, 'personal');

		return new TemplateResponse(Application::APP_ID, 'personal', [
			'flash' => $this->bridge->popFlash($uid),
			'clientId' => $this->bridge->getClientId($uid),
			'hasSecret' => $this->bridge->hasClientSecret($uid),
			'hasCredentials' => $this->bridge->hasClientCredentials($uid),
			'connected' => $this->bridge->isConnected($uid),
			'email' => $this->bridge->getGoogleEmail($uid),
			'redirectUri' => $this->bridge->getRedirectUri(),
			'bridgeOk' => $this->bridge->isBridgeDirWritable(),
			'bridgeDir' => $this->bridge->getBridgeDir(),
			'mountName' => $this->bridge->getMountName(),
			'saveUrl' => $this->urlGenerator->linkToRoute('gdrivebridge.oauth.saveCredentials'),
			'startUrl' => $this->urlGenerator->linkToRoute('gdrivebridge.oauth.start'),
			'disconnectUrl' => $this->urlGenerator->linkToRoute('gdrivebridge.oauth.disconnect'),
		], '');
	}

	public function getSection(): string {
		return Application::APP_ID;
	}

	public function getPriority(): int {
		return 10;
	}
}
