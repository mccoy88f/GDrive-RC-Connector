<?php
/** @var array $_ */
/** @var \OCP\IL10N $l */
?>
<div id="gdrivebridge" class="section">
	<h2>Google Drive</h2>
	<p class="settings-hint">
		<?php p($l->t('Connect your Google Drive: it will appear in Files as the folder “%s”.', [$_['mountName']])); ?>
		<?php p($l->t('You use the OAuth credentials of your own Google project: nobody else has access to your Drive.')); ?>
	</p>

	<?php if (!empty($_['flash'])): ?>
		<p class="gdb-msg <?php p(($_['flash']['type'] ?? '') === 'error' ? 'gdb-error' : 'gdb-ok'); ?>">
			<?php p($_['flash']['text'] ?? ''); ?>
		</p>
	<?php endif; ?>

	<?php if (!$_['bridgeOk']): ?>
		<p class="gdb-msg gdb-error">
			<?php p($l->t('The link folder %s is not accessible from the server: the volume shared with the rclone container must be mounted (see README).', [$_['bridgeDir']])); ?>
		</p>
	<?php endif; ?>

	<?php if ($_['connected']): ?>
		<div class="gdb-box">
			<?php if ($_['tokenStatus'] === 'expired'): ?>
				<p class="gdb-msg gdb-error">
					<strong><?php p($l->t('Google access expired or revoked')); ?></strong><?php if ($_['email'] !== ''): ?> (<?php p($l->t('account %s', [$_['email']])); ?>)<?php endif; ?>.
					<?php p($l->t('The folder “%s” will not work until you reconnect. If this happens every 7 days, your app on Google Cloud is still in “Testing”: publish it (see the guide below).', [$_['mountName']])); ?>
				</p>
				<p><a class="button primary" href="<?php p($_['startUrl']); ?>"><?php p($l->t('Reconnect Google Drive')); ?></a></p>
			<?php elseif ($_['tokenStatus'] === 'client'): ?>
				<p class="gdb-msg gdb-error">
					<strong><?php p($l->t('Google no longer accepts the Client ID or Client secret')); ?></strong>
					<?php p($l->t('(client deleted or secret regenerated?): update the credentials below and reconnect.')); ?>
				</p>
			<?php else: ?>
				<p>
					<?php if ($_['email'] !== ''): ?>
						<strong><?php p($l->t('Connected')); ?></strong> <?php p($l->t('to the account %s.', [$_['email']])); ?>
					<?php else: ?>
						<strong><?php p($l->t('Connected')); ?></strong>.
					<?php endif; ?>
					<?php if ($_['tokenStatus'] === 'unknown'): ?>
						<span class="gdb-hint"><?php p($l->t('(Google access cannot be verified right now)')); ?></span>
					<?php endif; ?>
				</p>
			<?php endif; ?>
			<form method="post" action="<?php p($_['disconnectUrl']); ?>">
				<input type="hidden" name="requesttoken" value="<?php p($_['requesttoken']); ?>">
				<button type="submit" class="button"><?php p($l->t('Disconnect Google Drive')); ?></button>
			</form>
		</div>
	<?php elseif ($_['hasCredentials']): ?>
		<div class="gdb-box">
			<p><?php p($l->t('Credentials saved. Now authorize access to your Drive.')); ?></p>
			<a class="button primary" href="<?php p($_['startUrl']); ?>"><?php p($l->t('Connect Google Drive')); ?></a>
		</div>
	<?php endif; ?>

	<h3><?php p($l->t('Google Docs, Sheets and Slides')); ?></h3>
	<p class="settings-hint">
		<?php p($l->t('Documents created with Google Docs, Sheets and Slides are not real files: they only exist on Google. To show them as .docx/.xlsx/.pptx they would have to be converted, but Google does not tell how big the conversion is until it has been fully downloaded, so in Nextcloud they would appear empty. Regular files uploaded to Drive (PDF, Word, Excel, photos…) do not have this problem.')); ?>
	</p>
	<form method="post" action="<?php p($_['gdocsUrl']); ?>" class="gdb-form">
		<input type="hidden" name="requesttoken" value="<?php p($_['requesttoken']); ?>">
		<label class="gdb-radio">
			<input type="radio" name="gdocs" value="link"<?php if ($_['gdocsMode'] === 'link'): ?> checked<?php endif; ?>>
			<span><strong><?php p($l->t('Show them as links')); ?></strong> (<code><?php p($l->t('Name')); ?>.link.html</code>):
				<?php p($l->t('downloading or opening them in the browser opens the document on Google, where you can edit it.')); ?></span>
		</label>
		<label class="gdb-radio">
			<input type="radio" name="gdocs" value="skip"<?php if ($_['gdocsMode'] === 'skip'): ?> checked<?php endif; ?>>
			<span><strong><?php p($l->t('Hide them')); ?></strong>:
				<?php p($l->t('only regular files appear in the folder. The documents stay on Google Drive and are not deleted.')); ?></span>
		</label>
		<div><button type="submit" class="button"><?php p($l->t('Save choice')); ?></button></div>
	</form>

	<h3><?php p($l->t('Error log')); ?></h3>
	<?php if (empty($_['errors'])): ?>
		<p class="settings-hint"><?php p($l->t('No errors recorded.')); ?></p>
	<?php else: ?>
		<p class="settings-hint">
			<?php p($l->t('The latest problems of the folder “%s”, most recent first. If an error repeats, the number in brackets says how many times.', [$_['mountName']])); ?>
		</p>
		<table class="gdb-errors">
			<thead><tr><th><?php p($l->t('When')); ?></th><th><?php p($l->t('File')); ?></th><th><?php p($l->t('Error')); ?></th></tr></thead>
			<tbody>
			<?php foreach ($_['errors'] as $e): ?>
				<tr>
					<td class="gdb-nowrap"><?php p($e['when']); ?><?php if ($e['count'] > 1): ?> (<?php p($e['count']); ?>×)<?php endif; ?></td>
					<td><?php p($e['path'] !== '' ? $e['path'] : '—'); ?></td>
					<td><?php p($e['message']); ?></td>
				</tr>
			<?php endforeach; ?>
			</tbody>
		</table>
		<form method="post" action="<?php p($_['clearErrorsUrl']); ?>">
			<input type="hidden" name="requesttoken" value="<?php p($_['requesttoken']); ?>">
			<button type="submit" class="button"><?php p($l->t('Clear log')); ?></button>
		</form>
	<?php endif; ?>

	<h3><?php p($l->t('OAuth credentials of your Google project')); ?></h3>
	<form method="post" action="<?php p($_['saveUrl']); ?>" class="gdb-form">
		<input type="hidden" name="requesttoken" value="<?php p($_['requesttoken']); ?>">

		<label for="gdb-client-id">Client ID</label>
		<input id="gdb-client-id" name="client_id" type="text" autocomplete="off" required
			value="<?php p($_['clientId']); ?>">

		<label for="gdb-client-secret">Client secret</label>
		<input id="gdb-client-secret" name="client_secret" type="password" autocomplete="new-password"
			placeholder="<?php p($_['hasSecret'] ? $l->t('•••••••• saved (leave empty to keep it)') : ''); ?>">

		<div><button type="submit" class="button"><?php p($l->t('Save credentials')); ?></button></div>
	</form>

	<details class="gdb-guide"<?php if (!$_['hasCredentials']): ?> open<?php endif; ?>>
		<summary><?php p($l->t('How to create the credentials on Google Cloud')); ?></summary>
		<ol>
			<li><?php print_unescaped($l->t('Go to %s and create a new project.', ['<a href="https://console.cloud.google.com/" target="_blank" rel="noopener noreferrer">console.cloud.google.com</a>'])); ?></li>
			<li><?php print_unescaped($l->t('In <em>APIs &amp; Services → Library</em> search for <strong>Google Drive API</strong> and enable it.')); ?></li>
			<li><?php print_unescaped($l->t('Configure the <strong>OAuth consent screen</strong>: type <em>External</em>, any app name, your email.')); ?></li>
			<li><?php print_unescaped($l->t('<strong>Important:</strong> in the <em>Audience</em> section press <em>Publish app</em> (status “In production”). If it stays in “Testing”, Google expires the access every 7 days.')); ?></li>
			<li><?php print_unescaped($l->t('In <em>Clients</em> create a new <strong>OAuth client ID</strong> of type <em>Web application</em> and, under <em>Authorized redirect URIs</em>, enter exactly this address:')); ?>
				<input class="gdb-redirect" type="text" readonly value="<?php p($_['redirectUri']); ?>">
			</li>
			<li><?php print_unescaped($l->t('Copy the <em>Client ID</em> and <em>Client secret</em> into the form above, save and press <em>Connect Google Drive</em>.')); ?></li>
			<li><?php print_unescaped($l->t('Google will warn you that the app is not verified: that is expected, it is your own app. Press <em>Advanced</em> → <em>Go to … (unsafe)</em> and allow access.')); ?></li>
		</ol>
	</details>
</div>
