# Passbolt Migration Assistant — contratti tecnici correnti

Questa guida descrive esclusivamente i contratti attivi di `0.29.0-beta.1 - Technical beta`. È una beta tecnica non production-ready: il percorso Passbolt v4 resta completo e le risorse v5 sono disponibili soltanto come preview selezionata esplicitamente. La cronologia delle versioni e delle sperimentazioni precedenti è in [CHANGELOG.md](CHANGELOG.md); non va dedotta da questo documento alcuna compatibilità oltre il profilo corrente `passbolt-v4-v5-resource-preview`.

## Avvio e componenti

Avvio dell'interfaccia Windows:

```powershell
.\run_passbolt_app.ps1
```

Componenti principali:

- `PassboltApp.ps1`: interfaccia WPF, coordinamento delle operazioni e presentazione dei risultati;
- `passbolt_app.py`: inventario locale dei documenti;
- `passbolt_review.py`: parsing, revisione mascherata e profili di mappatura;
- `passbolt_project.py`: progetti locali `.pbproj` protetti con DPAPI;
- `passbolt_import.py`: validazione dei piani, sessione persistente e journal di importazione;
- `passbolt_crypto.mjs`: GPGAuth, OpenPGP, letture API, dry-run, scritture v4 e creazione preview di risorse v5 personali;
- `passbolt_acl_reconciliation.py` e `passbolt_reconciliation.py`: journal, lease e recuperi;
- `passbolt_receipt.py`: feedback aggregato e ricevute sanitizzate;
- `passbolt_integration_matrix.py`: matrici reali separate v4 e v5-resource-preview con report sanitizzati;
- `offline_lab_*` e `run_offline_lab.ps1`: laboratorio sintetico vincolato al loopback.

Python, Node e WPF comunicano tramite JSON su standard input/output reindirizzati. Chiavi, passphrase, TOTP, password Excel e segreti delle credenziali non vengono passati negli argomenti dei processi o nelle variabili d'ambiente, non vengono registrati e non devono essere scritti in file temporanei. Gli schemi locali sono chiusi e bounded; proprietà sconosciute, messaggi oltre i limiti e risultati incoerenti vengono rifiutati.

## Identità del candidato e profilo di compatibilità

La sola identità corrente è `0.29.0-beta.1`; UI, user agent, progetti, ricevute, laboratorio, matrice e riepilogo del gate devono dichiarare la stessa versione. Applicazione, ricevute e gate dichiarano il profilo `passbolt-v4-v5-resource-preview`; i report a schema chiuso della matrice lo rappresentano senza ambiguità tramite la coppia esplicita `resource=v4, folder=v4` oppure `resource=v5, folder=v4`.

Il file [`release-candidate.json`](release-candidate.json) è la fonte macchina unica per versione, stato del changelog, profilo e conteggi del quality gate. I componenti standalone mantengono costanti locali perché devono poter essere eseguiti senza dipendere da un file di repository; `run_tests.ps1` compensa questo trade-off verificando automaticamente tutte le copie applicative della versione e confrontando i conteggi del manifesto con le suite e i riepiloghi effettivi. Una centralizzazione runtime più ampia introdurrebbe una nuova dipendenza di distribuzione senza modificare il contratto funzionale e non è giustificata per questo candidato.

Il candidato accetta esclusivamente due combinazioni esplicite: risorse v4 con cartelle v4 oppure risorse v5 con cartelle v4. Nel percorso preview il bridge verifica capability metadata, tipo di risorsa e chiavi metadata personali o condivise prima di promuovere un piano; i cataloghi di risorse e cartelle v5 possono essere letti e decifrati quando la chiave richiesta è disponibile. Le cartelle v5 restano read-only e sono escluse dalle destinazioni, anche quando esistono già. La sola scrittura v5 ammessa è l'importazione di una risorsa personale; una cartella v4 esistente è utilizzabile soltanto se la risposta autenticata prova `personal=true`, permesso effettivo Proprietario e una sola ACL riferita all'utente corrente. `auto`, conversioni fra formati, creazione o riuso di cartelle v5, importazioni v5 condivise e modifiche ACL su oggetti v5 vengono rifiutati fail-closed. Questa preview non costituisce una promessa per le altre capability v5.

