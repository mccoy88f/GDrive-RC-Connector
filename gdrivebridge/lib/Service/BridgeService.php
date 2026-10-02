<?php

declare(strict_types=1);

namespace OCA\GDriveBridge\Service;

use OCA\GDriveBridge\AppInfo\Application;
use OCP\EventDispatcher\IEventDispatcher;
use OCP\Files\Events\InvalidateMountCacheEvent;
use OCP\Http\Client\IClientService;
use OCP\IConfig;
use OCP\IGroupManager;
use OCP\IURLGenerator;
use OCP\IUserManager;
use OCP\Security\ICrypto;
use OCP\Security\ISecureRandom;
use Psr\Log\LoggerInterface;

/**
 * Gestisce credenziali OAuth per utente, il login Google e il file di
 * collegamento letto dall'auth-proxy di rclone.
 *
 * Il file di collegamento si chiama sha256("<dav_user>:<dav_pass>").json e
 * contiene la configurazione del remote rclone (tipo drive) dell'utente.
 */
class BridgeService {
	private const APP = Application::APP_ID;
	private const AUTH_URL = 'https://accounts.google.com/o/oauth2/v2/auth';
	private const TOKEN_URL = 'https://oauth2.googleapis.com/token';
	private const REVOKE_URL = 'https://oauth2.googleapis.com/revoke';
	private const ABOUT_URL = 'https://www.googleapis.com/drive/v3/about?fields=user';
	private const SCOPE = 'https://www.googleapis.com/auth/drive';
	private const GDOCS_MODES = ['link', 'skip'];
	private const MAX_ERRORS = 20;
	/** Gruppo a cui è applicata l'archiviazione esterna nella modalità mount */
	public const GROUP_ID = 'gdrive';

	public function __construct(
		private IConfig $config,
		private ICrypto $crypto,
		private IClientService $clientService,
		private IURLGenerator $urlGenerator,
		private ISecureRandom $random,
		private LoggerInterface $logger,
		private IEventDispatcher $dispatcher,
		private IUserManager $userManager,
		private IGroupManager $groupManager,
	) {
	}

	/* ---------- Impostazioni di istanza (occ config:app:set) ---------- */

	public function getBridgeDir(): string {
		return rtrim($this->config->getAppValue(self::APP, 'bridge_dir', '/gdrive-bridge'), '/');
	}

	public function getRcloneHost(): string {
		return $this->config->getAppValue(self::APP, 'rclone_host', 'rclone-gdrive:8080');
	}

	/**
	 * 'webdav': la cartella è montata dall'app tramite il WebDAV di rclone.
	 * 'mount': rclone monta il Drive come cartella (FUSE) e Nextcloud la vede
	 * con l'Archiviazione esterna di tipo Locale (configurata da install.sh).
	 */
	public function getMode(): string {
		return $this->config->getAppValue(self::APP, 'mode', 'webdav') === 'mount' ? 'mount' : 'webdav';
	}

	public function getMountName(): string {
		return $this->config->getAppValue(self::APP, 'mount_name', 'Google Drive');
	}

	/** Anteprime nella cartella: spente di default, ogni anteprima scarica il file intero da Google */
	public function previewsEnabled(): bool {
		return $this->config->getAppValue(self::APP, 'previews', 'no') === 'yes';
	}

	/**
	 * Come mostrare Documenti/Fogli/Presentazioni Google (scelta dell'utente,
	 * predefinita dall'amministratore): 'link' collegamenti .link.html che aprono
	 * il documento su Google, 'skip' nascosti. Convertirli in docx/xlsx non è
	 * un'opzione: con rclone serve risultano di dimensione 0 e si aprono vuoti.
	 */
	public function getGdocsMode(string $uid): string {
		$mode = $this->get($uid, 'gdocs');
		if ($mode === '') {
			$mode = $this->config->getAppValue(self::APP, 'gdocs', 'link');
		}
		return in_array($mode, self::GDOCS_MODES, true) ? $mode : 'link';
	}

	public function isBridgeDirWritable(): bool {
		$dir = $this->getBridgeDir();
		return is_dir($dir) && is_writable($dir);
	}

	public function getRedirectUri(): string {
		return $this->urlGenerator->linkToRouteAbsolute('gdrivebridge.oauth.callback');
	}

	/* ---------- Valori utente ---------- */

