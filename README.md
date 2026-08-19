# Passbolt Migration Assistant for Windows

Windows desktop assistant for safely inventorying, reviewing and importing credentials into Passbolt with OpenPGP, MFA TOTP, v4/v5 resources, folders and sharing.

Passbolt Migration Assistant is a local WPF workflow for controlled credential migrations. It inventories supported documents without opening them during discovery, exposes a masked review step, authenticates with Passbolt through GPGAuth and TOTP, builds a deterministic dry-run plan, and writes only after explicit confirmation.

> [!IMPORTANT]
> This is an independent community project. It is not an official Passbolt product and is not affiliated with or endorsed by Passbolt SA. Version 0.26.0 is a development release: validate it in a non-production environment and keep verified backups before any migration.

## Italiano

Passbolt Migration Assistant è un'app desktop Windows per migrare credenziali verso Passbolt in modo controllato. Il flusso separa inventario, revisione mascherata, autenticazione, dry-run e scrittura finale; chiavi private, passphrase, codici MFA e segreti restano locali e non devono mai essere salvati nel repository.

### Funzioni principali

- inventario metadati di file TXT, CSV, JSON, XML, XLSX, DOCX e ODT;
- revisione locale con password mascherate per impostazione predefinita, visualizzazione esplicita temporanea ed editor dei cinque campi importabili;
- riconoscimento dei file `.xlsx` protetti da password, con richiesta interattiva e decifratura esclusivamente in memoria;
- rilevamento automatico di indirizzi IPv4 e IPv6 per il campo URL/host quando manca un URL esplicito;
- verifica pubblica di healthcheck e TLS, con rilevamento e conferma della fingerprint OpenPGP del server;
- sessione GPGAuth riutilizzata durante il workflow, con supporto MFA TOTP;
- creazione di risorse Passbolt v4 e v5 con cifratura OpenPGP locale;
- destinazione nella radice, in cartelle personali o in cartelle condivise esistenti;
- creazione di sottocartelle personali e condivise con permessi ereditati oppure con una ACL personalizzata;
- editor autenticato dei permessi per selezionare utenti e gruppi Passbolt e assegnare Lettura, Aggiornamento o Proprietario ai nuovi oggetti;
- visualizzatore autenticato e read-only delle ACL di cartelle e risorse Passbolt esistenti, inclusi percorsi v4/v5 e gruppi espansi;
- editor di simulazione per confrontare ACL attuale e desiderata, con digest dello snapshot remoto e classificazione di aggiunte, aumenti, riduzioni e revoche;
- applicazione esplicita di aggiunte, aumenti, riduzioni e revoche ACL su cartelle e risorse esistenti, con impatto sugli utenti effettivi, protezione dell'ultimo proprietario e nuova verifica dello stato remoto immediatamente prima della scrittura;
- journal ACL dedicato e recupero idempotente delle risposte incerte, senza ripetere una scrittura quando Passbolt contiene già il risultato atteso;
- gestione locale dei journal ACL con elenco completo degli stati attivi, filtri, dettaglio tecnico sicuro e archiviazione non distruttiva;
- espansione controllata dei gruppi e verifica delle chiavi dei destinatari;
- centro preflight autenticato con controlli espliciti di identità, CSRF, formati v4/v5, chiavi metadati, cataloghi, destinazione, directory permessi e conflitti;
- dry-run con digest, rilevamento duplicati e riconciliazione dei fallimenti parziali;
- dashboard operativa del lotto con avanzamento live, fase e operazione correnti, contatori, tempi e timeline priva di segreti;
- verifica automatica dopo la scrittura di metadati, contenuto cifrato, cartella e ACL, con esito per risorsa e blocco fail-closed in caso di difformità;
- registro locale durevole e privo di segreti per le operazioni eseguite durante ogni lotto;
- recupero guidato e idempotente degli import interrotti, con verifica autenticata e archiviazione non distruttiva dei journal;
- matrice di integrazione ripetibile per laboratori Passbolt v4/v5, con sette prove automatizzate in sola lettura, nove attestazioni operative e report sanitizzati con digest;
- laboratorio HTTPS locale e stateful per esercitare l'app senza un'istanza Passbolt disponibile, con identità, MFA, chiave metadati condivisa v5, documenti e credenziali esclusivamente sintetici;
- accettazione offline automatica dei nove scenari operativi su entrambi i profili v4/v5: importazioni, destinazioni, duplicati, condivisione, ACL additive/restrittive e recuperi dopo fault controllati;
- nessun caricamento dei documenti sorgente su servizi esterni.

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