## Architettura dell'informazione delle quattro fasi

### 01 — Preparazione locale

L'operatore seleziona la radice dei documenti e, facoltativamente, pianifica l'origine HTTPS. In questa fase non viene attribuita fiducia a un server, non viene aperta una sessione e non vengono letti i valori delle credenziali.

Un progetto `.pbproj` può salvare origine pianificata, radice sorgente, profilo di mappatura, file selezionati e prove tecniche dei candidati. Il payload schema 1 è canonicalizzato, legato a digest, cifrato con DPAPI `CurrentUser` e scritto atomicamente. Non contiene fingerprint fidate, chiavi, passphrase, MFA, cookie, sessioni, password, correzioni, destinazioni remote, ACL, dry-run, ricevute o journal. Il ripristino azzera ogni trust e richiede nuovamente inventario, revisione e verifica remota.

### 02 — Inventario file

L'inventario usa estensione e metadati del filesystem senza aprire i documenti. La classificazione non valida il contenuto e non garantisce che un file produca candidati.

<!-- source-format-contract:inventory:start -->
**Estensioni rilevate dall'inventario (16):** `.txt`, `.csv`, `.tsv`, `.json`, `.xml`, `.yaml`, `.yml`, `.ini`, `.cfg`, `.conf`, `.env`, `.properties`, `.docx`, `.xlsx`, `.xls`, `.pdf`.
<!-- source-format-contract:inventory:end -->

<!-- source-format-contract:conversion-only:start -->
**Rilevata ma da convertire prima della revisione:** `.xls`.
<!-- source-format-contract:conversion-only:end -->

Le altre 15 estensioni vengono aperte soltanto nella revisione locale, con parser e limiti specifici. `.pdf` resta soggetto al limite di pagine e all'estrazione testuale; `.docx` e `.xlsx` devono essere contenitori validi. I file legacy `.xls` sono inventariati per produrre un feedback di conversione controllato, ma non vengono analizzati e devono essere convertiti, per esempio in `.xlsx`, prima della revisione. ODT non appartiene al contratto sorgente corrente. File temporanei Office, link simbolici o reparse point, estensioni non ammesse e file fuori radice vengono esclusi.

Il riepilogo **Esclusioni e conversioni** contiene soltanto contatori, codici e bucket di formato bounded. Nomi di file, clienti e percorsi non entrano nel feedback aggregato.

### 03 — Revisione controllata

I documenti selezionati vengono aperti localmente e normalizzati nei cinque campi importabili: client, titolo, username, password e URL/host. Le password restano mascherate per impostazione predefinita; la visualizzazione richiede un'azione esplicita e le copie lette dai sorgenti vengono rimosse dalla UI quando si ripristina la maschera o si cambia fase.

I profili di mappatura contengono esclusivamente alias di campo normalizzati. Alias duplicati, sovrapposti o ambigui bloccano la revisione; password e valori sorgente non sono serializzati. Profilo e digest accompagnano i candidati e vengono ricontrollati durante rilettura e pianificazione.

Un `.xlsx` cifrato viene decifrato soltanto in memoria dopo richiesta interattiva della password. Non viene creata una copia in chiaro. Come dichiarato dal contratto d'inventario, i file legacy `.xls` sono soltanto rilevati e richiedono conversione prima della revisione.

### 04 — Operazioni Passbolt v4 e risorse v5 preview

La verifica remota è confinata alla fase 04. **Nuova importazione** e **Recupero import interrotto** condividono lo spazio di migrazione; **Gestisci ACL esistenti** è separato e non eredita implicitamente destinazione o piano dell'importazione.

L'ordine operativo resta obbligatorio:

