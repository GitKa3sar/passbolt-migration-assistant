# Passbolt Migration Assistant for Windows

Windows desktop assistant for safely inventorying, reviewing and importing credentials into Passbolt v4 or explicitly selected personal v5 resources with OpenPGP and MFA TOTP; folders, sharing and ACL mutations remain v4-only.

Passbolt Migration Assistant is a local WPF workflow for controlled credential migrations. It inventories supported documents without opening them during discovery, exposes a masked review step, authenticates with Passbolt through GPGAuth and TOTP, builds a deterministic dry-run plan, and writes only after explicit confirmation.

> [!IMPORTANT]
> This is an independent community project. It is not an official Passbolt product and is not affiliated with or endorsed by Passbolt SA. Version 0.29.0-beta.1 is a technical beta and is not production-ready: Passbolt v4 remains supported and v5 is limited to explicitly selected personal-resource metadata preview. Automatic negotiation, shared v5 imports, v5 folder creation, format conversion and v5 ACL mutations are rejected fail-closed. Use only a non-production environment and keep verified backups.

## Italiano

Passbolt Migration Assistant è un'app desktop Windows per migrare credenziali verso Passbolt in modo controllato. Il flusso separa inventario, revisione mascherata, autenticazione, dry-run e scrittura finale; chiavi private, passphrase, codici MFA e segreti restano locali e non devono mai essere salvati nel repository.

### Funzioni principali

- inventario dei metadati per le 16 estensioni sorgente dichiarate nel contratto seguente, senza aprire i documenti durante il rilevamento;
- riepilogo aggregato dei file esclusi, non revisionabili o da convertire, per motivazione e formato ma senza nomi, clienti o percorsi;
- revisione locale con password mascherate per impostazione predefinita, visualizzazione esplicita temporanea ed editor dei cinque campi importabili;
- profili locali di mappatura sorgente per associare etichette non standard a titolo, username, password e URL/host, con validazione, digest e anteprima mascherata prima dell'importazione;
- progetti locali di preparazione protetti con Windows DPAPI, per ripristinare origine, cartella, profilo e selezioni tecniche senza salvare trust, sessioni, credenziali, correzioni o piani;
- riconoscimento dei file `.xlsx` protetti da password, con richiesta interattiva e decifratura esclusivamente in memoria;
- rilevamento automatico di indirizzi IPv4 e IPv6 per il campo URL/host quando manca un URL esplicito;
- verifica pubblica di healthcheck e TLS, con rilevamento e conferma della fingerprint OpenPGP del server;
- sessione GPGAuth riutilizzata durante il workflow, con supporto MFA TOTP;
- verifica fail-closed della firma GPGAuth con tolleranza temporale massima di cinque minuti rispetto all'header `Date` della stessa risposta HTTPS;
- creazione di risorse Passbolt v4 o di risorse v5 personali su scelta esplicita, con cifratura OpenPGP locale e cartelle sempre v4; per riusare una cartella con una risorsa v5 servono `personal=true` e la prova ACL dell'utente autenticato come unico proprietario, mentre una cartella appena creata viene riletta e deve conservare ID, nome, genitore, formato v4 e ACL personale prima del primo `POST` risorsa v5;
- per il percorso v4, destinazione nella radice, in cartelle personali o in cartelle condivise esistenti;
- creazione di sottocartelle v4 personali e condivise con permessi ereditati oppure con una ACL personalizzata;
- editor autenticato dei permessi v4 per selezionare utenti e gruppi Passbolt e assegnare Lettura, Aggiornamento o Proprietario ai nuovi oggetti;
- visualizzatore autenticato e read-only delle ACL di cartelle e risorse Passbolt v4/v5 esistenti, inclusi i gruppi espansi;
- editor di simulazione per confrontare ACL attuale e desiderata, con digest dello snapshot remoto e classificazione di aggiunte, aumenti, riduzioni e revoche;
- applicazione esplicita di aggiunte, aumenti, riduzioni e revoche ACL soltanto su oggetti v4 esistenti; gli oggetti v5 restano read-only nel workspace ACL;
- journal ACL dedicato e recupero idempotente delle risposte incerte, senza ripetere una scrittura quando Passbolt contiene già il risultato atteso;
- gestione locale dei journal ACL con elenco completo degli stati attivi, filtri, dettaglio tecnico sicuro e archiviazione non distruttiva;
- espansione controllata dei gruppi e verifica delle chiavi dei destinatari;
- centro preflight autenticato con controlli espliciti di identità, CSRF, formato risorsa v4/v5, cartelle v4, capability server, chiavi metadata, cataloghi, destinazione, directory permessi e conflitti;
- dry-run con digest, rilevamento duplicati e riconciliazione dei fallimenti parziali;
- dashboard operativa del lotto con avanzamento live, fase e operazione correnti, contatori, tempi e timeline priva di segreti;
- verifica automatica dopo la scrittura di metadati, contenuto cifrato, cartella e ACL, con esito per risorsa e blocco fail-closed in caso di difformità;
- ricevute JSON sanitizzate di preflight e migrazione verificata, a schema chiuso e digest canonico;
- registro locale durevole e privo di segreti per le operazioni eseguite durante ogni lotto;
- recupero guidato e idempotente degli import interrotti, con verifica autenticata e archiviazione non distruttiva dei journal;
- matrici di integrazione separate per laboratori Passbolt v4 e v5-resource-preview, con prove automatizzate in sola lettura, attestazioni operative e report sanitizzati con digest;
- laboratorio HTTPS locale e stateful v4/v5 per esercitare l'app senza un'istanza reale, con identità, MFA, documenti e credenziali esclusivamente sintetici;
- accettazione offline automatica degli scenari operativi v4 e delle risorse v5 con cartelle v4, inclusi recuperi dopo fault controllati;
- nessun caricamento dei documenti sorgente su servizi esterni.

