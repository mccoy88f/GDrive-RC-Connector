<?php

declare(strict_types=1);

namespace OCA\GDriveBridge\Storage;

use OC\Files\Storage\DAV;
use OCA\GDriveBridge\Service\BridgeService;
use OCP\Files\StorageInvalidException;
use OCP\Files\StorageNotAvailableException;
use OCP\IConfig;
use OCP\Server;

/**
 * Storage WebDAV verso il container rclone.
 *
 * rclone sta sulla rete Docker interna, e il client HTTP di Nextcloud rifiuta
 * gli indirizzi locali ("violates local access rules"): l'elenco dei file
 * funziona (passa da Sabre) ma download e upload no. Qui si consente l'indirizzo
 * locale solo per le richieste di questo storage, invece di attivare
 * allow_local_remote_servers per tutta l'istanza.
 *
 * Download e upload non usano il client HTTP di Nextcloud: è basato su cURL e
 * ignora lo streaming, quindi scaricherebbe l'intero file da Google prima di
 * inviarne il primo byte, e con il limite di 30 secondi fallirebbe con i file
 * grandi. Il download apre invece uno stream HTTP diretto verso rclone, con un
 * limite sull'inattività e non sulla durata totale.
 *
 * Gli errori finiscono anche nel registro mostrato nelle impostazioni dell'utente.
 */
class GDriveStorage extends DAV {
	private string $ownerUid;

	public function __construct($parameters) {
		parent::__construct($parameters);
		$this->ownerUid = (string)($parameters['gdb_uid'] ?? '');
	}

	/** Secondi senza dati dopo i quali un download si considera bloccato */
	private const IDLE_TIMEOUT = 120;

	private function url(string $path): string {
		return $this->createBaseUri() . $this->encodePath($path);
	}

	/** Limite totale per gli upload verso rclone (che li mette in cache e li invia a Google dopo) */
	private function uploadTimeout(): int {
		return (int)Server::get(IConfig::class)->getAppValue('gdrivebridge', 'upload_timeout', '3600');
	}

	private function recordError(\Throwable $e, string $path): void {
		try {
			$bridge = Server::get(BridgeService::class);
			$bridge->logError($this->ownerUid, $bridge->describeError($e), $path);
		} catch (\Throwable) {
			// il registro non deve mai interferire con l'operazione sui file
		}
	}

	public function fopen($path, $mode) {
		if ($mode !== 'r' && $mode !== 'rb') {
			// La scrittura passa da un file temporaneo e poi da uploadFile()
			return parent::fopen($path, $mode);
		}

		$this->init();
		$path = $this->cleanPath($path);
		$context = stream_context_create(['http' => [
			'method' => 'GET',
			'header' => 'Authorization: Basic ' . base64_encode($this->user . ':' . $this->password),
			'timeout' => self::IDLE_TIMEOUT,
			'ignore_errors' => true,
		]]);

		$stream = @fopen($this->url($path), 'rb', false, $context);
		if ($stream === false) {
			$error = error_get_last()['message'] ?? 'connessione non riuscita';
			$e = new StorageNotAvailableException('Download da rclone non riuscito: ' . $error);
			$this->recordError($e, $path);
			throw $e;
		}

		$headers = stream_get_meta_data($stream)['wrapper_data'] ?? [];
		$status = 0;
		foreach ($headers as $header) {
			// Con i redirect ci sono più righe di stato: conta l'ultima
			if (preg_match('#^HTTP/\S+\s+(\d{3})#', (string)$header, $m)) {
				$status = (int)$m[1];
			}
		}
		if ($status === 200) {
			return $stream;
		}
		fclose($stream);
		if ($status === 404) {
			return false;
		}
		$e = new StorageNotAvailableException('rclone ha risposto ' . $status . ' al download');
		$this->recordError($e, $path);
		throw $e;
	}

	protected function uploadFile($path, $target): void {
		$this->init();
		$target = $this->cleanPath($target);
		$this->statCache->remove($target);

		$source = fopen($path, 'r');
		try {
			$this->httpClientService->newClient()->put($this->url($target), [
				'body' => $source,
				'auth' => [$this->user, $this->password],
				'verify' => $this->verify,
				'connect_timeout' => 10,
				'timeout' => $this->uploadTimeout(),
				'nextcloud' => ['allow_local_address' => true],
			]);
		} catch (\Throwable $e) {
			$this->recordError($e, $target);
			throw $e;
		}

		$this->removeCachedFile($target);
	}

	protected function convertException(\Exception $e, $path = ''): void {
		try {
			parent::convertException($e, $path);
		} catch (\Throwable $converted) {
			// Solo gli errori veri (quelli che il DAV ignora non arrivano qui) e una
			// volta sola: un errore già convertito torna qui una seconda volta
			if (!($e instanceof StorageNotAvailableException) && !($e instanceof StorageInvalidException)) {
				$this->recordError($e, (string)$path);
			}
			throw $converted;
		}
	}
}