1. inserire o confermare l'origine HTTPS;
2. eseguire la verifica pubblica e confrontare la fingerprint OpenPGP tramite un canale indipendente;
3. confermare la fingerprint per la sola sessione corrente;
4. aprire GPGAuth e completare MFA TOTP quando richiesto;
5. scegliere esplicitamente il formato risorsa v4 o v5 preview, quindi destinazione e permessi;
6. eseguire preflight e dry-run autenticato;
7. verificare piano, conteggi e digest;
8. digitare la conferma esatta richiesta;
9. scrivere, rileggere il risultato remoto e chiudere il journal soltanto dopo la verifica.

Inventario e revisione rimangono disponibili senza connessione. URL, fingerprint, chiave privata, passphrase e TOTP compaiono soltanto nello spazio remoto in cui servono.

## Coordinatore operativo, lock e cleanup

WPF usa un unico stato operativo centralizzato. Una sola operazione può essere attiva; navigazione, selezioni e azioni incompatibili vengono bloccate dallo stesso lock. Un secondo avvio concorrente viene rifiutato prima di creare worker o modificare lo stato.

Le operazioni lunghe usano worker asincroni; gli eventi di progresso vengono accodati FIFO sul dispatcher. Non è presente un pump manuale `DoEvents`. Completamento, errore, timeout e chiusura rilasciano il lock, smaltiscono worker e handle, chiudono o ripuliscono la sessione quando necessario e riabilitano l'interfaccia in uno stato coerente. Un errore di trasporto durante una scrittura non viene reinterpretato dal cleanup come prova che la mutazione non sia avvenuta.

Il self-test WPF verifica esplicitamente stato unico, anti-reentrancy, lock centralizzato, ordine dei progressi, ciclo di vita asincrono, assenza del pump manuale, feedback/ricevute sanitizzate e mancata serializzazione dei segreti.

## Connessione, GPGAuth e MFA

La verifica pubblica richiede HTTPS, healthcheck valido, risposta JSON coerente e fingerprint OpenPGP normalizzata. La fingerprint mostrata dallo stesso endpoint non è una prova autonoma: deve essere confrontata con un valore comunicato tramite un canale indipendente. La conferma resta soltanto in memoria e viene invalidata se origine o fingerprint cambiano.

GPGAuth verifica crittograficamente la firma della sfida con la chiave server fissata. Il primo tentativo usa l'ora locale. Soltanto se OpenPGP segnala che la firma è futura, il bridge può ripetere la verifica usando l'header HTTP `Date` della medesima risposta HTTPS, purché sia un IMF-fixdate valido e lo scarto assoluto non superi 300 secondi. Firma matematica, identità del firmatario, validità della chiave e policy degli hash restano obbligatorie; header assenti o malformati, scarti maggiori e firmatari differenti restano bloccanti.

La verifica TOTP usa il payload corrente con il solo campo `totp`. Provider MFA diversi da TOTP vengono riconosciuti ma bloccano il flusso senza scritture. La diagnostica espone soltanto codice e fase enumerati, stato HTTP sicuro ed eventuale scarto temporale bounded; non include endpoint privati, URL, cookie, token, chiavi, passphrase o codici MFA.

## Dry-run e importazione v4/v5-resource-preview

Il dry-run è autenticato e non scrive. Rilegge identità, CSRF, impostazioni, tipi di risorsa, cartelle, maschere, directory di utenti e gruppi e risorse accessibili. Per una risorsa v5 legge inoltre impostazioni e copie private delle chiavi metadata e verifica la disponibilità della chiave richiesta dal piano. Lo snapshot di capability usato dalla decisione è validato con tipi JSON stretti e legato al digest del piano; cataloghi duplicati, valori testuali come `"false"`, drift successivo, capability incomplete, formati impliciti, cartelle v5, destinazioni personali non attestate e piani v5 che richiedono condivisione o altre mutazioni ACL bloccano il percorso. La UI accetta il risultato soltanto se dichiara assenza di scritture e tutti i controlli obbligatori sono `passed` o `not_required`.

Il piano lega tramite digest:

- identità e sessione verificate;
- origine e fingerprint confermata;
- prove tecniche dei sorgenti e profilo di mappatura;
- candidati selezionati e loro destinazioni;
- formato risorsa esplicito v4 o v5, tipo di risorsa e, per v5, identità/tipo della chiave metadata verificata;
- cartelle da riusare o creare;
- ACL desiderata e directory verificata;
- duplicati e conflitti rilevati.

Subito prima della scrittura vengono ricontrollati sessione, identità, sorgenti, capability e digest. Le nuove cartelle sono sempre v4 e vengono create prima delle risorse; l'eventuale condivisione v4 deve essere simulata e applicata con successo prima che la cartella sia usata come destinazione. Le password vengono estratte dai sorgenti soltanto al passaggio necessario oppure restano in memoria se corrette nella fase 03. Node cifra e firma localmente il segreto per il proprietario e per gli eventuali destinatari concreti verificati. Per una risorsa v5 personale cifra inoltre i metadata localmente con la chiave attestata e li rilegge dopo la creazione; i sink ripetono il vincolo sulla destinazione personale e rifiutano direttamente qualunque simulazione o scrittura ACL v5.

Le creazioni sono sequenziali e non costituiscono una transazione unica. Dopo ogni scrittura, il journal registra l'esito durevole. Prima di `batch_completed`, il bridge rilegge ogni risorsa creata e verifica metadati, contenuto, cartella, ACL e proprietà dell'utente autenticato. Una difformità o un esito incerto lascia il lotto recuperabile e impedisce la ricevuta finale.

## ACL di oggetti esistenti

Il catalogo ACL usa soltanto richieste `GET` e può mostrare cartelle e risorse v4/v5 quando i metadata sono decifrabili. Cartelle e risorse, permessi diretti e appartenenze tramite gruppi restano distinti; directory incomplete, soggetti non verificati o ACL non normalizzabili non vengono promossi a stato verificato. Gli oggetti v5 sono marcati read-only: dry-run, apply e recovery di mutazioni ACL li rifiutano prima di ogni richiesta mutativa.

Il dry-run ACL richiede che l'utente autenticato sia un permesso diretto `Owner`, conserva almeno un proprietario e classifica `add`, `upgrade`, `downgrade` e `revoke`. Snapshot, desiderato, directory e piano hanno digest separati. La simulazione Passbolt deve restituire esattamente gli utenti effettivi aggiunti e rimossi dopo l'espansione dei gruppi.

L'applicazione richiede una frase esatta legata a conteggi e digest. Downgrade e revoche richiedono una conferma rafforzata e un secondo avviso. Per una risorsa, il segreto esistente viene decifrato e ricifrato soltanto se servono nuove copie per destinatari aggiunti; il testo in chiaro non attraversa Python o WPF e non entra nel journal.

Il journal ACL è separato da quello di importazione. In caso di esito incerto, il recupero accetta soltanto `remote_success`, con chiusura senza seconda scrittura, oppure `not_applied`, con ripetizione del medesimo piano originario. Qualsiasi stato intermedio o differente è un conflitto fail-closed.

## Journal e recupero degli import

Il journal JSON Lines viene creato dopo un dry-run valido e prima della prima operazione irreversibile. Registra UUID, hash, digest, identificativi tecnici, stati e contatori; rifiuta campi riconducibili a password, passphrase, segreti, chiavi private, MFA, cookie, autorizzazioni o sessioni. Non registra percorsi, titoli, username o URL delle credenziali.

I record sono concatenati con SHA-256 e sincronizzati su disco. La catena rileva corruzione e troncamento ma non è una firma; per questo il recupero apre una nuova sessione, rilegge sorgenti e stato remoto e confronta origine, fingerprint, identità, destinazione, ACL e digest. Un lease esclusivo impedisce recuperi concorrenti dello stesso lotto.

Un HTTP 5xx, timeout, disconnessione o lettura incompleta dopo una richiesta mutativa produce `unknown`. Prima di qualsiasi retry, il recupero deve dimostrare univocamente:

- `not_applied`, quindi può ripetere una sola volta la stessa operazione; oppure
- `remote_success`, quindi chiude l'operazione senza riscriverla.