### Formati sorgente

L'inventario classifica i file esclusivamente per estensione e metadati. La presenza nell'inventario non garantisce che il contenuto sia valido o che produca candidati: questi controlli avvengono soltanto nella revisione locale, entro i limiti documentati nella [guida tecnica](LEGGIMI-Passbolt-API.md).

<!-- source-format-contract:inventory:start -->
**Estensioni rilevate dall'inventario (16):** `.txt`, `.csv`, `.tsv`, `.json`, `.xml`, `.yaml`, `.yml`, `.ini`, `.cfg`, `.conf`, `.env`, `.properties`, `.docx`, `.xlsx`, `.xls`, `.pdf`.
<!-- source-format-contract:inventory:end -->

<!-- source-format-contract:conversion-only:start -->
**Rilevata ma da convertire prima della revisione:** `.xls`.
<!-- source-format-contract:conversion-only:end -->

I file legacy `.xls` compaiono quindi nell'inventario e nel riepilogo **Esclusioni e conversioni**, ma non vengono analizzati: devono essere convertiti in un formato moderno supportato, per esempio `.xlsx`, prima della revisione. ODT non appartiene al contratto sorgente corrente.

## Requisiti

- Windows 10 o Windows 11;
- Windows PowerShell 5.1;
- Python 3.11 o successivo disponibile in `PATH`;
- Node.js 18 o successivo disponibile in `PATH`;
- pnpm, oppure Corepack con pnpm abilitato;
- connettività HTTPS verso l'istanza Passbolt di destinazione.

Le dipendenze Node sono bloccate da `pnpm-lock.yaml`; i parser Python e il supporto Office cifrato sono bloccati da `requirements.txt`.

## Installazione e avvio

Clonare il repository e installare le dipendenze Python e Node. L'installazione Node non esegue script di pacchetto:

```powershell
git clone https://github.com/GitKa3sar/passbolt-migration-assistant.git
Set-Location .\passbolt-migration-assistant
python -m pip install --requirement .\requirements.txt
pnpm install --frozen-lockfile --ignore-scripts
```

