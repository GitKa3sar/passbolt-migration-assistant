# Passbolt Migration Assistant — contratti tecnici correnti

Questa guida descrive esclusivamente i contratti attivi di `0.28.4-beta.1 - Technical beta`. È una beta tecnica non production-ready, limitata a Passbolt v4. La cronologia delle versioni e delle sperimentazioni precedenti è in [CHANGELOG.md](CHANGELOG.md); non va dedotta da questo documento alcuna compatibilità oltre il profilo corrente `passbolt-v4-only`.

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
- `passbolt_crypto.mjs`: GPGAuth, OpenPGP, letture API, dry-run e scritture v4;
- `passbolt_acl_reconciliation.py` e `passbolt_reconciliation.py`: journal, lease e recuperi;
- `passbolt_receipt.py`: feedback aggregato e ricevute sanitizzate;
- `passbolt_integration_matrix.py`: matrice reale v4 e report sanitizzato;
- `offline_lab_*` e `run_offline_lab.ps1`: laboratorio sintetico vincolato al loopback.

Python, Node e WPF comunicano tramite JSON su standard input/output reindirizzati. Chiavi, passphrase, TOTP, password Excel e segreti delle credenziali non vengono passati negli argomenti dei processi o nelle variabili d'ambiente, non vengono registrati e non devono essere scritti in file temporanei. Gli schemi locali sono chiusi e bounded; proprietà sconosciute, messaggi oltre i limiti e risultati incoerenti vengono rifiutati.

## Identità del candidato e profilo di compatibilità

La sola identità corrente è `0.28.4-beta.1`; UI, user agent, progetti, ricevute, laboratorio, matrice e riepilogo del gate devono dichiarare la stessa versione. Il profilo applicativo e di report è `passbolt-v4-only`.

Il file [`release-candidate.json`](release-candidate.json) è la fonte macchina unica per versione, stato del changelog, profilo e conteggi del quality gate. I componenti standalone mantengono costanti locali perché devono poter essere eseguiti senza dipendere da un file di repository; `run_tests.ps1` compensa questo trade-off verificando automaticamente tutte le copie applicative della versione e confrontando i conteggi del manifesto con le suite e i riepiloghi effettivi. Una centralizzazione runtime più ampia introdurrebbe una nuova dipendenza di distribuzione senza modificare il contratto funzionale e non è giustificata per questo candidato.

Il candidato non offre un percorso operativo v5. Formati `auto` o v5, profili v5 e server che espongono plugin, endpoint o resource type v5 vengono rifiutati fail-closed prima di abilitare importazione o gestione ACL. Le fixture legacy v5 conservate nel codice sono soltanto evidenza storica o regressioni negative: non sono eseguite come accettazione positiva, non soddisfano il gate e non costituiscono una promessa di supporto.

## Architettura dell'informazione delle quattro fasi

### 01 — Preparazione locale

L'operatore seleziona la radice dei documenti e, facoltativamente, pianifica l'origine HTTPS. In questa fase non viene attribuita fiducia a un server, non viene aperta una sessione e non vengono letti i valori delle credenziali.

Un progetto `.pbproj` può salvare origine pianificata, radice sorgente, profilo di mappatura, file selezionati e prove tecniche dei candidati. Il payload schema 1 è canonicalizzato, legato a digest, cifrato con DPAPI `CurrentUser` e scritto atomicamente. Non contiene fingerprint fidate, chiavi, passphrase, MFA, cookie, sessioni, password, correzioni, destinazioni remote, ACL, dry-run, ricevute o journal. Il ripristino azzera ogni trust e richiede nuovamente inventario, revisione e verifica remota.

### 02 — Inventario file

L'inventario usa estensione e metadati del filesystem senza aprire i documenti. Riconosce TXT, CSV, JSON, XML, XLSX, DOCX e ODT; PDF è revisionabile entro i limiti dedicati. File temporanei Office, link simbolici o reparse point, estensioni non ammesse e file fuori radice vengono esclusi.

Il riepilogo **Esclusioni e conversioni** contiene soltanto contatori, codici e bucket di formato bounded. Nomi di file, clienti e percorsi non entrano nel feedback aggregato.

### 03 — Revisione controllata

I documenti selezionati vengono aperti localmente e normalizzati nei cinque campi importabili: client, titolo, username, password e URL/host. Le password restano mascherate per impostazione predefinita; la visualizzazione richiede un'azione esplicita e le copie lette dai sorgenti vengono rimosse dalla UI quando si ripristina la maschera o si cambia fase.

I profili di mappatura contengono esclusivamente alias di campo normalizzati. Alias duplicati, sovrapposti o ambigui bloccano la revisione; password e valori sorgente non sono serializzati. Profilo e digest accompagnano i candidati e vengono ricontrollati durante rilettura e pianificazione.

Un `.xlsx` cifrato viene decifrato soltanto in memoria dopo richiesta interattiva della password. Non viene creata una copia in chiaro. I file legacy `.xls` non sono supportati e devono essere convertiti prima della revisione.

