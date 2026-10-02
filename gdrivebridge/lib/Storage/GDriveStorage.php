<?php

declare(strict_types=1);

namespace OCA\GDriveBridge\Storage;

use OC\Files\Storage\DAV;
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
 */
class GDriveStorage extends DAV {
	private function requestOptions(array $options): array {
		$options['auth'] = [$this->user, $this->password];
		$options['verify'] = $this->verify;
		$options['timeout'] = Server::get(IConfig::class)->getSystemValueInt('davstorage.request_timeout', 30);
		$options['nextcloud'] = ['allow_local_address' => true];
		return $options;
	}

	public function fopen($path, $mode) {
		if ($mode !== 'r' && $mode !== 'rb') {
			// La scrittura passa da un file temporaneo e poi da uploadFile()
			return parent::fopen($path, $mode);
		}

		$this->init();
		$path = $this->cleanPath($path);
		try {
			$response = $this->httpClientService->newClient()->get(
				$this->createBaseUri() . $this->encodePath($path),
				$this->requestOptions(['stream' => true])
			);
		} catch (\GuzzleHttp\Exception\ClientException $e) {
			if ($e->getResponse()->getStatusCode() === 404) {
				return false;
			}
			throw $e;
		}

		$content = $response->getBody();
		if ($content === null || is_string($content)) {
			return false;
		}
		return $content;
	}

	protected function uploadFile($path, $target): void {
		$this->init();
		$target = $this->cleanPath($target);
		$this->statCache->remove($target);

		$source = fopen($path, 'r');
		$this->httpClientService->newClient()->put(
			$this->createBaseUri() . $this->encodePath($target),
			$this->requestOptions(['body' => $source])
		);

		$this->removeCachedFile($target);
	}
}