Avviare quindi l'interfaccia:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\run_passbolt_app.ps1
```

Al primo utilizzo:

1. selezionare la cartella locale contenente i documenti da inventariare; l'URL HTTPS pianificato è facoltativo in questa fase;
2. completare inventario e revisione interamente in locale;
3. nella fase 04 inserire o confermare l'URL HTTPS, verificare la connessione pubblica e confrontare la fingerprint OpenPGP rilevata con il valore comunicato dall'amministratore tramite un canale indipendente;
4. aprire la sessione GPGAuth/MFA soltanto dopo la conferma della fingerprint;
5. scegliere esplicitamente il formato risorsa v4 oppure v5 preview, completare destinazione e permessi, quindi eseguire il dry-run prima di autorizzare la scrittura.

Se i documenti usano intestazioni non riconosciute automaticamente, nella fase **Inventario** aprire **Profilo sorgente: Automatico** prima della revisione. Il profilo personalizzato associa una o più etichette a ciascun campo Passbolt; richiede sempre la password e almeno uno fra username e URL/host. **Carica JSON...** e **Salva JSON...** consentono di riusare soltanto la configurazione delle etichette: il file non contiene valori dei documenti o credenziali. Ogni modifica al profilo invalida la revisione e il piano già costruiti, così la griglia mascherata diventa l'anteprima obbligatoria della nuova mappatura.

Per sospendere una preparazione, selezionare i file nell'inventario e usare **Salva progetto...**; dalla revisione vengono aggiunte soltanto le coppie tecniche `candidate_id`/SHA-256 dei candidati pronti selezionati. Il file `.pbproj` è cifrato con Windows DPAPI nello scope dell'utente corrente: dipende dal relativo profilo di protezione e non ha portabilità garantita. **Apri progetto...** ripristina URL HTTPS pianificato, cartella sorgente, profilo e selezioni, ma non attribuisce fiducia al server: inventario e revisione restano disponibili localmente, mentre fingerprint e connessione devono essere rilevate, confrontate e confermate di nuovo nella fase 04. L'inventario viene ricostruito senza aprire i documenti; la revisione resta un'azione esplicita e i candidati vengono riselezionati soltanto se identificativo, hash sorgente e stato **Pronto** coincidono. Password Excel, valori delle credenziali, correzioni manuali, chiave privata, passphrase, MFA, cookie, sessioni, cartelle Passbolt, ACL, dry-run e attestazioni non vengono salvati.

Il pulsante **Preflight e dry-run** prepara il piano senza modificare Passbolt e popola la scheda **Preflight**. La conferma resta disabilitata se almeno un controllo è bloccante. Durante la scrittura, la scheda **Attività lotto** mostra soltanto eventi già registrati nel journal locale; non visualizza password, passphrase o MFA. Prima di dichiarare il successo, l'app rilegge ogni risorsa creata e confronta metadati, contenuto decifrato in memoria, cartella e ACL con il piano. La scheda **Verifica finale** conserva soltanto gli esiti booleani e i titoli già presenti nella revisione locale.

In **Inventario**, **Esclusioni e conversioni** mostra separatamente le segnalazioni dell'intera scansione e quelle dell'ultima revisione selezionata. Il riepilogo usa solo conteggi e bucket di formato bounded: non contiene nomi di file, clienti o percorsi. Dopo un dry-run è possibile esportare dalla scheda **Preflight** una ricevuta JSON con digest del piano, stato e conteggi dei controlli. La ricevuta della scheda **Verifica finale** si abilita soltanto dopo che tutte le risorse create sono state rilette con esito conforme e il journal è stato chiuso. Le ricevute non contengono server, fingerprint, identità, sessione, titoli, username, URL, ID di risorse o cartelle e non sostituiscono il journal per il recupero.

La GUI non richiede più di digitare la fingerprint. Il valore rilevato non viene considerato una prova autonoma dell'identità del server: dopo la conferma, viene mantenuto in memoria e usato come valore atteso dal bridge OpenPGP, che controlla crittograficamente la chiave effettiva ricevuta durante GPGAuth. La conferma vale per la sessione corrente e non costituisce un archivio persistente di server fidati.

Se un import si interrompe dopo l'avvio delle scritture, non ripetere direttamente una nuova importazione dello stesso lotto. Nella fase 04 aprire **Recupero import interrotto**, quindi:

1. selezionare il journal indicato dall'errore;
2. usare la stessa cartella sorgente e rivedere tutti i documenti del lotto, riapplicando eventuali correzioni fatte nella fase 03;
3. avviare la sessione autenticata; se il lotto usava una ACL personalizzata, ricreare nell'editor la stessa selezione di utenti, gruppi e livelli, quindi scegliere **Verifica lotto**;
4. controllare i conteggi **Già riuscite**, **Da applicare** e **Conflitti**, verificando che non siano previste azioni distruttive;
5. digitare la frase esatta `RECUPERA N` e confermare la ripresa;
6. al completamento, archiviare il journal dalla stessa scheda.

I journal troncati o corrotti vengono mostrati ma restano bloccati in modalità fail-closed: richiedono un controllo manuale su Passbolt. Possono essere archiviati esplicitamente come abbandonati, senza essere cancellati.

Per consultare o modificare i permessi già presenti su Passbolt, nella fase 04 scegliere **Gestisci ACL esistenti**. Si apre uno spazio separato dal percorso di migrazione: le opzioni di destinazione dell'import non si applicano agli oggetti esistenti e **Torna alla migrazione** ripristina l'ultimo percorso scelto. Mantenere attiva la stessa sessione autenticata e scegliere **Leggi permessi**. Lo spazio ACL consente di filtrare cartelle e risorse, cercare per nome, percorso o ID e visualizzare la ACL del singolo oggetto. Le voci dirette e quelle assegnate tramite gruppo restano distinte; per i gruppi viene mostrato il numero di destinatari effettivi verificati. Se la ACL è completa, tutti i soggetti sono verificati e l'account autenticato è Proprietario, **Simula modifica...** prepara la ACL desiderata e mostra il confronto prima/dopo in **Piano e applicazione**.

Il pulsante **Applica ACL** richiede `APPLICA ACL N XXXXXXXX` per un piano puramente additivo. Se il piano contiene almeno un downgrade o una revoca, mostra gli utenti effettivi che perderanno o ridurranno l'accesso, richiede `CONFERMO RIDUZIONE ACL R L XXXXXXXX` e presenta un secondo avviso prima della scrittura. L'utente autenticato deve rimanere un permesso diretto `Owner` e il risultato deve conservare almeno un proprietario. Subito prima della `PUT`, il bridge riverifica identità, capability e catalogo dei tipi, oggetto, maschera e directory, inclusi membri effettivi dei gruppi e fingerprint delle chiavi; confronta digest dello snapshot, del desiderato, della directory e del piano, quindi una variazione remota invalida l'operazione.

Per ogni modifica viene prima chiamata la simulazione Passbolt. Gli insiemi `added` e `removed` devono coincidere esattamente con gli utenti effettivi calcolati dalla ACL prima e dopo l'espansione dei gruppi; un destinatario inatteso blocca la scrittura. Per una risorsa, il bridge legge e decifra localmente il segreto esistente soltanto se devono essere create nuove copie cifrate. Downgrade e revoche che non aggiungono utenti non richiedono la lettura del segreto. Il testo in chiaro non viene inviato alla GUI o scritto nel journal.

Se l'applicazione restituisce un esito incerto, non preparare un nuovo piano. Usare **Recupera ACL...**, selezionare il journal indicato nell'errore e completare la verifica autenticata. Se la ACL remota coincide con il risultato atteso, il journal viene chiuso senza una seconda scrittura; se coincide esattamente con lo snapshot originale, l'app può ripetere soltanto lo stesso piano originario. Per i soli journal dichiarati dalle serie 0.16-0.28, il recupero riconosce anche il digest storico della relativa generazione ricostruito esattamente; un journal 0.16 resta limitato ai piani additivi disponibili in quella versione. I nuovi dry-run e apply accettano esclusivamente il digest legato alle capability correnti. Un recupero restrittivo richiede la frase rafforzata e un secondo avviso. Qualsiasi stato parziale o differente è un conflitto fail-closed.

Il controllo pubblico può essere eseguito anche senza aprire la GUI:

```powershell
.\run_passbolt_probe.ps1 `
  -BaseUrl "https://passbolt.example.com" `
  -ExpectedFingerprint "0123456789ABCDEF0123456789ABCDEF01234567"