	private function get(string $uid, string $key, bool $encrypted = false): string {
		$value = $this->config->getUserValue($uid, self::APP, $key, '');
		if ($value === '' || !$encrypted) {
			return $value;
		}
		try {
			return $this->crypto->decrypt($value);
		} catch (\Throwable $e) {
			$this->logger->warning('Impossibile decifrare ' . $key, ['app' => self::APP, 'exception' => $e]);
			return '';
		}
	}

	private function set(string $uid, string $key, string $value, bool $encrypt = false): void {
		$this->config->setUserValue($uid, self::APP, $key, $encrypt ? $this->crypto->encrypt($value) : $value);
	}

	private function del(string $uid, string ...$keys): void {
		foreach ($keys as $key) {
			$this->config->deleteUserValue($uid, self::APP, $key);
		}
	}

	/* ---------- Credenziali OAuth dell'utente ---------- */

	public function getClientId(string $uid): string {
		return $this->get($uid, 'client_id');
	}

	public function hasClientSecret(string $uid): bool {
		return $this->get($uid, 'client_secret') !== '';
	}

	public function hasClientCredentials(string $uid): bool {
		return $this->getClientId($uid) !== '' && $this->hasClientSecret($uid);
	}

	public function saveClientCredentials(string $uid, string $clientId, string $clientSecret): void {
		$clientId = trim($clientId);
		$clientSecret = trim($clientSecret);
		if ($clientId === '') {
			throw new \InvalidArgumentException('Il Client ID è obbligatorio.');
		}
		if ($clientSecret === '' && !$this->hasClientSecret($uid)) {
			throw new \InvalidArgumentException('Il Client secret è obbligatorio.');
		}

		$changed = $clientId !== $this->getClientId($uid)
			|| ($clientSecret !== '' && $clientSecret !== $this->get($uid, 'client_secret', true));

		// Cambiando app Google il vecchio token non vale più
		if ($changed && $this->isConnected($uid)) {
			$this->disconnect($uid);
		}

		$this->set($uid, 'client_id', $clientId);
		if ($clientSecret !== '') {
			$this->set($uid, 'client_secret', $clientSecret, true);
		}
	}

	/* ---------- Stato collegamento ---------- */

	public function isConnected(string $uid): bool {
		return $this->get($uid, 'dav_user') !== '' && $this->get($uid, 'refresh_token') !== '';
	}

	public function getGoogleEmail(string $uid): string {
		return $this->get($uid, 'google_email');
	}

	/** @return array{user: string, password: string}|null */
	public function getDavCredentials(string $uid): ?array {
		if (!$this->isConnected($uid)) {
			return null;
		}
		$pass = $this->get($uid, 'dav_pass', true);
		if ($pass === '') {
			return null;
		}
		return ['user' => $this->get($uid, 'dav_user'), 'password' => $pass];
	}

	/**
	 * Chiede a Google un nuovo access token con il refresh token salvato,
	 * per capire se il collegamento funziona ancora.
	 *
	 * @return string 'ok' | 'expired' (token scaduto o revocato) |
	 *                'client' (Client ID/secret non più validi) | 'unknown' (Google non raggiungibile)
	 */
	public function checkToken(string $uid): string {
		if ($this->get($uid, 'refresh_token', true) === '') {
			return 'expired';
		}
		$result = $this->fetchToken($uid);
		if ($result === null) {
			return 'unknown';
		}

		[$status, $data] = $result;
		if ($status === 200) {
			$this->refreshBridgeFile($uid, $data);
			return 'ok';
		}
		$error = (string)($data['error'] ?? '');
		if ($error === 'invalid_grant') {
			$this->logError($uid, 'Google ha rifiutato l\'accesso: token scaduto o revocato. Ricollega Google Drive.');
			return 'expired';
		}
		if ($error === 'invalid_client' || $error === 'unauthorized_client') {
			$this->logError($uid, 'Google non accetta più Client ID o Client secret (' . $error . ').');
			return 'client';
		}
		$this->logger->info('Verifica del token Google: risposta ' . $status . ' ' . $error, ['app' => self::APP]);
		return 'unknown';
	}