1. inserire l'URL HTTPS dell'istanza Passbolt;
2. verificare la connessione pubblica;
3. leggere e confermare la fingerprint OpenPGP rilevata automaticamente, confrontandola alla prima connessione con il valore comunicato dall'amministratore tramite un canale indipendente;
4. selezionare la cartella locale contenente i documenti da inventariare;
5. completare revisione, mappatura delle destinazioni, eventuale configurazione dei permessi e dry-run prima di autorizzare la scrittura.

Il pulsante **Preflight e dry-run** prepara il piano senza modificare Passbolt e popola la scheda **Preflight**. La conferma resta disabilitata se almeno un controllo è bloccante. Durante la scrittura, la scheda **Attività lotto** mostra soltanto eventi già registrati nel journal locale; non visualizza password, passphrase o MFA. Prima di dichiarare il successo, l'app rilegge ogni risorsa creata e confronta metadati, contenuto decifrato in memoria, cartella e ACL con il piano. La scheda **Verifica finale** conserva soltanto gli esiti booleani e i titoli già presenti nella revisione locale.

La GUI non richiede più di digitare la fingerprint. Il valore rilevato non viene considerato una prova autonoma dell'identità del server: dopo la conferma, viene mantenuto in memoria e usato come valore atteso dal bridge OpenPGP, che controlla crittograficamente la chiave effettiva ricevuta durante GPGAuth. La conferma vale per la sessione corrente e non costituisce un archivio persistente di server fidati.

Se un import si interrompe dopo l'avvio delle scritture, non ripetere direttamente una nuova importazione dello stesso lotto. Nella fase 04 aprire **Recupero import interrotto**, quindi:

1. selezionare il journal indicato dall'errore;
2. usare la stessa cartella sorgente e rivedere tutti i documenti del lotto, riapplicando eventuali correzioni fatte nella fase 03;
3. avviare la sessione autenticata; se il lotto usava una ACL personalizzata, ricreare nell'editor la stessa selezione di utenti, gruppi e livelli, quindi scegliere **Verifica lotto**;
4. controllare i conteggi **Già riuscite**, **Da applicare** e **Conflitti**, verificando che non siano previste azioni distruttive;
5. digitare la frase esatta `RECUPERA N` e confermare la ripresa;
6. al completamento, archiviare il journal dalla stessa scheda.

I journal troncati o corrotti vengono mostrati ma restano bloccati in modalità fail-closed: richiedono un controllo manuale su Passbolt. Possono essere archiviati esplicitamente come abbandonati, senza essere cancellati.

Per consultare o estendere i permessi già presenti su Passbolt, nella fase 04 aprire **Permessi esistenti**, mantenere attiva la stessa sessione autenticata e scegliere **Leggi permessi**. La scheda consente di filtrare cartelle e risorse, cercare per nome, percorso o ID e visualizzare la ACL del singolo oggetto. Le voci dirette e quelle assegnate tramite gruppo restano distinte; per i gruppi viene mostrato il numero di destinatari effettivi verificati. Se la ACL è completa, tutti i soggetti sono verificati e l'account autenticato è Proprietario, **Simula modifica...** prepara la ACL desiderata e mostra il confronto prima/dopo nella scheda **Piano e applicazione**.