```

## Modello di sicurezza

L'app adotta un comportamento fail-closed: interrompe il flusso se non riesce a dimostrare l'identità del server o dell'utente, se cambia un sorgente dopo il dry-run, se una chiave non supera i controlli, se una destinazione non è scrivibile o se il confronto dei duplicati è incompleto.

Prima di usare il progetto:

- non copiare mai nel repository chiavi private, passphrase, account-kit o esportazioni reali;
- non usare la fingerprint visualizzata dallo stesso endpoint che si sta tentando di verificare come unica fonte di fiducia;
- provare prima una migrazione minima in un ambiente non produttivo;
- controllare manualmente il piano, il digest e la cartella Passbolt di destinazione;
- conservare un backup verificato e applicare il principio del minimo privilegio all'account usato.

La chiave privata viene selezionata dalla GUI. Passphrase e TOTP sono inviati al bridge locale soltanto per aprire la sessione, rimossi subito dalla richiesta e non scritti nei log. I cookie di sessione restano in memoria e il logout viene tentato alla chiusura. Nella revisione le password vengono mostrate soltanto dopo una conferma esplicita; quelle lette dai sorgenti vengono rimosse dalla UI quando si torna alla maschera o si cambia fase, mentre eventuali correzioni restano in memoria esclusivamente fino all'importazione o alla chiusura. Se un `.xlsx` è protetto, la password del documento viene chiesta soltanto dopo il rilevamento della cifratura, resta in memoria per revisione, verifica d'integrità e importazione e non viene inoltrata a Passbolt. Il formato legacy `.xls` protetto non è supportato.

I progetti `.pbproj` possono contenere percorsi locali e nomi relativi dei documenti, quindi restano materiale operativo riservato anche se protetto. La busta JSON a schema chiuso e i digest rilevano alterazioni prima e dopo la decifratura; DPAPI fornisce riservatezza e integrità per l'utente Windows corrente. La perdita del profilo Windows può rendere il progetto irrecuperabile: il file non sostituisce i documenti sorgente, un backup verificato o il journal di riconciliazione.

Le ricevute `.json` sono artefatti informativi sanitizzati, non firme digitali e non autorizzano retry o recovery. Il loro digest rileva modifiche accidentali al contenuto; la fonte di verità per un esito remoto incerto resta sempre il journal locale insieme a una nuova verifica autenticata.

Consulta [SECURITY.md](SECURITY.md) prima di segnalare una vulnerabilità o lavorare con materiale sensibile.

## Test locali

I test non contattano un'istanza Passbolt reale. I test di protocollo usano esclusivamente server simulati su `127.0.0.1`. Il comando unico esegue parsing, self-test, suite Python e Node/OpenPGP, laboratori read-only/stateful/recovery v4 e v5-resource-preview, self-test WPF, anteprime UI e `git diff --check`. Versione, profilo e conteggi per ciascun percorso hanno una sola fonte macchina in [`release-candidate.json`](release-candidate.json); il runner fallisce in caso di drift:

```powershell
python -m pip install --requirement requirements-test.txt
.\run_tests.ps1
```

Per riprodurre la modalità GitHub Actions e conservare le anteprime in una directory esplicita:

```powershell
.\run_tests.ps1 `
  -Ci `
  -ArtifactDirectory "$env:TEMP\passbolt-ui-previews"