Duplicati ambigui, oggetti spostati o mancanti, ACL intermedie, sorgenti differenti, journal troncati o corrotti bloccano l'automatismo. Nel solo recovery di journal dichiarati dalle serie 0.16-0.28, il bridge può confrontare il digest storico della relativa generazione ricostruito canonicamente; i journal 0.16 ammettono soltanto il piano additivo previsto dalla loro epoca. Il normale dry-run/apply continua a richiedere il digest corrente vincolato alle capability. L'archiviazione sposta il journal sotto la directory `Archive` senza cancellarlo e richiede UUID, stato corrente e conferma esatta.

## Feedback e ricevute sanitizzate

Il feedback sorgente espone solo contatori aggregati e codici bounded. Le ricevute schema 1 di preflight e migrazione hanno campi chiusi, forma canonica, digest SHA-256 e scrittura atomica.

Sono esclusi origine e fingerprint del server, identità, sessione, nomi e percorsi sorgente, titoli, username, URL, password, chiavi, MFA e ID remoti. La ricevuta di migrazione richiede tutte le risorse create e verificate, zero difformità e journal `complete`. Errori o esiti incerti non possono essere convertiti in una ricevuta di successo.

Il digest rileva alterazioni accidentali ma non è una firma. Una ricevuta non sostituisce il journal e non autorizza retry, recupero o distribuzione.

## Endpoint API nel profilo corrente

Il probe pubblico usa:

- `GET /healthcheck/status.json`;
- `GET /auth/verify.json`.

La sessione autenticata usa, secondo l'operazione:

- `GET /auth/login.json` e `POST /auth/login.json` per GPGAuth;
- `POST /mfa/verify/totp.json?api-version=v2` per TOTP;
- `GET /users/me.json`;
- `GET /settings.json`;
- `GET /resource-types.json`;
- `GET /metadata/types/settings.json?api-version=v2` per attestare le capability v5;
- `GET /metadata/keys/settings.json?api-version=v2` e `GET /metadata/keys.json?api-version=v2&contain[metadata_private_keys]=1` quando servono chiavi metadata v5;
- `GET /resources.json` e `GET /resources/{id}.json`;
- `GET /folders.json` e `GET /folders/{id}.json` per rileggere e attestare le destinazioni;
- `GET /secrets/resource/{id}.json`;
- `GET /share/search-aros.json`;
- `POST /folders.json` e `POST /resources.json` dopo conferma;
- `POST /share/simulate/{folder|resource}/{id}.json` prima delle modifiche ACL;
- `PUT /share/{folder|resource}/{id}.json` dopo simulazione e conferma;
- `DELETE /auth/logout.json` alla chiusura della sessione.

Redirect esterni, downgrade HTTPS, origini diverse, risposte oltre i limiti, content type incoerente e payload non validi vengono bloccati. Per v5, plugin metadata, route, impostazioni di creazione e tipo di risorsa devono essere presenti, tipizzati e coerenti nello stesso snapshot decisionale; booleani non primitivi, enum sconosciuti, definizioni non JSON e ID/slug duplicati interrompono la sessione. Tipo, ID e fingerprint della chiave metadata selezionata partecipano al digest del piano. Il catalogo ACL riusa la stessa attestazione e rifiuta tipi mancanti o cambiati. Prima di collocare una risorsa v5 in una cartella v4 appena creata, l'app rilegge la cartella e richiede corrispondenza esatta di ID, nome e genitore, assenza di marker metadata v5, `personal=true`, permesso Proprietario e un'unica ACL Owner dell'utente autenticato. L'app non usa endpoint di creazione cartelle v5 né endpoint ACL mutativi per oggetti v5.

## Matrici reali v4 e v5-resource-preview

La configurazione schema 1 ammette profili separati con ID logico, URL HTTPS, fingerprint attesa e una delle due combinazioni esplicite: `resource=v4, folder=v4` oppure `resource=v5, folder=v4`. `auto`, cartelle v5 e valori sconosciuti sono rifiutati prima di leggere credenziali o contattare il target. Chiave privata, passphrase e TOTP sono richiesti interattivamente e non vengono salvati nella configurazione.