	/**
	 * Chiede a Google un nuovo access token con il refresh token salvato.
	 *
	 * @return array{0: int, 1: array}|null stato HTTP e risposta, null se Google non risponde
	 */
	private function fetchToken(string $uid): ?array {
		try {
			$response = $this->clientService->newClient()->post(self::TOKEN_URL, [
				'body' => [
					'grant_type' => 'refresh_token',
					'refresh_token' => $this->get($uid, 'refresh_token', true),
					'client_id' => $this->getClientId($uid),
					'client_secret' => $this->get($uid, 'client_secret', true),
				],
				'timeout' => 5,
				'http_errors' => false,
			]);
		} catch (\Throwable $e) {
			$this->logger->info('Richiesta del token Google non riuscita', ['app' => self::APP, 'exception' => $e]);
			return null;
		}
		$data = json_decode((string)$response->getBody(), true);
		return [$response->getStatusCode(), is_array($data) ? $data : []];
	}

	/**
	 * Riscrive il file per rclone con il nuovo access token e le impostazioni
	 * attuali. Con $rotate cambia anche la password WebDAV: rclone tiene in cache
	 * il backend per ogni password, quindi solo così le modifiche valgono subito.
	 */
	private function refreshBridgeFile(string $uid, array $token, bool $rotate = false): bool {
		$creds = $this->getDavCredentials($uid);
		$access = (string)($token['access_token'] ?? '');
		if ($creds === null || $access === '') {
			return false;
		}
		$pass = $rotate ? $this->random->generate(48, ISecureRandom::CHAR_ALPHANUMERIC) : $creds['password'];
		try {
			$this->writeBridgeFile($uid, $creds['user'], $pass, $this->getClientId($uid),
				$this->get($uid, 'client_secret', true), $access, $this->get($uid, 'refresh_token', true),
				gmdate('Y-m-d\TH:i:s\Z', time() + (int)($token['expires_in'] ?? 3600)));
		} catch (\Throwable $e) {
			$this->logger->warning('Aggiornamento del file per rclone non riuscito', ['app' => self::APP, 'exception' => $e]);
			$this->logError($uid, 'Aggiornamento del collegamento con rclone non riuscito: ' . $e->getMessage());
			return false;
		}
		if ($rotate) {
			$this->removeBridgeFile($uid);
			$this->set($uid, 'dav_pass', $pass, true);
			$this->invalidateMounts($uid);
		}
		return true;
	}

	/**
	 * Salva la scelta per i documenti Google e, se collegato, la applica subito.
	 *
	 * @return bool false se è salvata ma verrà applicata solo al prossimo collegamento
	 */
	public function setGdocsMode(string $uid, string $mode): bool {
		if (!in_array($mode, self::GDOCS_MODES, true)) {
			throw new \InvalidArgumentException('Scelta non valida.');
		}
		$this->set($uid, 'gdocs', $mode);
		if (!$this->isConnected($uid)) {
			return true;
		}
		$result = $this->fetchToken($uid);
		return $result !== null && $result[0] === 200 && $this->refreshBridgeFile($uid, $result[1], true);
	}

	/* ---------- Flusso OAuth ---------- */

	public function buildAuthUrl(string $uid): string {
		if (!$this->hasClientCredentials($uid)) {
			throw new \RuntimeException('Inserisci prima Client ID e Client secret.');
		}
		$state = $this->random->generate(32, ISecureRandom::CHAR_ALPHANUMERIC);
		$this->set($uid, 'oauth_state', $state);

		return self::AUTH_URL . '?' . http_build_query([
			'client_id' => $this->getClientId($uid),
			'redirect_uri' => $this->getRedirectUri(),
			'response_type' => 'code',
			'scope' => self::SCOPE,
			'access_type' => 'offline',
			'prompt' => 'consent',
			'state' => $state,
		]);
	}