```

La resa delle quattro fasi può essere verificata anche senza una sessione Passbolt. Il comando seguente genera una PNG locale dello stato iniziale della pagina scelta (`Configuration`, `Inventory`, `Review` o `Import`), senza leggere documenti o eseguire richieste di rete. Larghezza e altezza sono espresse in unità WPF; i DPI ammessi sono 96, 120, 144 e 192:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass `
  -File .\PassboltApp.ps1 `
  -RenderPreviewPath "$env:TEMP\passbolt-ui.png" `
  -RenderPreviewPage Import `
  -RenderPreviewWidth 1160 `
  -RenderPreviewHeight 740 `
  -RenderPreviewDpi 144
```

## Laboratorio Passbolt offline v4/v5

La versione 0.21.0 consente di provare il workflow anche quando non è disponibile un server Passbolt. Il runner prepara sotto `%TEMP%` un certificato TLS autofirmato, un'identità OpenPGP con passphrase e TOTP casuali, un piccolo archivio di documenti sintetici e un server HTTPS stateful in ascolto esclusivamente su `127.0.0.1`. Il trust TLS viene applicato soltanto ai processi avviati dal runner: l'archivio certificati di Windows non viene modificato.

Per aprire l'app con un laboratorio sintetico v4 oppure v5-resource-preview:

```powershell
.\run_offline_lab.ps1 -Profile v4
.\run_offline_lab.ps1 -Profile v5
```

Il terminale mostra URL, fingerprint, percorso della chiave privata, passphrase, TOTP e cartella dei documenti da inserire nell'app. Ogni password sintetica contiene il marcatore `LAB-ONLY-NOT-A-REAL-SECRET`. Alla chiusura dell'app il server viene arrestato e il workspace temporaneo viene cancellato. `-KeepWorkspace` ne impedisce la rimozione soltanto per una diagnosi esplicita; il contenuto resta materiale di laboratorio e deve comunque essere eliminato dopo l'uso.

