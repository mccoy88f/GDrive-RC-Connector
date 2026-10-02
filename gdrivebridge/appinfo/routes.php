<?php

declare(strict_types=1);

return [
	'routes' => [
		['name' => 'oauth#saveCredentials', 'url' => '/credentials', 'verb' => 'POST'],
		['name' => 'oauth#start', 'url' => '/oauth/start', 'verb' => 'GET'],
		['name' => 'oauth#callback', 'url' => '/oauth/callback', 'verb' => 'GET'],
		['name' => 'oauth#disconnect', 'url' => '/disconnect', 'verb' => 'POST'],
	],
];