Il pulsante **Applica ACL** richiede `APPLICA ACL N XXXXXXXX` per un piano puramente additivo. Se il piano contiene almeno un downgrade o una revoca, mostra gli utenti effettivi che perderanno o ridurranno l'accesso, richiede `CONFERMO RIDUZIONE ACL R L XXXXXXXX` e presenta un secondo avviso prima della scrittura. L'utente autenticato deve rimanere un permesso diretto `Owner` e il risultato deve conservare almeno un proprietario. Subito prima della `PUT`, il bridge riverifica identità, oggetto, maschera e directory, inclusi membri effettivi dei gruppi e fingerprint delle chiavi; confronta digest dello snapshot, del desiderato, della directory e del piano, quindi una variazione remota invalida l'operazione.

Per ogni modifica viene prima chiamata la simulazione Passbolt. Gli insiemi `added` e `removed` devono coincidere esattamente con gli utenti effettivi calcolati dalla ACL prima e dopo l'espansione dei gruppi; un destinatario inatteso blocca la scrittura. Per una risorsa, il bridge legge e decifra localmente il segreto esistente soltanto se devono essere create nuove copie cifrate. Downgrade e revoche che non aggiungono utenti non richiedono la lettura del segreto. Il testo in chiaro non viene inviato alla GUI o scritto nel journal.

Se l'applicazione restituisce un esito incerto, non preparare un nuovo piano. Usare **Recupera ACL...**, selezionare il journal indicato nell'errore e completare la verifica autenticata. Se la ACL remota coincide con il risultato atteso, il journal viene chiuso senza una seconda scrittura; se coincide esattamente con lo snapshot originale, l'app può ripetere soltanto lo stesso piano originario. Un recupero restrittivo richiede la frase rafforzata e un secondo avviso. Qualsiasi stato parziale o differente è un conflitto fail-closed.

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

Consulta [SECURITY.md](SECURITY.md) prima di segnalare una vulnerabilità o lavorare con materiale sensibile.

## Test locali

I test non contattano un'istanza Passbolt reale. I test di protocollo usano esclusivamente server simulati su `127.0.0.1`. Il comando unico esegue controlli di sintassi, self-test, 114 test Python, suite Node/OpenPGP, matrici read-only v4/v5, 18 scenari stateful offline con ventiquattro percorsi di fault di recupero, contratto WPF, otto anteprime UI e `git diff --check`:

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

Per aprire l'app con un laboratorio v4 o v5:

```powershell
.\run_offline_lab.ps1 -Profile v4
.\run_offline_lab.ps1 -Profile v5
```

Il terminale mostra URL, fingerprint, percorso della chiave privata, passphrase, TOTP e cartella dei documenti da inserire nell'app. Ogni password sintetica contiene il marcatore `LAB-ONLY-NOT-A-REAL-SECRET`. Alla chiusura dell'app il server viene arrestato e il workspace temporaneo viene cancellato. `-KeepWorkspace` ne impedisce la rimozione soltanto per una diagnosi esplicita; il contenuto resta materiale di laboratorio e deve comunque essere eliminato dopo l'uso.

Sono disponibili scenari di autenticazione negativa:

```powershell
.\run_offline_lab.ps1 -Profile v5 -Scenario mfa-rejected
.\run_offline_lab.ps1 -Profile v5 -Scenario session-expired
```

Le fault injection monouso consentono inoltre di simulare una risposta HTTP 500 prima della prossima creazione di risorsa, cartella o condivisione, oppure la scadenza della sessione:

```powershell
.\run_offline_lab.ps1 -Profile v5 -Fault next-resource-create-500
.\run_offline_lab.ps1 -Profile v5 -Fault next-folder-create-500
.\run_offline_lab.ps1 -Profile v5 -Fault next-share-500
.\run_offline_lab.ps1 -Profile v5 -Fault expire-session
```