Sono disponibili scenari di autenticazione negativa:

```powershell
.\run_offline_lab.ps1 -Profile v4 -Scenario mfa-rejected
.\run_offline_lab.ps1 -Profile v4 -Scenario session-expired
```

Le fault injection monouso consentono inoltre di simulare una risposta HTTP 500 prima della prossima creazione di risorsa, cartella o condivisione, oppure la scadenza della sessione:

```powershell
.\run_offline_lab.ps1 -Profile v4 -Fault next-resource-create-500
.\run_offline_lab.ps1 -Profile v4 -Fault next-folder-create-500
.\run_offline_lab.ps1 -Profile v4 -Fault next-share-500
.\run_offline_lab.ps1 -Profile v4 -Fault expire-session
```

La versione 0.24.0 aggiunge due fault post-commit: il simulatore applica la creazione della risorsa o la modifica ACL, poi restituisce HTTP 500 come se la risposta conclusiva fosse andata persa. Servono a verificare che il recupero rilegga lo stato remoto, classifichi `remote_success` e chiuda il journal senza ripetere la mutazione:

```powershell
.\run_offline_lab.ps1 -Profile v4 -Fault next-resource-create-after-commit-500
.\run_offline_lab.ps1 -Profile v4 -Fault next-share-after-commit-500
```

La versione 0.25.0 completa lo stesso controllo per la creazione delle cartelle. Il fault seguente persiste la cartella e restituisce HTTP 500 prima di comunicarne l'ID al client; il recupero deve ritrovarla in modo univoco, riusarla come destinazione e creare la risorsa successiva senza una seconda cartella:

```powershell
.\run_offline_lab.ps1 -Profile v4 -Fault next-folder-create-after-commit-500
```

La versione 0.26.0 estende gli stessi controlli alle interruzioni di trasporto senza risposta HTTP. Per ciascuna mutazione è disponibile un fault pre-commit, che deve essere dimostrato `not_applied`, e uno post-commit, che deve essere riconciliato come `remote_success` senza ripetere la scrittura:

```powershell
.\run_offline_lab.ps1 -Profile v4 -Fault next-resource-create-disconnect
.\run_offline_lab.ps1 -Profile v4 -Fault next-resource-create-after-commit-disconnect
.\run_offline_lab.ps1 -Profile v4 -Fault next-folder-create-disconnect
.\run_offline_lab.ps1 -Profile v4 -Fault next-folder-create-after-commit-disconnect
.\run_offline_lab.ps1 -Profile v4 -Fault next-share-disconnect
.\run_offline_lab.ps1 -Profile v4 -Fault next-share-after-commit-disconnect
```

Il controllo automatico in sola lettura, usato anche dal quality gate, esegue per ciascun profilo le sette prove della matrice e verifica che non restino oggetti nel simulatore:

```powershell
.\run_offline_lab.ps1 -Profile v4 -SelfTest
.\run_offline_lab.ps1 -Profile v5 -SelfTest
```

L'accettazione automatica mutativa resta confinata al workspace effimero. Il quality gate corrente esegue, separatamente per v4 e v5-resource-preview, tutte le prove operative dichiarate nel manifesto: risorsa in radice, nuova cartella cliente v4, destinazione esistente, duplicato senza scritture, condivisione personalizzata, ACL additiva, ACL restrittiva, recupero di un import dopo HTTP 500 e recupero di una ACL dopo HTTP 500. Nel profilo preview le risorse sono v5, le cartelle restano v4 e le mutazioni ACL sugli oggetti v5 restano escluse dal prodotto; il simulatore esercita soltanto i percorsi ammessi dal contratto.

In 0.26.0 l'accettazione esercita entrambi gli esiti sicuri per creazione risorsa, creazione cartella e modifica ACL sia dopo HTTP 500 sia dopo una disconnessione. Il fault pre-commit deve produrre `not_applied` e una sola ripetizione della mutazione originaria; il fault post-commit deve produrre `remote_success` e zero riscritture della stessa mutazione. Per le cartelle, la risorsa pianificata viene poi creata nella destinazione appena verificata. Gli HTTP 5xx e gli errori di trasporto delle creazioni sono registrati come esito incerto; soltanto una risposta 4xx resta un fallimento confermato.

```powershell
.\run_offline_lab.ps1 -Profile v4 -AcceptanceTest
```