Le prove automatiche sono read-only e non inviano comandi di importazione o applicazione ACL. Le prove mutative richiedono autorizzazione esplicita dell'operatore e attestazione separata che il target sia dedicato e usa-e-getta. In CI, `integration-matrix run` viene rifiutato prima di leggere credenziali o contattare un'istanza reale.

Ogni scenario manuale lega il proprio risultato a uno dei contratti chiusi `remote_write_success`, `no_write_success` o `fail_closed_no_write`. Per il profilo v5-resource-preview, condivisione personalizzata, ACL additiva e ACL restrittiva sono prove negative superate soltanto con `ACL_V5_MUTATION_DISABLED`, `rejection_observed=true` e `remote_writes_recorded=false`; le prove ACL operative e i relativi recuperi restano sulle cartelle v4. Metriche incompatibili con il profilo invalidano il report anche se il digest viene ricalcolato.

Il report schema 1 contiene soltanto profilo logico, formati attesi, stati, contatori e codici enumerati. Esclude URL, fingerprint, identità, sessione, ID e nomi remoti, materiale OpenPGP e messaggi API. I report completi v4 e v5-resource-preview devono restare fuori dal repository e superare separatamente `summary --require-complete`; un report storico non può soddisfare il gate corrente.

## Quality gate offline

Installazione delle dipendenze di test ed esecuzione completa:

```powershell
python -m pip install --requirement requirements-test.txt
pnpm install --frozen-lockfile --ignore-scripts
.\run_tests.ps1
```

Il gate esegue:

- verifica dell'identità rispetto a `release-candidate.json`;
- parsing PowerShell, Python e Node;
- self-test dei backend;
- conteggio ed esecuzione della suite Python;
- suite Node/OpenPGP;
- laboratori read-only v4 e v5-resource-preview sul loopback;
- accettazione stateful e fault di recupero separati per v4 e v5-resource-preview;
- self-test WPF, incluso DPAPI quando disponibile nel profilo;
- rendering e verifica delle anteprime sintetiche;
- `git diff --check`.

I conteggi richiesti non sono duplicati in questa guida: vengono letti dal manifesto schema 2 e confrontati con i risultati JSON effettivi per ciascun profilo. Gli envelope v5 read-only e stateful sono validati con proprietà e tipi JSON esatti; per lo stateful il gate richiede inoltre i nove scenari nell'ordine previsto, nomi univoci, stato `passed` e metriche complete. Una corsa completa produce `offline_gate=passed`; `-SkipUiPreviews` produce `partial_ui_previews_skipped`. Entrambi mantengono `release_authorized=false`: il gate offline non crea un tag o una release e non attesta le matrici reali.

Le matrici reali `16/16` v4 e `16/16` v5-resource-preview del futuro commit candidato non sono attestate. Le evidenze precedenti, inclusa la matrice v5 storica `14/16`, non vengono reinterpretate per il nuovo candidato. Questo rischio è accettato soltanto per preparare una beta tecnica chiaramente etichettata e non production-ready; il gate stabile resta non superato e una release stabile rimane NO-GO.

Il laboratorio di test ascolta esclusivamente su `127.0.0.1`, genera identità e dati sintetici sotto `%TEMP%` e rimuove il workspace al termine. Non installa certificati nel sistema e non contatta istanze Passbolt reali. Le anteprime UI non leggono documenti e non eseguono richieste di rete.

## Storia e sicurezza

Le descrizioni delle versioni precedenti sono conservate nel [CHANGELOG](CHANGELOG.md) come evidenza storica chiaramente separata dai contratti correnti. Per gestione dei dati sensibili, segnalazione delle vulnerabilità e proprietà dei journal consultare [SECURITY.md](SECURITY.md). Per le regole di modifica e verifica consultare [CONTRIBUTING.md](CONTRIBUTING.md).