La versione 0.24.0 aggiunge due fault post-commit: il simulatore applica la creazione della risorsa o la modifica ACL, poi restituisce HTTP 500 come se la risposta conclusiva fosse andata persa. Servono a verificare che il recupero rilegga lo stato remoto, classifichi `remote_success` e chiuda il journal senza ripetere la mutazione:

```powershell
.\run_offline_lab.ps1 -Profile v5 -Fault next-resource-create-after-commit-500
.\run_offline_lab.ps1 -Profile v5 -Fault next-share-after-commit-500
```

La versione 0.25.0 completa lo stesso controllo per la creazione delle cartelle. Il fault seguente persiste la cartella e restituisce HTTP 500 prima di comunicarne l'ID al client; il recupero deve ritrovarla in modo univoco, riusarla come destinazione e creare la risorsa successiva senza una seconda cartella:

```powershell
.\run_offline_lab.ps1 -Profile v5 -Fault next-folder-create-after-commit-500
```

La versione 0.26.0 estende gli stessi controlli alle interruzioni di trasporto senza risposta HTTP. Per ciascuna mutazione è disponibile un fault pre-commit, che deve essere dimostrato `not_applied`, e uno post-commit, che deve essere riconciliato come `remote_success` senza ripetere la scrittura:

```powershell
.\run_offline_lab.ps1 -Profile v5 -Fault next-resource-create-disconnect
.\run_offline_lab.ps1 -Profile v5 -Fault next-resource-create-after-commit-disconnect
.\run_offline_lab.ps1 -Profile v5 -Fault next-folder-create-disconnect
.\run_offline_lab.ps1 -Profile v5 -Fault next-folder-create-after-commit-disconnect
.\run_offline_lab.ps1 -Profile v5 -Fault next-share-disconnect
.\run_offline_lab.ps1 -Profile v5 -Fault next-share-after-commit-disconnect
```

Il controllo automatico in sola lettura, usato anche dal quality gate, esegue le sette prove della matrice e verifica che non restino oggetti nel simulatore:

```powershell
.\run_offline_lab.ps1 -Profile v4 -SelfTest
.\run_offline_lab.ps1 -Profile v5 -SelfTest
```

La versione 0.23.0 aggiunge un secondo controllo automatico, deliberatamente mutativo ma confinato al workspace effimero. Per ciascun profilo esegue le nove prove operative della matrice: risorsa in radice, nuova cartella cliente, destinazione esistente, duplicato senza scritture, condivisione personalizzata, ACL additiva, ACL restrittiva, recupero di un import dopo HTTP 500 e recupero di una ACL dopo HTTP 500. Ogni risorsa creata dal normale import viene riletta e verificata; v5 usa anche una chiave metadati condivisa sintetica con copia privata cifrata e firmata per l'utente del laboratorio.

In 0.26.0 l'accettazione esercita entrambi gli esiti sicuri per creazione risorsa, creazione cartella e modifica ACL sia dopo HTTP 500 sia dopo una disconnessione. Il fault pre-commit deve produrre `not_applied` e una sola ripetizione della mutazione originaria; il fault post-commit deve produrre `remote_success` e zero riscritture della stessa mutazione. Per le cartelle, la risorsa pianificata viene poi creata nella destinazione appena verificata. Gli HTTP 5xx e gli errori di trasporto delle creazioni sono registrati come esito incerto; soltanto una risposta 4xx resta un fallimento confermato.

```powershell
.\run_offline_lab.ps1 -Profile v4 -AcceptanceTest
.\run_offline_lab.ps1 -Profile v5 -AcceptanceTest
```

`-AcceptanceTest` accetta soltanto lo scenario `healthy` senza fault iniziale, imposta internamente dodici percorsi di fault per profilo nei due casi di recupero, controlla che gli envelope di avanzamento non contengano campi sensibili e produce un riepilogo con soli stati e contatori. I 18 esiti sintetici e i ventiquattro percorsi di fault complessivi vengono eseguiti anche dal quality gate, ma non sostituiscono né compilano automaticamente le attestazioni della matrice su istanze Passbolt reali.