`-AcceptanceTest` accetta soltanto lo scenario `healthy` senza fault iniziale, imposta internamente i fault di recupero, controlla che gli envelope non contengano campi sensibili e produce un riepilogo con soli stati e contatori. Nel profilo v5 crea risorse v5 ma mantiene le cartelle v4. Gli esiti sintetici non sostituiscono le matrici reali.

Il simulatore riproduce soltanto i contratti API utilizzati dall'app e non sostituisce la verifica finale su una versione Passbolt reale. È però adatto a testare inventario, revisione, login GPGAuth/TOTP, scelta della destinazione, dry-run, creazioni e percorsi di errore senza coinvolgere dati o sistemi aziendali.

## Identita del candidato e decisione go/no-go

Il candidato corrente usa `0.29.0-beta.1` come unica versione applicativa, di protocollo e di report ed è marcato **Technical beta** con profilo `passbolt-v4-v5-resource-preview`. Soltanto `offline_gate: passed` di una corsa completa di `run_tests.ps1` attesta il gate offline del contenuto corrente; `-SkipUiPreviews` dichiara `partial_ui_previews_skipped`. Nessuno dei due esiti crea un tag o una release.

Per una release stabile la decisione resta **GO** soltanto se tutte le condizioni seguenti valgono sul medesimo commit:

1. parsing PowerShell/Python/Node, self-test, suite, laboratori v4/v5, fault di recupero, WPF, anteprime e `git diff --check` sono superati con i conteggi schema 2;
2. runtime, UI, ricevute e gate dichiarano `passbolt-v4-v5-resource-preview`, mentre ogni report di matrice dichiara la coppia di formati v4/v4 o v5/v4; `auto`, import v5 condivisi, cartelle v5, conversioni e ACL mutative v5 restano fail-closed;
3. un operatore ha autorizzato separatamente gli scenari reali e attestato target v4 e v5 dedicati e usa-e-getta;
4. i report sanitizzati delle matrici reali superano separatamente tutti i 16 scenari v4 e i 16 scenari v5-resource-preview con digest valido;
5. i report restano fuori dal repository e non contengono URL, fingerprint, identità, ID remoti, chiavi, passphrase, MFA, cookie, nomi o messaggi API.

Il punto 4 non è superato. Le evidenze precedenti, inclusa la matrice v5 storica `14/16`, non attestano il nuovo candidato e non vengono reinterpretate.

La decisione di prodotto accetta questo rischio residuo esclusivamente per preparare una **beta tecnica non production-ready**, dopo gate offline e CI verdi sullo stesso commit e con etichettatura beta esplicita. La release stabile resta **NO-GO** finché la matrice reale completa non è attestata; la beta non deve essere presentata come superamento del punto 4.

## Matrici di integrazione v4 e v5-resource-preview

Il runner separato prepara report distinti per un'istanza v4 (`resource=v4`, `folder=v4`) o v5-resource-preview (`resource=v5`, `folder=v4`). La configurazione contiene soltanto ID, URL HTTPS, fingerprint pubblica attesa e formati espliciti; chiave privata, passphrase e TOTP non devono essere aggiunti al file. Profili con cartelle v5 o formato `auto` vengono rifiutati.

Preparare una configurazione locale ignorata da Git:

```powershell
Copy-Item .\integration-matrix.example.json .\integration-matrix.local.json
notepad .\integration-matrix.local.json
.\run_passbolt_integration_matrix.ps1 -Action Validate
```

Per ogni profilo, sostituire URL e fingerprint, impostare `enabled` a `true` e avviare le prove automatizzate:

```powershell
.\run_passbolt_integration_matrix.ps1 -Action Run -Instance v4-lab
.\run_passbolt_integration_matrix.ps1 -Action Run -Instance v5-resource-preview
```

Il runner richiede interattivamente percorso della chiave `.asc`, passphrase e TOTP; nessuno di questi valori compare negli argomenti del processo. Le prove automatiche dichiarate nel manifesto eseguono healthcheck, pinning della fingerprint, GPGAuth/MFA, lettura della directory dei permessi, lettura del catalogo ACL e dry-run sintetici di una risorsa nella radice e di una nuova cartella cliente. Dichiarano sempre `write_requests=0` e non chiamano importazione o applicazione ACL.