### 04 — Operazioni Passbolt v4

La verifica remota è confinata alla fase 04. **Nuova importazione** e **Recupero import interrotto** condividono lo spazio di migrazione; **Gestisci ACL esistenti** è separato e non eredita implicitamente destinazione o piano dell'importazione.

L'ordine operativo resta obbligatorio:

1. inserire o confermare l'origine HTTPS;
2. eseguire la verifica pubblica e confrontare la fingerprint OpenPGP tramite un canale indipendente;
3. confermare la fingerprint per la sola sessione corrente;
4. aprire GPGAuth e completare MFA TOTP quando richiesto;
5. scegliere destinazione e permessi;
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

## Dry-run e importazione v4

Il dry-run è autenticato e non scrive. Rilegge identità, CSRF, impostazioni, tipi di risorsa, cartelle, maschere, directory di utenti e gruppi e risorse accessibili. Capability o oggetti v5 bloccano il percorso. La UI accetta il risultato soltanto se dichiara assenza di scritture e tutti i controlli obbligatori sono `passed` o `not_required`.

Il piano lega tramite digest:

- identità e sessione verificate;
- origine e fingerprint confermata;
- prove tecniche dei sorgenti e profilo di mappatura;
- candidati selezionati e loro destinazioni;
- formato v4 e tipo di risorsa;
- cartelle da riusare o creare;
- ACL desiderata e directory verificata;
- duplicati e conflitti rilevati.

Subito prima della scrittura vengono ricontrollati sessione, identità, sorgenti e digest. Le nuove cartelle sono create prima delle risorse; l'eventuale condivisione deve essere simulata e applicata con successo prima che la cartella sia usata come destinazione. Le password vengono estratte dai sorgenti soltanto al passaggio necessario oppure restano in memoria se corrette nella fase 03. Node cifra e firma localmente il segreto per il proprietario e per gli eventuali destinatari concreti verificati.

Le creazioni sono sequenziali e non costituiscono una transazione unica. Dopo ogni scrittura, il journal registra l'esito durevole. Prima di `batch_completed`, il bridge rilegge ogni risorsa creata e verifica metadati, contenuto, cartella, ACL e proprietà dell'utente autenticato. Una difformità o un esito incerto lascia il lotto recuperabile e impedisce la ricevuta finale.

## ACL di oggetti esistenti

Il catalogo ACL viene letto soltanto in una sessione v4 attiva e usa richieste `GET`. Cartelle e risorse, permessi diretti e appartenenze tramite gruppi restano distinti; directory incomplete, soggetti non verificati o ACL non normalizzabili non vengono promossi a stato verificato.

Il dry-run ACL richiede che l'utente autenticato sia un permesso diretto `Owner`, conserva almeno un proprietario e classifica `add`, `upgrade`, `downgrade` e `revoke`. Snapshot, desiderato, directory e piano hanno digest separati. La simulazione Passbolt deve restituire esattamente gli utenti effettivi aggiunti e rimossi dopo l'espansione dei gruppi.

L'applicazione richiede una frase esatta legata a conteggi e digest. Downgrade e revoche richiedono una conferma rafforzata e un secondo avviso. Per una risorsa, il segreto esistente viene decifrato e ricifrato soltanto se servono nuove copie per destinatari aggiunti; il testo in chiaro non attraversa Python o WPF e non entra nel journal.

Il journal ACL è separato da quello di importazione. In caso di esito incerto, il recupero accetta soltanto `remote_success`, con chiusura senza seconda scrittura, oppure `not_applied`, con ripetizione del medesimo piano originario. Qualsiasi stato intermedio o differente è un conflitto fail-closed.

## Journal e recupero degli import

Il journal JSON Lines viene creato dopo un dry-run valido e prima della prima operazione irreversibile. Registra UUID, hash, digest, identificativi tecnici, stati e contatori; rifiuta campi riconducibili a password, passphrase, segreti, chiavi private, MFA, cookie, autorizzazioni o sessioni. Non registra percorsi, titoli, username o URL delle credenziali.

I record sono concatenati con SHA-256 e sincronizzati su disco. La catena rileva corruzione e troncamento ma non è una firma; per questo il recupero apre una nuova sessione, rilegge sorgenti e stato remoto e confronta origine, fingerprint, identità, destinazione, ACL e digest. Un lease esclusivo impedisce recuperi concorrenti dello stesso lotto.

Un HTTP 5xx, timeout, disconnessione o lettura incompleta dopo una richiesta mutativa produce `unknown`. Prima di qualsiasi retry, il recupero deve dimostrare univocamente:

- `not_applied`, quindi può ripetere una sola volta la stessa operazione; oppure
- `remote_success`, quindi chiude l'operazione senza riscriverla.

Duplicati ambigui, oggetti spostati o mancanti, ACL intermedie, sorgenti differenti, journal troncati o corrotti bloccano l'automatismo. L'archiviazione sposta il journal sotto la directory `Archive` senza cancellarlo e richiede UUID, stato corrente e conferma esatta.

