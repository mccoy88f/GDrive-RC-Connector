<?php

declare(strict_types=1);

return [
	'routes' => [
		['name' => 'oauth#saveCredentials', 'url' => '/credentials', 'verb' => 'POST'],
		['name' => 'oauth#start', 'url' => '/oauth/start', 'verb' => 'GET'],
		['name' => 'oauth#callback', 'url' => '/oauth/callback', 'verb' => 'GET'],
		['name' => 'oauth#disconnect', 'url' => '/disconnect', 'verb' => 'POST'],
		['name' => 'oauth#saveGdocs', 'url' => '/gdocs', 'verb' => 'POST'],
		['name' => 'oauth#clearErrors', 'url' => '/errors/clear', 'verb' => 'POST'],
	],
];