I report vengono salvati per impostazione predefinita sotto `%LOCALAPPDATA%\Passbolt Migration Assistant\IntegrationMatrix`. Contengono soltanto profilo logico, formati attesi, stati, contatori e codici enumerati; omettono URL, fingerprint, identità, ID remoti, nomi degli oggetti, chiavi, passphrase, MFA e messaggi API. Un digest SHA-256 rileva modifiche o troncamenti.

Le prove che creano oggetti, modificano permessi o simulano recuperi devono essere eseguite nell'app su istanze usa-e-getta e poi attestate singolarmente. Prima della prima prova mutativa l'operatore deve autorizzare esplicitamente l'esecuzione e attestare che il target selezionato e dedicato e usa-e-getta; non inserire segreti nell'autorizzazione, nella configurazione o in chat. Per esempio:

```powershell
.\run_passbolt_integration_matrix.ps1 `
  -Action Record `
  -Report "$env:LOCALAPPDATA\Passbolt Migration Assistant\IntegrationMatrix\matrix-v4-lab-<UUID>.json" `
  -Scenario import_root_resource `
  -Status passed

.\run_passbolt_integration_matrix.ps1 `
  -Action Summary `
  -Report "$env:LOCALAPPDATA\Passbolt Migration Assistant\IntegrationMatrix\matrix-v4-lab-<UUID>.json" `
  -RequireComplete
```

Gli scenari manuali sono: importazione nella radice, nuova cartella cliente, destinazione esistente, duplicati, condivisione personalizzata, ACL additiva, ACL restrittiva, recupero import interrotto e recupero ACL interrotto. Nel profilo v5-resource-preview, condivisione personalizzata e i due scenari ACL sono prove negative: risultano `passed` soltanto se l'operatore osserva `ACL_V5_MUTATION_DISABLED`, indica `-ErrorCode ACL_V5_MUTATION_DISABLED` e non avviene alcuna scrittura remota. Il report lega ogni scenario a `remote_write_success`, `no_write_success` o `fail_closed_no_write` e rifiuta metriche incoerenti anche con digest ricalcolato. Un esito `failed` o `blocked` richiede un `-ErrorCode` enumerato; non inserire note libere o dati reali nel report.

La descrizione completa del comportamento, degli endpoint e dei controlli implementati è disponibile in [LEGGIMI-Passbolt-API.md](LEGGIMI-Passbolt-API.md).

## Limiti correnti

La beta tecnica `0.29.0-beta.1` non è destinata alla produzione. Passbolt v4 resta il percorso completo; v5 è limitato alle risorse personali selezionate esplicitamente. Le cartelle v5 esistenti possono apparire nei cataloghi read-only, ma non sono destinazioni operative; una cartella v4 esistente è proposta al percorso v5 soltanto con prova positiva di ACL personale e unico proprietario autenticato. `auto`, import v5 condivisi, creazione o riuso di cartelle v5, conversioni e ACL mutative v5 vengono rifiutati fail-closed.

Non sono supportati provider MFA diversi da TOTP, la revisione diretta dei file Excel legacy `.xls`, cancellazione o spostamento di oggetti Passbolt e modifiche alla composizione dei gruppi. Le migrazioni devono essere provate su ambienti non produttivi con backup verificati; una risposta di scrittura incerta richiede il recupero autenticato dal journal e non autorizza la ripetizione diretta dell'operazione.

Le matrici reali v4 e v5-resource-preview restano gate esterni separati dal gate offline e devono essere eseguite sul medesimo commit candidato in istanze dedicate e usa-e-getta, conservando soltanto report sanitizzati fuori dal repository. Il profilo corrente non promette supporto per le capability v5 escluse.

La cronologia delle funzionalità, inclusa l'evidenza storica dei precedenti esperimenti v5, è mantenuta esclusivamente in [CHANGELOG.md](CHANGELOG.md). I contratti tecnici correnti sono descritti in [LEGGIMI-Passbolt-API.md](LEGGIMI-Passbolt-API.md).

## Contribuire

Issue e pull request sono benvenute. Prima di contribuire, leggere [CONTRIBUTING.md](CONTRIBUTING.md) e assicurarsi che test, esempi e log non contengano dati reali.

## Licenza

Copyright (C) 2026 Cesare Polidoro.

Il progetto è distribuito sotto la GNU Affero General Public License v3.0 only (`AGPL-3.0-only`). Vedere [LICENSE](LICENSE) per il testo completo.