	public function handleCallback(string $uid, string $code, string $state): void {
		$expected = $this->get($uid, 'oauth_state');
		$this->del($uid, 'oauth_state');
		if ($expected === '' || !hash_equals($expected, $state)) {
			throw new \RuntimeException('Richiesta di autorizzazione non valida o scaduta: riprova.');
		}
		if ($code === '') {
			throw new \RuntimeException('Google non ha restituito il codice di autorizzazione.');
		}

		$clientId = $this->getClientId($uid);
		$clientSecret = $this->get($uid, 'client_secret', true);
		$client = $this->clientService->newClient();

		try {
			$response = $client->post(self::TOKEN_URL, [
				'body' => [
					'code' => $code,
					'client_id' => $clientId,
					'client_secret' => $clientSecret,
					'redirect_uri' => $this->getRedirectUri(),
					'grant_type' => 'authorization_code',
				],
			]);
			$data = json_decode((string)$response->getBody(), true, 512, JSON_THROW_ON_ERROR);
		} catch (\Throwable $e) {
			$this->logger->error('Scambio del codice OAuth fallito', ['app' => self::APP, 'exception' => $e]);
			throw new \RuntimeException('Google ha rifiutato lo scambio del codice: controlla Client ID, Client secret e URI di reindirizzamento.');
		}

		$access = (string)($data['access_token'] ?? '');
		$refresh = (string)($data['refresh_token'] ?? '');
		if ($access === '' || $refresh === '') {
			throw new \RuntimeException('Google non ha restituito un refresh token. Rimuovi l\'accesso dell\'app dal tuo account Google e riprova.');
		}
		$expiry = gmdate('Y-m-d\TH:i:s\Z', time() + (int)($data['expires_in'] ?? 3600));

		// Indirizzo dell'account, solo per mostrarlo nelle impostazioni
		$email = '';
		try {
			$about = $client->get(self::ABOUT_URL, ['headers' => ['Authorization' => 'Bearer ' . $access]]);
			$info = json_decode((string)$about->getBody(), true);
			$email = (string)($info['user']['emailAddress'] ?? '');
		} catch (\Throwable $e) {
			$this->logger->info('Lettura account Google non riuscita', ['app' => self::APP, 'exception' => $e]);
		}

		// Nuove credenziali WebDAV verso rclone
		$this->removeBridgeFile($uid);
		$davUser = 'u' . $this->random->generate(15, ISecureRandom::CHAR_ALPHANUMERIC);
		$davPass = $this->random->generate(48, ISecureRandom::CHAR_ALPHANUMERIC);
		$this->writeBridgeFile($uid, $davUser, $davPass, $clientId, $clientSecret, $access, $refresh, $expiry);

		$this->set($uid, 'refresh_token', $refresh, true);
		$this->set($uid, 'google_email', $email);
		$this->set($uid, 'dav_user', $davUser);
		$this->set($uid, 'dav_pass', $davPass, true);
		$this->addToGroup($uid);
		$this->invalidateMounts($uid);
	}

	public function disconnect(string $uid): void {
		$refresh = $this->get($uid, 'refresh_token', true);
		if ($refresh !== '') {
			try {
				$this->clientService->newClient()->post(self::REVOKE_URL, ['body' => ['token' => $refresh]]);
			} catch (\Throwable $e) {
				$this->logger->info('Revoca del token Google non riuscita', ['app' => self::APP, 'exception' => $e]);
			}
		}
		$this->removeBridgeFile($uid);
		$this->removeMountConfig($uid);
		$this->removeFromGroup($uid);
		$this->del($uid, 'refresh_token', 'google_email', 'dav_user', 'dav_pass', 'oauth_state');
		$this->invalidateMounts($uid);
	}

	/**
	 * Avvisa Nextcloud che i montaggi dell'utente sono cambiati, così la
	 * cartella compare/sparisce subito anche nelle sottocartelle in cache.
	 */
	private function invalidateMounts(string $uid): void {
		$user = $this->userManager->get($uid);
		if ($user !== null) {
			$this->dispatcher->dispatchTyped(new InvalidateMountCacheEvent($user));
		}
	}

	/* ---------- File di collegamento per rclone ---------- */

	private function bridgeFile(string $davUser, string $davPass): string {
		return $this->getBridgeDir() . '/' . hash('sha256', $davUser . ':' . $davPass) . '.json';
	}

	private function writeBridgeFile(string $uid, string $davUser, string $davPass, string $clientId, string $clientSecret,
		string $access, string $refresh, string $expiry): void {
		if (!$this->isBridgeDirWritable()) {
			throw new \RuntimeException(sprintf(
				'La cartella %s non esiste o non è scrivibile da Nextcloud: controlla il volume condiviso con rclone.',
				$this->getBridgeDir()
			));
		}

		$token = json_encode([
			'access_token' => $access,
			'token_type' => 'Bearer',
			'refresh_token' => $refresh,
			'expiry' => $expiry,
		], JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);

		$config = [
			'type' => 'drive',
			'_root' => '',
			'client_id' => $clientId,
			'client_secret' => $clientSecret,
			'scope' => 'drive',
			'token' => $token,
		];
		// rclone vuole solo stringhe nella risposta dell'auth-proxy
		switch ($this->getGdocsMode($uid)) {
			case 'link':
				$config['export_formats'] = 'link.html';
				break;
			case 'skip':
				$config['skip_gdocs'] = 'true';
				break;
		}
		$remote = json_encode($config, JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);

		$this->writeFile($this->bridgeFile($davUser, $davPass), $remote);

		// Stessa configurazione in formato rclone.conf, per la modalità mount
		unset($config['_root']);
		$ini = "[gdrive]\n";
		foreach ($config as $key => $value) {
			$ini .= $key . ' = ' . str_replace(["\r", "\n"], '', $value) . "\n";
		}
		$this->writeFile($this->mountConfigFile($uid), $ini);
	}