Il simulatore riproduce soltanto i contratti API utilizzati dall'app e non sostituisce la verifica finale su una versione Passbolt reale. È però adatto a testare inventario, revisione, login GPGAuth/TOTP, scelta della destinazione, dry-run, creazioni e percorsi di errore senza coinvolgere dati o sistemi aziendali.

## Matrice di integrazione v4/v5

La versione 0.19.0 aggiunge un runner separato per verificare l'app contro istanze Passbolt di laboratorio reali. La configurazione contiene esclusivamente ID del profilo, URL HTTPS, fingerprint pubblica attesa e formati v4/v5: chiave privata, passphrase e TOTP non devono essere aggiunti al file.

Preparare una configurazione locale ignorata da Git:

```powershell
Copy-Item .\integration-matrix.example.json .\integration-matrix.local.json
notepad .\integration-matrix.local.json
.\run_passbolt_integration_matrix.ps1 -Action Validate
```

Per ogni profilo, sostituire URL e fingerprint, impostare `enabled` a `true` e avviare le prove automatizzate:

```powershell
.\run_passbolt_integration_matrix.ps1 -Action Run -Instance v4-lab
.\run_passbolt_integration_matrix.ps1 -Action Run -Instance v5-lab
```

Il runner richiede interattivamente percorso della chiave `.asc`, passphrase e TOTP; nessuno di questi valori compare negli argomenti del processo. Le sette prove automatiche eseguono healthcheck, pinning della fingerprint, GPGAuth/MFA, lettura della directory dei permessi, lettura del catalogo ACL e dry-run sintetici di una risorsa nella radice e di una nuova cartella cliente. Dichiarano sempre `write_requests=0` e non chiamano importazione o applicazione ACL.

I report vengono salvati per impostazione predefinita sotto `%LOCALAPPDATA%\Passbolt Migration Assistant\IntegrationMatrix`. Contengono soltanto profilo logico, formati attesi, stati, contatori e codici enumerati; omettono URL, fingerprint, identità, ID remoti, nomi degli oggetti, chiavi, passphrase, MFA e messaggi API. Un digest SHA-256 rileva modifiche o troncamenti.

Le nove prove che creano oggetti, modificano permessi o simulano recuperi devono essere eseguite nell'app su istanze usa-e-getta e poi attestate singolarmente. Per esempio:

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

Gli scenari manuali sono: importazione nella radice, nuova cartella cliente, destinazione esistente, duplicati, condivisione personalizzata, ACL additiva, ACL restrittiva, recupero import interrotto e recupero ACL interrotto. Un esito `failed` o `blocked` richiede soltanto un `-ErrorCode` enumerato; non inserire note libere o dati reali nel report.

La descrizione completa del comportamento, degli endpoint e dei controlli implementati è disponibile in [LEGGIMI-Passbolt-API.md](LEGGIMI-Passbolt-API.md).

## Limiti attuali e roadmap

La versione 0.26.0 copre anche la perdita completa della risposta a livello di trasporto. Le creazioni di risorsa e cartella registrano un evento incerto durevole quando la richiesta termina con connessione interrotta, timeout o lettura incompleta; il recupero non usa uno stato HTTP fittizio e deve ancora dimostrare `not_applied` oppure `remote_success`. Il laboratorio interrompe deliberatamente la connessione prima e dopo il commit per risorse, cartelle e ACL su entrambi i profili, senza promuovere il risultato sintetico ad attestazione reale.

La versione 0.25.0 completa il recupero sintetico della creazione cartella. Se Passbolt applica `POST /folders.json` ma la risposta conclusiva va persa, la nuova rilettura autenticata deve trovare una sola cartella nella destinazione prevista: il recupero la classifica `remote_success`, la reinserisce nella mappa interna delle destinazioni e completa le risorse senza creare una cartella duplicata. Il ramo pre-commit continua invece a richiedere `not_applied` prima di ripetere una sola volta la creazione. Entrambi i rami sono esercitati su v4 e v5.

