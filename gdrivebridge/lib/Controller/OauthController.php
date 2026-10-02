<?php

declare(strict_types=1);

namespace OCA\GDriveBridge\Controller;

use OCA\GDriveBridge\AppInfo\Application;
use OCA\GDriveBridge\Service\BridgeService;
use OCP\AppFramework\Controller;
use OCP\AppFramework\Http\Attribute\NoAdminRequired;
use OCP\AppFramework\Http\Attribute\NoCSRFRequired;
use OCP\AppFramework\Http\Attribute\NoSameSiteCookieRequired;
use OCP\AppFramework\Http\RedirectResponse;
use OCP\IRequest;
use OCP\IURLGenerator;
use OCP\IUserSession;

class OauthController extends Controller {
	public function __construct(
		IRequest $request,
		private BridgeService $bridge,
		private IUserSession $userSession,
		private IURLGenerator $urlGenerator,
	) {
		parent::__construct(Application::APP_ID, $request);
	}

	private function uid(): string {
		return $this->userSession->getUser()?->getUID() ?? '';
	}

	private function back(): RedirectResponse {
		return new RedirectResponse(
			$this->urlGenerator->linkToRoute('settings.PersonalSettings.index', ['section' => Application::APP_ID])
		);
	}

	/** @NoAdminRequired */
	#[NoAdminRequired]
	public function saveCredentials(string $client_id = '', string $client_secret = ''): RedirectResponse {
		$uid = $this->uid();
		try {
			$this->bridge->saveClientCredentials($uid, $client_id, $client_secret);
			$this->bridge->setFlash($uid, 'ok', 'Credenziali salvate.');
		} catch (\InvalidArgumentException $e) {
			$this->bridge->setFlash($uid, 'error', $e->getMessage());
		}
		return $this->back();
	}

	/**
	 * @NoAdminRequired
	 * @NoCSRFRequired
	 */
	#[NoAdminRequired]
	#[NoCSRFRequired]
	public function start(): RedirectResponse {
		$uid = $this->uid();
		try {
			return new RedirectResponse($this->bridge->buildAuthUrl($uid));
		} catch (\RuntimeException $e) {
			$this->bridge->setFlash($uid, 'error', $e->getMessage());
			return $this->back();
		}
	}

	/**
	 * @NoAdminRequired
	 * @NoCSRFRequired
	 * @NoSameSiteCookieRequired
	 */
	#[NoAdminRequired]
	#[NoCSRFRequired]
	#[NoSameSiteCookieRequired]
	public function callback(string $code = '', string $state = '', string $error = ''): RedirectResponse {
		$uid = $this->uid();
		if ($error !== '') {
			$this->bridge->setFlash($uid, 'error', 'Autorizzazione annullata o negata da Google (' . $error . ').');
			return $this->back();
		}
		try {
			$this->bridge->handleCallback($uid, $code, $state);
			$this->bridge->setFlash($uid, 'ok',
				'Google Drive collegato! Lo trovi nei File come cartella «' . $this->bridge->getMountName() . '».');
		} catch (\RuntimeException $e) {
			$this->bridge->setFlash($uid, 'error', $e->getMessage());
		}
		return $this->back();
	}

	/** @NoAdminRequired */
	#[NoAdminRequired]
	public function disconnect(): RedirectResponse {
		$uid = $this->uid();
		$this->bridge->disconnect($uid);
		$this->bridge->setFlash($uid, 'ok', 'Google Drive scollegato.');
		return $this->back();
	}
}