	private function writeFile(string $path, string $content): void {
		$tmp = $path . '.tmp';
		if (file_put_contents($tmp, $content) === false) {
			throw new \RuntimeException('Impossibile scrivere il file di collegamento per rclone.');
		}
		chmod($tmp, 0600);
		rename($tmp, $path);
	}

	/** Configurazione rclone dell'utente per la modalità mount: <cartella>/<uid>.conf */
	private function mountConfigFile(string $uid): string {
		return $this->getBridgeDir() . '/' . $uid . '.conf';
	}

	/** Errori di rclone mount dell'utente, scritti dal container rclone */
	private function mountErrorsFile(string $uid): string {
		return $this->getBridgeDir() . '/' . $uid . '.errors';
	}

	private function removeMountConfig(string $uid): void {
		foreach ([$this->mountConfigFile($uid), $this->mountErrorsFile($uid)] as $path) {
			if (is_file($path)) {
				@unlink($path);
			}
		}
	}

	/* ---------- Gruppo «Google Drive» (modalità mount) ---------- */

	private function addToGroup(string $uid): void {
		$user = $this->userManager->get($uid);
		if ($user === null) {
			return;
		}
		$group = $this->groupManager->get(self::GROUP_ID) ?? $this->groupManager->createGroup(self::GROUP_ID);
		if ($group !== null && !$group->inGroup($user)) {
			$group->addUser($user);
		}
	}

	private function removeFromGroup(string $uid): void {
		$user = $this->userManager->get($uid);
		$group = $this->groupManager->get(self::GROUP_ID);
		if ($user !== null && $group !== null && $group->inGroup($user)) {
			$group->removeUser($user);
		}
	}

	/**
	 * Riallinea un utente già collegato: file per rclone (entrambi i formati) e
	 * gruppo. Usato da install.sh, per esempio passando da una modalità all'altra.
	 */
	public function syncUser(string $uid): bool {
		if (!$this->isConnected($uid)) {
			return false;
		}
		$result = $this->fetchToken($uid);
		// Se Google non dà un access token, rclone lo chiederà da solo con il refresh token
		$token = ($result !== null && $result[0] === 200) ? $result[1] : ['access_token' => 'scaduto', 'expires_in' => -3600];
		$ok = $this->refreshBridgeFile($uid, $token);
		$this->addToGroup($uid);
		return $ok;
	}

	private function removeBridgeFile(string $uid): void {
		$user = $this->get($uid, 'dav_user');
		$pass = $this->get($uid, 'dav_pass', true);
		if ($user === '' || $pass === '') {
			return;
		}
		$path = $this->bridgeFile($user, $pass);
		if (is_file($path)) {
			@unlink($path);
		}
	}

	/* ---------- Registro errori (mostrato nelle impostazioni) ---------- */

	public function logError(string $uid, string $message, string $path = ''): void {
		if ($uid === '') {
			return;
		}
		$message = mb_substr(trim($message), 0, 500);
		$errors = $this->getErrors($uid);
		$now = time();
		$last = $errors[0] ?? null;
		if ($last !== null && $last['message'] === $message && $last['path'] === $path) {
			// Stesso errore ripetuto (es. editor che riprova): una riga sola con il conteggio
			$errors[0]['time'] = $now;
			$errors[0]['count']++;
		} else {
			array_unshift($errors, ['time' => $now, 'message' => $message, 'path' => $path, 'count' => 1]);
			$errors = array_slice($errors, 0, self::MAX_ERRORS);
		}
		$this->set($uid, 'errors', json_encode($errors));
	}

	/** @return list<array{time: int, message: string, path: string, count: int}> */
	public function getErrors(string $uid): array {
		$data = json_decode($this->get($uid, 'errors'), true);
		$errors = is_array($data) ? array_values($data) : [];
		$errors = array_merge($errors, $this->getMountErrors($uid));
		usort($errors, fn (array $a, array $b) => $b['time'] <=> $a['time']);
		return array_slice($errors, 0, self::MAX_ERRORS);
	}