La versione 0.24.0 consolida la fault injection dei recuperi incerti. Un errore HTTP 5xx durante una creazione non viene più trattato come prova che la scrittura non sia iniziata: import e ACL rileggono lo stato autenticato e distinguono il ramo `not_applied`, che ripete esattamente la mutazione originaria, da `remote_success`, che chiude il journal senza riscrivere. Il laboratorio dimostra entrambi i rami per v4 e v5, ma resta una regressione sintetica.

La versione 0.23.0 completa nel laboratorio offline l'esecuzione automatica dei nove scenari operativi per entrambi i profili v4/v5. Il simulatore conserva lo stato di risorse, cartelle, segreti e ACL, calcola gli utenti effettivi delle simulazioni Passbolt e consente di riprodurre fallimenti confermati e recuperi idempotenti. Questi 18 scenari sintetici sono una regressione di protocollo, non una certificazione della compatibilità con una release Passbolt reale.

La versione 0.21.0 introduce un laboratorio Passbolt offline, effimero e ripetibile per i profili v4/v5. La matrice automatica verifica entrambi i profili a ogni quality gate; scenari negativi e fault injection consentono di riprodurre errori di autenticazione o scrittura senza accesso al server reale. Il simulatore non sostituisce la validazione di compatibilità su istanze Passbolt dedicate.

La versione 0.20.1 introduce il quality gate Windows riproducibile. `run_tests.ps1` è il punto di ingresso locale e la stessa procedura viene eseguita su GitHub Actions a ogni push su `main`, pull request o avvio manuale. La CI installa esclusivamente dipendenze bloccate, non conserva credenziali Git nel checkout e non può avviare la matrice contro istanze Passbolt reali. Le anteprime pubblicate come artefatti contengono soltanto lo stato iniziale vuoto dell'app.

La versione 0.20.0 introduce una nuova interfaccia chiara ispirata alle applicazioni Apple, mantenendo la struttura operativa già nota. La navigazione laterale mostra sempre la fase corrente e quelle disponibili; card, campi, menu, tabelle e tab condividono ora un unico design system. Nella fase 04 sessione sicura e destinazione sono affiancate, così il piano resta visibile anche senza massimizzare la finestra. L'aggiornamento non modifica protocolli, endpoint, contenuto dei piani o conferme.

La versione 0.19.2 ottimizza l'elaborazione dei lotti estesi senza modificare il flusso operativo. Destinazioni, duplicati e stati di recupero vengono indicizzati in memoria, la revisione riconosce i campi con una sola scansione per record e la verifica d'integrità associa i candidati in tempo costante, interrompendo la lettura del documento quando tutti quelli selezionati sono stati ricostruiti. La creazione iniziale del journal scrive i manifesti già validati a blocchi, evitando una seconda copia contigua dell'intero registro. Restano invariati hash prima e dopo la lettura, limiti in byte, validazione canonica, dry-run, conferme e controlli remoti.

La versione 0.19.1 rimuove i tetti numerici dell'app sul numero di file revisionabili e di credenziali selezionabili o importabili in un lotto. Restano i limiti di sicurezza per singolo documento, le dimensioni massime dei messaggi locali e i vincoli della memoria disponibile e dell'istanza Passbolt. La versione supporta MFA TOTP; gli altri provider MFA sono intenzionalmente fuori dallo scope corrente della roadmap. Gli editor ACL usano utenti e gruppi già presenti in Passbolt e non modificano la composizione dei gruppi. Sono supportate aggiunte, aumenti, riduzioni e revoche di permessi, ma non la cancellazione, lo spostamento o la sovrascrittura degli oggetti Passbolt. L'impatto effettivo di un singolo piano ACL è limitato a 2.000 utenti. I file Excel cifrati sono supportati nel formato moderno `.xlsx`; i file legacy `.xls` devono essere convertiti prima della revisione.

