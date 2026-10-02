<?php
/** @var array $_ */
?>
<div id="gdrivebridge" class="section">
	<h2>Google Drive</h2>
	<p class="settings-hint">
		Collega il tuo Google Drive: comparirà nei File come cartella «<?php p($_['mountName']); ?>».
		Usi le credenziali OAuth del tuo progetto Google, nessun altro ha accesso al tuo Drive.
	</p>

	<?php if (!empty($_['flash'])): ?>
		<p class="gdb-msg <?php p(($_['flash']['type'] ?? '') === 'error' ? 'gdb-error' : 'gdb-ok'); ?>">
			<?php p($_['flash']['text'] ?? ''); ?>
		</p>
	<?php endif; ?>

	<?php if (!$_['bridgeOk']): ?>
		<p class="gdb-msg gdb-error">
			La cartella di collegamento <code><?php p($_['bridgeDir']); ?></code> non è accessibile dal server.
			Va montato il volume condiviso con il container rclone (vedi README).
		</p>
	<?php endif; ?>

	<?php if ($_['connected']): ?>
		<div class="gdb-box">
			<?php if ($_['tokenStatus'] === 'expired'): ?>
				<p class="gdb-msg gdb-error">
					<strong>Accesso a Google scaduto o revocato</strong><?php if ($_['email'] !== ''): ?> per l'account <?php p($_['email']); ?><?php endif; ?>:
					la cartella «<?php p($_['mountName']); ?>» non funziona finché non ricolleghi.
					Se succede ogni 7 giorni, l'app su Google Cloud è ancora in "Test": pubblicala (vedi guida sotto).
				</p>
				<p><a class="button primary" href="<?php p($_['startUrl']); ?>">Ricollega Google Drive</a></p>
			<?php elseif ($_['tokenStatus'] === 'client'): ?>
				<p class="gdb-msg gdb-error">
					<strong>Google non accetta più Client ID o Client secret</strong> (client eliminato o secret rigenerato?):
					aggiorna le credenziali qui sotto e ricollega.
				</p>
			<?php else: ?>
				<p>
					<strong>Collegato</strong><?php if ($_['email'] !== ''): ?> all'account <?php p($_['email']); ?><?php endif; ?>.
					<?php if ($_['tokenStatus'] === 'unknown'): ?>
						<span class="gdb-hint">(al momento non è possibile verificare l'accesso con Google)</span>
					<?php endif; ?>
				</p>
			<?php endif; ?>
			<form method="post" action="<?php p($_['disconnectUrl']); ?>">
				<input type="hidden" name="requesttoken" value="<?php p($_['requesttoken']); ?>">
				<button type="submit" class="button">Scollega Google Drive</button>
			</form>
		</div>
	<?php elseif ($_['hasCredentials']): ?>
		<div class="gdb-box">
			<p>Credenziali salvate. Ora autorizza l'accesso al tuo Drive.</p>
			<a class="button primary" href="<?php p($_['startUrl']); ?>">Collega Google Drive</a>
		</div>
	<?php endif; ?>

	<h3>Documenti, Fogli e Presentazioni Google</h3>
	<p class="settings-hint">
		I documenti creati con Google Docs, Fogli e Presentazioni non sono file veri e propri: esistono solo su Google.
		Per mostrarli come <code>.docx</code>/<code>.xlsx</code>/<code>.pptx</code> andrebbero convertiti, ma Google non
		dice quanto pesa la conversione finché non la si scarica tutta, quindi in Nextcloud risulterebbero vuoti.
		I file normali caricati su Drive (PDF, Word, Excel, foto…) non hanno questo problema.
	</p>
	<form method="post" action="<?php p($_['gdocsUrl']); ?>" class="gdb-form">
		<input type="hidden" name="requesttoken" value="<?php p($_['requesttoken']); ?>">
		<label class="gdb-radio">
			<input type="radio" name="gdocs" value="link"<?php if ($_['gdocsMode'] === 'link'): ?> checked<?php endif; ?>>
			<span><strong>Mostrali come collegamenti</strong> (<code>Nome.link.html</code>): scaricandoli o aprendoli
				nel browser si apre il documento su Google, dove puoi modificarlo.</span>
		</label>
		<label class="gdb-radio">
			<input type="radio" name="gdocs" value="skip"<?php if ($_['gdocsMode'] === 'skip'): ?> checked<?php endif; ?>>
			<span><strong>Nascondili</strong>: nella cartella compaiono solo i file normali.
				I documenti restano su Google Drive, non vengono cancellati.</span>
		</label>
		<div><button type="submit" class="button">Salva scelta</button></div>
	</form>

	<h3>Registro errori</h3>
	<?php if (empty($_['errors'])): ?>
		<p class="settings-hint">Nessun errore registrato.</p>
	<?php else: ?>
		<p class="settings-hint">
			Gli ultimi problemi della cartella «<?php p($_['mountName']); ?>», dal più recente.
			Se un errore si ripete, il numero tra parentesi indica quante volte.
		</p>
		<table class="gdb-errors">
			<thead><tr><th>Quando</th><th>File</th><th>Errore</th></tr></thead>
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
			<button type="submit" class="button">Svuota registro</button>
		</form>
	<?php endif; ?>

	<h3>Credenziali OAuth del tuo progetto Google</h3>
	<form method="post" action="<?php p($_['saveUrl']); ?>" class="gdb-form">
		<input type="hidden" name="requesttoken" value="<?php p($_['requesttoken']); ?>">

		<label for="gdb-client-id">Client ID</label>
		<input id="gdb-client-id" name="client_id" type="text" autocomplete="off" required
			value="<?php p($_['clientId']); ?>">

		<label for="gdb-client-secret">Client secret</label>
		<input id="gdb-client-secret" name="client_secret" type="password" autocomplete="new-password"
			placeholder="<?php p($_['hasSecret'] ? '•••••••• salvato (lascia vuoto per non cambiarlo)' : ''); ?>">

		<div><button type="submit" class="button">Salva credenziali</button></div>
	</form>

	<details class="gdb-guide"<?php if (!$_['hasCredentials']): ?> open<?php endif; ?>>
		<summary>Come creare le credenziali su Google Cloud</summary>
		<ol>
			<li>Vai su <a href="https://console.cloud.google.com/" target="_blank" rel="noopener noreferrer">console.cloud.google.com</a> e crea un nuovo progetto.</li>
			<li>In <em>API e servizi → Libreria</em> cerca <strong>Google Drive API</strong> e attivala.</li>
			<li>Configura la <strong>schermata di consenso OAuth</strong>: tipo <em>Esterno</em>, nome app a piacere, la tua email.</li>
			<li><strong>Importante:</strong> nella sezione <em>Pubblico</em> premi <em>Pubblica app</em> (stato "In produzione").
				Se resta in "Test", Google fa scadere l'accesso ogni 7 giorni.</li>
			<li>In <em>Client</em> crea un nuovo <strong>ID client OAuth</strong> di tipo <em>Applicazione web</em> e, in
				<em>URI di reindirizzamento autorizzati</em>, inserisci esattamente questo indirizzo:
				<input class="gdb-redirect" type="text" readonly value="<?php p($_['redirectUri']); ?>">
			</li>
			<li>Copia <em>Client ID</em> e <em>Client secret</em> nel modulo qui sopra, salva e premi <em>Collega Google Drive</em>.</li>
			<li>Google ti avviserà che l'app non è verificata: è normale, è la tua app.
				Premi <em>Avanzate</em> → <em>Vai a … (non sicura)</em> e consenti l'accesso.</li>
		</ol>
	</details>
</div>