	/**
	 * Errori di rclone mount (modalità mount): righe del log di rclone copiate
	 * dal container nel file <uid>.errors, es. "2026/10/02 22:15:27 ERROR : a.txt: messaggio".
	 */
	private function getMountErrors(string $uid): array {
		$file = $this->mountErrorsFile($uid);
		if (!is_file($file)) {
			return [];
		}
		$errors = [];
		foreach (file($file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [] as $line) {
			if (!preg_match('#^(\d{4}/\d\d/\d\d \d\d:\d\d:\d\d) (?:ERROR|CRITICAL) ?: (.*)$#', $line, $m)) {
				continue;
			}
			$path = '';
			$message = $m[2];
			if (preg_match('#^(.+?): (.+)$#', $message, $p) && !str_contains($p[1], ' ')) {
				[$path, $message] = [$p[1], $p[2]];
			}
			$time = \DateTime::createFromFormat('Y/m/d H:i:s', $m[1], new \DateTimeZone('UTC'));
			$time = $time !== false ? $time->getTimestamp() : 0;
			// Lo stesso errore ripetuto (es. mount ritentato) diventa una riga sola
			$key = $path . "\0" . $message;
			if (isset($errors[$key])) {
				$errors[$key]['count']++;
				$errors[$key]['time'] = max($errors[$key]['time'], $time);
				continue;
			}
			$errors[$key] = [
				'time' => $time,
				'message' => $this->describeText($message),
				'path' => $path,
				'count' => 1,
			];
		}
		return array_values($errors);
	}

	public function clearErrors(string $uid): void {
		$this->del($uid, 'errors');
		if (is_file($this->mountErrorsFile($uid))) {
			@unlink($this->mountErrorsFile($uid));
		}
	}

	/** Spiega in italiano gli errori più comuni della cartella Google Drive */
	public function describeError(\Throwable $e): string {
		$described = $this->describeText($e->getMessage());
		if ($described !== $e->getMessage()) {
			return $described;
		}
		$class = substr(strrchr('\\' . get_class($e), '\\'), 1);
		return $class . ': ' . mb_substr($e->getMessage(), 0, 300);
	}

	/** Aggiunge una spiegazione in italiano ai messaggi di errore noti */
	private function describeText(string $text): string {
		$hints = [
			'invalid_grant' => 'Google ha rifiutato l\'accesso: token scaduto o revocato. Ricollega Google Drive.',
			'storageQuotaExceeded' => 'Spazio su Google Drive esaurito.',
			'rateLimitExceeded' => 'Troppe richieste a Google: riprova tra qualche minuto.',
			'userRateLimitExceeded' => 'Troppe richieste a Google: riprova tra qualche minuto.',
			'violates local access' => 'Nextcloud ha bloccato la connessione verso rclone (indirizzo interno): aggiorna l\'app.',
			'401' => 'rclone ha rifiutato le credenziali: apri le impostazioni o ricollega Google Drive.',
			'Unauthorized' => 'rclone ha rifiutato le credenziali: apri le impostazioni o ricollega Google Drive.',
			'cURL error 28' => 'Tempo scaduto: Google o rclone non hanno risposto in tempo.',
			'timed out' => 'Tempo scaduto: Google o rclone non hanno risposto in tempo.',
			'cURL error 6' => 'rclone non raggiungibile: il container gdrive-rclone è attivo?',
			'Could not resolve host' => 'rclone non raggiungibile: il container gdrive-rclone è attivo?',
			'Failed to connect' => 'rclone non raggiungibile: il container gdrive-rclone è attivo?',
			'cURL error 7' => 'rclone non raggiungibile: il container gdrive-rclone è attivo?',
			'Connection refused' => 'rclone non raggiungibile: il container gdrive-rclone è attivo?',
		];
		foreach ($hints as $needle => $hint) {
			if (stripos($text, (string)$needle) !== false) {
				return $hint . ' (' . mb_substr($text, 0, 200) . ')';
			}
		}
		return mb_substr($text, 0, 300);
	}

	/* ---------- Messaggi per la pagina impostazioni ---------- */

	public function setFlash(string $uid, string $type, string $text): void {
		$this->set($uid, 'flash', json_encode(['type' => $type, 'text' => $text]));
	}

	public function popFlash(string $uid): ?array {
		$raw = $this->get($uid, 'flash');
		if ($raw === '') {
			return null;
		}
		$this->del($uid, 'flash');
		$data = json_decode($raw, true);
		return is_array($data) ? $data : null;
	}
}