La versione 0.19.0 introduce la matrice ripetibile v4/v5 senza automatizzare scritture distruttive o lasciare artefatti remoti. I controlli pubblici e autenticati in sola lettura sono automatici; importazioni, permessi e recuperi restano operazioni dell'app su laboratori dedicati e vengono registrati come attestazioni esplicite. Il report è sanitizzato e legato a digest, ma non costituisce una firma né sostituisce la revisione dell'operatore.

La versione 0.18.1 riallinea il login al contratto API Passbolt corrente: GPGAuth usa prioritariamente `data.gpg_auth` e la verifica TOTP invia soltanto il campo `totp`, senza il precedente parametro legacy `remember`. In caso di errore la finestra mostra codice, fase e stato HTTP sicuri; se Passbolt comunica `servertime`, segnala anche uno scarto significativo dell'orologio Windows. Chiave, passphrase, TOTP, cookie e URL privati non entrano nella diagnostica.

La versione 0.17.0 applica piani ACL `additive`, `mixed` o `restrictive`. Il piano rimane volatile e obbligatorio; Python crea prima della scrittura un journal separato sotto `%LOCALAPPDATA%\Passbolt Migration Assistant\AclReconciliation`, quindi il bridge ricostruisce da Passbolt lo stesso snapshot. La simulazione `/share/simulate/{folder|resource}/{id}.json` deve confermare esattamente aggiunte e rimozioni previste. La scrittura usa `/share/{folder|resource}/{id}.json`; per le risorse, le copie OpenPGP richieste dalla simulazione vengono create a partire dal segreto esistente senza modificarne lo schema v4/v5.

Il journal ACL contiene origine e fingerprint del server, hash dell'utente, tipo e ID tecnico dell'oggetto, digest, contatori e ACL desiderata normalizzata. Gli ID di utenti e gruppi vengono conservati perché sono necessari a ricostruire automaticamente il risultato dopo un riavvio; password, segreti, chiavi, passphrase, MFA, cookie e identificatori di sessione sono vietati dallo schema. Un recupero accetta soltanto due stati: risultato già presente (`remote_success`) oppure snapshot originale ancora integro (`not_applied`). Uno stato diverso blocca ogni automatismo.

La versione 0.18.0 aggiunge **Gestisci journal...** nella scheda dei permessi esistenti. La finestra elenca journal recuperabili, completi, troncati e corrotti e li filtra per stato, tipo di oggetto, intervallo temporale o testo. Il dettaglio esclude percorsi locali, origine e fingerprint del server, hash utente e destinatari ACL. L'archiviazione richiede la frase esatta `ARCHIVIA ACL <UUID>`, ricontrolla lo stato sotto lease esclusivo e sposta il file in `AclReconciliation\Archive\<stato>`; non elimina il journal e non effettua richieste a Passbolt.

La versione 0.15.1 aggiunge il dry-run delle modifiche ACL sugli oggetti esistenti. Il bridge riverifica sessione e identità, rilegge oggetto, maschera e directory da Passbolt, richiede accesso `Owner` e blocca ACL incomplete o soggetti non verificati. La ACL desiderata conserva implicitamente il proprietario autenticato e può essere anche priva di destinatari esterni, così da rappresentare nel solo piano una revoca completa. Il risultato distingue `add`, `upgrade`, `downgrade` e `revoke`, segnala le azioni sensibili e lega confronto, snapshot e desiderato a digest SHA-256. Il piano è volatile, dichiara `read_only=true`, `write_requests=0` e `remote_writes_planned=0` e non crea journal.

La versione 0.15 introduce la consultazione autenticata degli oggetti esistenti. Il bridge legge cartelle, risorse, maschere e directory con sole richieste `GET`, decifra localmente i nomi v5, normalizza i livelli Read/Update/Owner e segnala ACL incomplete o soggetti non verificabili. Il catalogo è bounded e resta in memoria; la GUI non riceve chiavi, fingerprint o segreti. Questa fase non crea journal perché non esegue alcuna operazione remota irreversibile.