## Feedback e ricevute sanitizzate

Il feedback sorgente espone solo contatori aggregati e codici bounded. Le ricevute schema 1 di preflight e migrazione hanno campi chiusi, forma canonica, digest SHA-256 e scrittura atomica.

Sono esclusi origine e fingerprint del server, identità, sessione, nomi e percorsi sorgente, titoli, username, URL, password, chiavi, MFA e ID remoti. La ricevuta di migrazione richiede tutte le risorse create e verificate, zero difformità e journal `complete`. Errori o esiti incerti non possono essere convertiti in una ricevuta di successo.

Il digest rileva alterazioni accidentali ma non è una firma. Una ricevuta non sostituisce il journal e non autorizza retry, recupero o distribuzione.

## Endpoint API nel profilo corrente

Il probe pubblico usa:

- `GET /healthcheck/status.json`;
- `GET /auth/verify.json`.

La sessione autenticata usa, secondo l'operazione v4:

- `GET /auth/login.json` e `POST /auth/login.json` per GPGAuth;
- `POST /mfa/verify/totp.json?api-version=v2` per TOTP;
- `GET /users/me.json`;
- `GET /settings.json`;
- `GET /resource-types.json`;
- `GET /resources.json` e `GET /resources/{id}.json`;
- `GET /folders.json`;
- `GET /secrets/resource/{id}.json`;
- `GET /share/search-aros.json`;
- `POST /folders.json` e `POST /resources.json` dopo conferma;
- `POST /share/simulate/{folder|resource}/{id}.json` prima delle modifiche ACL;
- `PUT /share/{folder|resource}/{id}.json` dopo simulazione e conferma;
- `DELETE /auth/logout.json` alla chiusura della sessione.

Redirect esterni, downgrade HTTPS, origini diverse, risposte oltre i limiti, content type incoerente e payload non validi vengono bloccati. Gli endpoint metadata v5 non appartengono al flusso operativo corrente; la loro esposizione da parte del target concorre al rifiuto fail-closed del server.

## Matrice reale v4

La configurazione schema 1 ammette soltanto profili v4 con ID logico, URL HTTPS, fingerprint attesa e formati v4 espliciti. Chiave privata, passphrase e TOTP sono richiesti interattivamente e non vengono salvati nella configurazione.

Le prove automatiche sono read-only e non inviano comandi di importazione o applicazione ACL. Le prove mutative richiedono autorizzazione esplicita dell'operatore e attestazione separata che il target sia dedicato e usa-e-getta. In CI, `integration-matrix run` viene rifiutato prima di leggere credenziali o contattare un'istanza reale.

Il report schema 1 contiene soltanto profilo logico, formati attesi, stati, contatori e codici enumerati. Esclude URL, fingerprint, identità, sessione, ID e nomi remoti, materiale OpenPGP e messaggi API. Il report completo deve restare fuori dal repository e superare `summary --require-complete`; un report v5 storico non può soddisfare il gate corrente.

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
- laboratorio read-only v4 sul loopback;
- accettazione stateful v4 e fault di recupero;
- self-test WPF, incluso DPAPI quando disponibile nel profilo;
- rendering e verifica delle anteprime sintetiche;
- `git diff --check`.

I conteggi richiesti non sono duplicati in questa guida: vengono letti dal manifesto e confrontati con i risultati JSON effettivi. Una corsa completa produce `offline_gate=passed`; `-SkipUiPreviews` produce `partial_ui_previews_skipped`. Entrambi mantengono `release_authorized=false`: il gate offline non crea un tag o una release e non attesta la matrice reale v4.

La matrice reale del candidato precedente si è fermata a `7/16` (7 read-only superati, 0 falliti, 1 bloccato, 8 non eseguiti e 0 scritture remote), quindi `summary --require-complete` non è passato. La matrice `16/16` del commit beta corrente non è ancora attestata. Questo rischio è accettato soltanto per preparare una beta tecnica chiaramente etichettata e non production-ready; il punto 4 del gate stabile resta non superato e una release stabile rimane NO-GO.

Il laboratorio di test ascolta esclusivamente su `127.0.0.1`, genera identità e dati sintetici sotto `%TEMP%` e rimuove il workspace al termine. Non installa certificati nel sistema e non contatta istanze Passbolt reali. Le anteprime UI non leggono documenti e non eseguono richieste di rete.

## Storia e sicurezza

Le descrizioni di versioni precedenti, compresi i vecchi esperimenti v5, sono conservate nel [CHANGELOG](CHANGELOG.md) come evidenza storica chiaramente separata dai contratti correnti. Per gestione dei dati sensibili, segnalazione delle vulnerabilità e proprietà dei journal consultare [SECURITY.md](SECURITY.md). Per le regole di modifica e verifica consultare [CONTRIBUTING.md](CONTRIBUTING.md).