La versione 0.14 introduce l'editor esplicito dei permessi nella fase 04. La directory di utenti e gruppi viene letta soltanto nella sessione autenticata; ogni chiave pubblica e ogni appartenenza di gruppo vengono verificate prima di rendere il destinatario selezionabile. Il proprietario autenticato viene aggiunto sempre come `Owner` e non può essere rimosso o declassato. La ACL normalizzata entra nel digest del dry-run e viene ricontrollata subito prima della scrittura.

I permessi personalizzati si applicano soltanto alle nuove cartelle e risorse create dall'import. Se il piano punta a una cartella esistente, l'importazione è consentita soltanto quando quella cartella possiede già esattamente la stessa ACL; in caso contrario il dry-run si blocca senza modificare l'oggetto. Il journal conserva soltanto modalità e hash della configurazione, non gli ID dei destinatari. Per questo un recupero riavviato deve ricreare la stessa ACL nell'editor e superare il confronto dell'hash.

La versione 0.13 completa il registro locale di riconciliazione privo di segreti, con identificativo del lotto, hash dei sorgenti, ID remoti e stato di ogni creazione. `passbolt_reconciliation.py` definisce il formato JSON Lines versionato, il concatenamento SHA-256, la scrittura sincronizzata e il comportamento sicuro in caso di troncamento o manomissione; il workflow della fase 04 persiste gli eventi prima e dopo ogni operazione irreversibile; il protocollo di sessione riapre un lotto incompleto, riverifica server, fingerprint, utente, sorgenti e stato remoto e costruisce una ripresa idempotente.

La ripresa accetta soltanto stati non ambigui: un'unica risorsa esatta nella destinazione prevista, una richiesta dimostrabilmente non applicata oppure una maschera ancora limitata al solo proprietario. Un esito riuscito seguito dalla scomparsa dell'oggetto, duplicati multipli, contenuti spostati, permessi parziali o variazioni della ACL prevista bloccano ogni automatismo. La GUI distingue lotti recuperabili, completati, troncati e corrotti; presenta il riepilogo autenticato, richiede `RECUPERA N` e non pianifica cancellazioni, spostamenti o sovrascritture.

I registri attivi sono conservati sotto `%LOCALAPPDATA%\Passbolt Migration Assistant\Reconciliation`, fuori dalla cartella del progetto. L'archiviazione li sposta sotto `Reconciliation\Archive\<stato>` e non elimina l'evidenza. Lo schema ammette soltanto identificativi tecnici, hash, contatori e stati: non accetta password, passphrase, MFA, cookie, chiavi, contenuto dei documenti o metadati delle credenziali.

Il prossimo gate esterno resta la chiusura della matrice 0.19.0 su due istanze Passbolt dedicate, una v4 e una v5, conservando soltanto i report sanitizzati fuori dal repository. I sette controlli read-only saranno eseguiti dal runner e i nove scenari mutativi saranno attestati dall'operatore tramite l'app. Dopo il completamento dei sedici scenari per entrambi i profili seguirà la preparazione della distribuzione Windows, inclusi pacchetto riproducibile, firma/verifica degli artefatti e guida di aggiornamento. Finché le istanze reali non sono disponibili, la roadmap può consolidare ulteriormente diagnostica e fault injection, ma non promuoverà gli esiti offline ad attestazioni reali. Il supporto ad altri provider MFA resta saltato come scelta di scope.

## Contribuire

Issue e pull request sono benvenute. Prima di contribuire, leggere [CONTRIBUTING.md](CONTRIBUTING.md) e assicurarsi che test, esempi e log non contengano dati reali.

## Licenza

Copyright (C) 2026 Cesare Polidoro.

Il progetto è distribuito sotto la GNU Affero General Public License v3.0 only (`AGPL-3.0-only`). Vedere [LICENSE](LICENSE) per il testo completo.
