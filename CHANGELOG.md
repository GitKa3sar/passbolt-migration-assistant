# Changelog

Le modifiche rilevanti del progetto sono documentate in questo file. Il formato segue [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) e il progetto usa [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.20.1 - 2026-08-14

### Added

- aggiunto `run_tests.ps1`, comando unico per sintassi PowerShell/Python/Node, self-test, 105 test Python, suite OpenPGP, contratto WPF, anteprime UI e controllo del diff;
- separata in `requirements-test.txt` la dipendenza ReportLab usata esclusivamente per costruire PDF sintetici durante i test, senza ampliare le dipendenze runtime dell'app;
- aggiunto il workflow GitHub Actions Windows con Python 3.12, Node.js 24, dipendenze bloccate, permessi `contents: read` e checkout senza credenziali persistenti;
- estesa la modalità di anteprima con larghezza, altezza e DPI validati; il quality gate genera le quattro fasi a 1360×860 e verifica anche 1160×740 fino a 192 DPI;
- aggiunto un test esplicito del blocco delle istanze reali negli ambienti CI.

### Changed

- reso deterministico il runtime del self-test WPF e tollerato, sia nel coordinatore Python sia nel bridge OpenPGP, il BOM UTF-8 che Windows PowerShell 5.1 puo' anteporre alla prima richiesta JSON.

### Security

- il comando `integration-matrix run` rifiuta l'esecuzione quando `CI`, `GITHUB_ACTIONS` o `PASSBOLT_MIGRATION_CI` dichiarano un ambiente non interattivo;
- validazione locale, self-test e report sanitizzati restano disponibili in CI, ma non vengono richiesti chiave privata, passphrase o TOTP e non viene contattata alcuna istanza Passbolt;
- le sole immagini pubblicate come artefatti sono render dello stato iniziale privo di credenziali, conservati per sette giorni;
- l'installazione Node del workflow usa il lockfile e disabilita gli script di lifecycle.

## 0.20.0 - 2026-08-14

### Changed

- introdotto un design system WPF moderno ispirato alle interfacce Apple, con palette chiara, gerarchia tipografica, superfici leggere, spaziature coerenti e angoli arrotondati;
- ridisegnati sidebar, indicatore delle quattro fasi, marchio Passbolt, badge di stato, pulsanti, campi, checkbox, menu a discesa, tab e tabelle;
- resa più compatta la fase 04 tramite due sezioni affiancate per sessione sicura e destinazione/formato, lasciando più spazio al piano di importazione;
- applicato lo stesso tema agli editor WPF secondari senza cambiare i relativi controlli o flussi;
- aumentate la dimensione iniziale e la dimensione minima della finestra per supportare la nuova densità visiva mantenendo il ridimensionamento;
- aggiunta la modalità locale `-RenderPreviewPath` con selezione `-RenderPreviewPage` per generare anteprime PNG delle quattro fasi senza aprire documenti o contattare Passbolt.

### Security

- mantenuti invariati mascheramento delle password, conferme esplicite, sessione in memoria, dry-run e controlli fail-closed;
- il rendering delle anteprime usa esclusivamente lo stato iniziale privo di credenziali e non esegue richieste di rete;
- nessun nuovo dato sensibile viene conservato, serializzato o mostrato dalla nuova interfaccia.

## 0.19.2 - 2026-08-14

### Changed

- indicizzate destinazioni, cartelle, duplicati e classificazioni di recupero per evitare scansioni quadratiche nei lotti estesi;
- ridotta a una sola scansione per record la ricerca dei campi titolo, username, password e URL/host;
- indicizzati i candidati durante la nuova verifica dei sorgenti e arrestato il parser appena tutti i candidati richiesti sono stati ricostruiti;
- scritti separatamente i blocchi già validati del manifesto iniziale del journal, evitando una seconda copia contigua dell'intero registro;
- mantenuto incrementalmente il totale dei byte supportati durante l'inventario;
- aggiunti test di scala per 512 candidati Python, 1.025 candidati Node e 600 prove tecniche nel journal.

### Security

- conservate la doppia verifica SHA-256 dei documenti, la corrispondenza completa dei metadati revisionati e l'estrazione dei segreti soltanto al momento dell'importazione;
- mantenuti invariati validazione canonica, limiti dimensionali in byte, catena SHA-256, dry-run, conferme esplicite e ricontrolli autenticati dello stato remoto;
- rimosso il solo tetto numerico interno di 10.000 operazioni lette nel recovery, continuando a vincolare il payload locale a 64 MiB e il journal a 256 MiB.

## 0.19.1 - 2026-08-13

### Changed

- rimossi i massimi applicativi di 50 file per revisione, 2.000 candidati raccolti e 25 credenziali per lotto;
- estesa a 64 MiB la capacità dei messaggi locali tra WPF, Python e Node per gestire selezioni più grandi;
- introdotto un manifesto concatenato a blocchi per conservare nel journal le prove tecniche di lotti estesi senza perdere integrità o recuperabilità;
- aggiunti test di regressione con 60 file, 2.001 credenziali rilevate, 64 selezionate e 600 prove candidate nel journal.

### Security

- mantenuti i limiti per singolo documento, espansione Office, record, pagine PDF, campi, messaggi in byte ed estensione totale del journal;
- mantenuti la validazione canonica, il rilevamento dei duplicati e il concatenamento SHA-256 anche per i manifesti suddivisi.

## 0.19.0 - 2026-08-13

### Added

- aggiunto `passbolt_integration_matrix.py`, runner opt-in per una matrice ripetibile contro istanze Passbolt v4/v5 reali;
- aggiunte sette prove automatizzate e in sola lettura per healthcheck/pinning, GPGAuth/MFA, directory permessi, catalogo ACL e dry-run sintetici di risorsa e cartella;
- aggiunti nove scenari manuali attestabili per importazioni, destinazioni, duplicati, condivisione, ACL additive/restrittive e recuperi interrotti;
- aggiunti configurazione di esempio, launcher PowerShell, report canonico con digest SHA-256 e otto test automatici dedicati;
- collegato il self-test della matrice al self-test WPF e uniformati i metadati dei componenti alla versione 0.19.0.

### Security

- chiave, passphrase e TOTP sono richiesti interattivamente e inviati soltanto via standard input al comando `session-open`, senza comparire in configurazione, argomenti, ambiente o report;
- i report sanitizzati omettono URL, fingerprint, identità, ID remoti, nomi degli oggetti e messaggi API e accettano soltanto contatori, stati e codici enumerati;
- l'automazione dichiara zero scritture remote e non può invocare importazione o applicazione ACL; le prove mutative restano operazioni esplicite dell'app su laboratori dedicati.

### Roadmap

- la fase successiva eseguirà tutti i sedici scenari sui laboratori v4 e v5; la distribuzione Windows inizierà soltanto dopo la chiusura della matrice.

## 0.18.1 - 2026-08-12

### Fixed

- riallineato il login GPGAuth al contratto API Passbolt corrente, inviando `data.gpg_auth` come struttura primaria sia per la richiesta sia per la risposta alla sfida;
- rimosso il campo legacy `remember` dal corpo TOTP: `POST /mfa/verify/totp.json` riceve ora esclusivamente `{ "totp": "......" }`, evitando il rifiuto delle istanze con validazione rigida;
- mantenuto il payload GPGAuth non racchiuso esclusivamente come fallback per istanze legacy che non restituiscono la sfida con il formato corrente.

### Added

- aggiunta una diagnostica sicura del login con codice errore, fase GPGAuth/MFA e stato HTTP, senza esporre URL privati, cookie, chiavi, passphrase o TOTP;
- aggiunto il confronto tra ora locale e `servertime` della sfida MFA, con indicazione esplicita quando uno scarto significativo può rendere invalido il codice TOTP;
- reso il mock end-to-end deliberatamente rigido sui payload ufficiali GPGAuth e TOTP per prevenire nuove regressioni di compatibilità.

### Security

- continuato a cancellare passphrase e TOTP subito dopo il tentativo e limitata la nuova diagnostica a valori tecnici enumerati e bounded;
- mantenuti cookie di sessione, CSRF e MFA soltanto nel processo Node in memoria, senza persistenza dell'opzione `remember`.

## 0.18.0 - 2026-08-12

### Added

- aggiunta la finestra **Gestisci journal...** nella scheda dei permessi esistenti, con elenco di tutti i journal ACL attivi e filtri per stato, tipo di oggetto, data e testo;
- aggiunto un dettaglio tecnico bounded per contatori, modalità ed esiti del journal, senza esporre percorsi, origine server, fingerprint, identità o destinatari;
- aggiunti i comandi locali `--acl-reconciliation-describe` e `--acl-reconciliation-archive`;
- aggiunti test per descrizione sicura, stato corrotto, archiviazione di journal recuperabili/completi/troncati/corrotti e lease concorrente.

### Changed

- aggiornata l'applicazione e i metadati di progetto alla versione 0.18.0;
- esteso l'elenco ACL con conteggi di aggiunte, aumenti, riduzioni e revoche e con la modalità `additive`, `mixed` o `restrictive`;
- spostata la prossima fase della roadmap sul consolidamento dei test di integrazione contro istanze Passbolt v4/v5 reali e sulla preparazione della distribuzione Windows.

### Security

- resa l'archiviazione ACL non distruttiva e vincolata a UUID v4 canonico, stato atteso, conferma esatta `ARCHIVIA ACL <UUID>` e lease esclusivo;
- separati gli archivi ACL per stato sotto `AclReconciliation\Archive\<stato>`, preservando journal e relativo lock senza inviare richieste remote;
- limitato il protocollo di descrizione ai soli metadati operativi sicuri; un journal corrotto non viene interpretato e può essere soltanto preservato nell'archivio `corrupt`.

## 0.17.0 - 2026-08-11

### Added

- abilitate riduzioni di livello e revoche dei permessi su cartelle e risorse esistenti, anche all'interno di piani misti con aggiunte o aumenti;
- aggiunto il riepilogo degli utenti effettivi che ottengono, perdono, aumentano o riducono l'accesso dopo l'espansione completa dei gruppi;
- aggiunta la conferma rafforzata `CONFERMO RIDUZIONE ACL R L XXXXXXXX`, seguita da un secondo avviso esplicito prima della scrittura;
- aggiunta la conferma `RECUPERA RIDUZIONE ACL R XXXXXXXX` per ripetere una modifica restrittiva da un journal verificato;
- aggiunti test end-to-end per downgrade, revoca, `delete` dei permessi, perdita effettiva tramite gruppo, mismatch della simulazione e recupero restrittivo.

### Changed

- aggiornata l'applicazione e i metadati di progetto alla versione 0.17.0;
- generalizzato il percorso ACL da additive-only a `additive`, `mixed` o `restrictive`, conservando l'ID dei permessi modificati e usando `delete: true` soltanto per le revoche pianificate;
- esteso il journal ACL, in modo retrocompatibile con i journal 0.16.0, con conteggi di downgrade/revoca, utenti rimossi e indicatore delle azioni restrittive;
- spostata la prossima fase della roadmap sulla descrizione e archiviazione non distruttiva dei journal ACL dalla GUI.

### Security

- riconciliati gli insiemi esatti di utenti effettivi `added` e `removed` restituiti da `share/simulate` con la differenza tra ACL iniziale e finale; qualsiasi scostamento blocca la `PUT`;
- imposto che l'utente autenticato rimanga un permesso diretto `Owner` e che il risultato conservi almeno un proprietario, durante piano, applicazione e recupero;
- incluso l'impatto effettivo degli utenti e il numero di Owner nel digest del piano, con limite di 2.000 utenti modificati per mantenere ispezionabile la conferma;
- mantenuta la ricifratura del segreto soltanto per utenti effettivamente aggiunti; downgrade e revoche non leggono il segreto quando non aggiungono destinatari;
- reso il recupero restrittivo idempotente e vincolato agli stessi conteggi, modalità, digest e ACL desiderata del journal originale.

## 0.16.0 - 2026-08-11

### Added

- aggiunto **Applica ACL** per eseguire esclusivamente aggiunte e aumenti di livello su cartelle e risorse Passbolt esistenti;
- aggiunta la conferma esatta `APPLICA ACL N XXXXXXXX`, legata al numero di operazioni e al digest del piano volatile;
- aggiunto `passbolt_acl_reconciliation.py`, con journal JSON Lines dedicato, hash-chain SHA-256, `fsync`, schema chiuso e lease esclusivo;
- aggiunto **Recupera ACL...**, che elenca i journal incompleti e distingue `remote_success` da `not_applied` tramite una nuova verifica autenticata;
- aggiunti i comandi persistenti `session-acl-apply`, `session-acl-recovery-readiness` e `session-acl-recovery-apply`, oltre al comando locale `--acl-reconciliation-list`;
- aggiunti test per applicazione su cartelle, ricifratura del segreto di risorse v4/v5-agnostic, risposta remota incerta, recupero senza doppia scrittura, integrità e lock dei journal ACL.

### Changed

- aggiornata l'applicazione e i metadati di progetto alla versione 0.16.0;
- rinominata la scheda di dettaglio in **Piano e applicazione** e aggiunti i controlli di conferma, applicazione e recupero;
- estesa la simulazione di condivisione alle modifiche ACL degli oggetti esistenti e imposto il rifiuto di qualsiasi rimozione inattesa;
- conservato il testo esatto del segreto esistente durante la ricifratura per nuovi destinatari, senza reinterpretare gli schemi v4 o v5;
- spostata la fase successiva della roadmap su riduzioni e revoche con protezione contro la perdita di accesso, seguita dalla gestione operativa dei journal ACL.

### Security

- ricostruiti e confrontati nuovamente `object_state_digest`, `desired_acl_digest` e `plan_digest` immediatamente prima di ogni scrittura;
- bloccati fail-closed piani con `downgrade`, `revoke`, soggetti omessi, livelli inferiori, record di permesso incompleti, simulazioni con rimozioni o destinatari non previsti;
- letto e decifrato il segreto di una risorsa soltanto nel bridge Node e soltanto quando la simulazione richiede nuove copie cifrate; nessun segreto attraversa Python, WPF o journal;
- legato ogni journal ACL a origine e fingerprint del server, hash dell'utente, oggetto, snapshot, desiderato e piano; rifiutati campi sensibili, materiale OpenPGP, record non canonici, troncamenti e alterazioni della catena;
- reso il recupero idempotente: nessuna seconda `PUT` quando la ACL attesa è già presente e nessun retry quando lo stato remoto non coincide esattamente con snapshot iniziale o risultato finale.

## 0.15.1 - 2026-08-11

### Added

- aggiunto **Simula modifica...** nella scheda **Permessi esistenti** per preparare una ACL desiderata senza applicarla;
- aggiunto il comando persistente `session-acl-plan`, limitato a sessione, tipo/ID dell'oggetto e voci ACL desiderate con schema chiuso;
- aggiunto il confronto prima/dopo con classificazione separata di aggiunte, aumenti, riduzioni e revoche, conteggio delle voci invariate e marcatura delle azioni sensibili;
- aggiunti digest SHA-256 distinti per snapshot remoto, ACL desiderata e piano completo, oltre a un ID volatile del piano;
- aggiunta nella GUI la scheda **Piano read-only** con riepilogo, impatto e livelli precedente/successivo.

### Changed

- aggiornata l'applicazione e i metadati di progetto alla versione 0.15.1;
- riutilizzato l'editor autenticato di utenti e gruppi per costruire la sola ACL desiderata degli oggetti esistenti;
- consentita nel piano una ACL senza destinatari esterni per rappresentare una revoca completa, mantenendo sempre implicito e immutabile il proprietario autenticato;
- spostata la roadmap successiva sulle sole scritture additive con journal dedicato, lasciando riduzioni e revoche a una fase separata.

### Security

- riletto lo stato remoto completo a ogni dry-run e richiesto accesso `Owner`, maschera completa e soggetti integralmente verificati;
- mantenuto il protocollo strettamente read-only con `write_requests=0` e `remote_writes_planned=0`, senza endpoint di condivisione, conferme di applicazione o journal;
- limitato ogni confronto a 2.000 operazioni e ogni ACL desiderata a 500 voci per mantenere bounded protocollo e interfaccia;
- eliminate dal passaggio Python tutte le chiavi non previste nelle voci ACL, impedendo l'inoltro accidentale di candidati, password, passphrase, MFA o materiale OpenPGP;
- aggiunti test end-to-end che dimostrano l'assenza di richieste mutative e il blocco fail-closed di ACL incomplete o directory non verificabili.

## 0.15.0 - 2026-08-11

### Added

- aggiunta nella fase 04 la scheda **Permessi esistenti**, dedicata alla consultazione read-only delle ACL di cartelle e risorse Passbolt;
- aggiunto il comando persistente `session-acl-catalog`, che riusa la sessione GPGAuth e accetta soltanto identificativo di sessione, senza candidati, sorgenti o segreti;
- aggiunti filtri per cartelle/risorse e ricerca per nome, percorso o ID, con dettaglio di soggetti diretti, gruppi, livello di accesso, verifica e destinatari effettivi;
- supportata la decifratura locale dei nomi v5 e la ricostruzione dei percorsi gerarchici senza inoltrare chiavi OpenPGP alla GUI;
- aggiunti test end-to-end per lettura ACL, risoluzione User/Group, espansione dei gruppi e assenza di richieste mutative.

### Changed

- aggiornata l'applicazione e i metadati di progetto alla versione 0.15.0;
- separata visivamente la consultazione degli oggetti esistenti dall'editor che configura i permessi dei soli oggetti nuovi;
- spostato il prossimo blocco della roadmap sul dry-run prima/dopo delle future modifiche ACL, mantenendo disabilitate tutte le scritture sugli oggetti esistenti.

### Security

- verificata nuovamente la sessione e l'identita Passbolt prima di ogni caricamento del catalogo ACL;
- usate esclusivamente richieste HTTP `GET`; la risposta dichiara e la GUI verifica `read_only=true` e `write_requests=0`;
- marcate come incomplete o con avvisi le maschere mancanti, malformate o contenenti soggetti non verificabili, senza presentarle come affidabili;
- limitato il catalogo a 2.000 oggetti, 20.000 righe ACL e 3 MiB serializzati prima della consegna al backend Python;
- esclusi dalla risposta password, segreti, chiavi pubbliche, fingerprint e materiale OpenPGP; nomi, percorsi e ID restano soltanto nella sessione volatile della GUI.

## 0.14.0 - 2026-08-11

### Added

- aggiunto nella fase 04 il comando **Modifica permessi...**, disponibile dopo l'apertura della sessione Passbolt;
- aggiunto il comando persistente `session-permissions`, che legge la directory autenticata di utenti e gruppi senza richiedere nuovamente passphrase o MFA;
- supportati i livelli Passbolt Lettura (`1`), Aggiornamento (`7`) e Proprietario (`15`) per utenti e gruppi già esistenti;
- aggiunti test per catalogo autenticato, ACL personalizzate, blocco delle destinazioni esistenti, immutabilità del proprietario, hash privacy-preserving e associazione dei permessi al recupero.

### Changed

- applicata la ACL personalizzata soltanto a nuove cartelle e nuove risorse create dall'import;
- incluso il proprietario autenticato sempre come Owner, senza consentirne rimozione o declassamento;
- inclusi modalità, voci normalizzate e hash della configurazione nel digest deterministico del piano;
- legato ogni nuovo journal alla modalità e all'hash dei permessi senza persistere gli ID di utenti o gruppi;
- richiesto, per il recupero di un lotto con ACL personalizzata, di ricreare nell'editor la stessa configurazione;
- aggiornata l'applicazione e i metadati di progetto alla versione 0.14.0;
- saltata intenzionalmente l'estensione ad altri provider MFA, mantenendo TOTP come provider supportato e spostando il focus successivo sulle operazioni controllate relative agli oggetti esistenti.

### Security

- mostrati come selezionabili soltanto destinatari attivi con chiavi pubbliche OpenPGP verificabili e gruppi espandibili integralmente;
- ripetuta la validazione autenticata di utenti, gruppi, chiavi e ACL immediatamente prima dell'importazione;
- bloccato il dry-run quando una destinazione già esistente non possiede esattamente la stessa ACL, evitando modifiche implicite dei permessi su oggetti preesistenti;
- bloccato il recupero prima del bridge remoto quando modalità o hash dei permessi non coincidono con il lotto originale;
- mantenuta la compatibilità di lettura con i journal precedenti, trattati come importazioni a permessi ereditati.

## 0.13.0 - 2026-08-11

### Added

- aggiunto il componente locale `passbolt_reconciliation.py` per creare un registro JSON Lines versionato e separato per ogni lotto;
- aggiunti identificativo UUID del lotto, sequenza monotona degli eventi, timestamp UTC, concatenamento SHA-256 e sincronizzazione su disco dopo ogni append;
- definito uno schema a campi consentiti per piano, prove dei sorgenti, intenzioni operative, ID remoti, condivisioni, errori sicuri e completamento del lotto;
- aggiunti test per troncamento dell'ultima scrittura, manomissione, record malformati, associazione fra nome file e lotto e immutabilita dei registri completati;
- collegato il registro alla fase 04: Python lo crea dopo il dry-run e prima della scrittura, quindi inoltra al bridge soltanto l'UUID del lotto;
- aggiunti envelope interni Node-Python per intenzione ed esito di creazione, condivisione, riconciliazione, duplicati saltati e completamento del lotto;
- aggiunti all'esito finale l'UUID e lo stato del registro; la GUI annota il completamento oppure mostra l'UUID del lotto da verificare senza esporre il percorso locale;
- aggiunti test end-to-end per assorbimento degli eventi intermedi, chiusura del registro e interruzione del bridge dopo un'intenzione operativa.
- aggiunta la scansione limitata dei registri locali e la risoluzione di un lotto esclusivamente tramite UUID canonico, senza accettare percorsi forniti dal chiamante;
- aggiunti gli eventi `operation_verified` e `recovery_verified`, associati a un UUID di recupero e a un digest tecnico della verifica autenticata;
- aggiunti i comandi persistenti `session-recovery-readiness` e `session-recovery-import` per ricontrollare l'identita, i sorgenti e lo stato remoto e riprendere lo stesso journal;
- aggiunta la classificazione idempotente di cartelle, risorse e permessi in `remote_success`, `not_applied` o conflitto bloccante;
- aggiunta la riparazione controllata delle condivisioni rimaste personali, inclusa la riestrazione in memoria del segreto soltanto quando serve ricifrarlo per i destinatari;
- aggiunti test per ripresa completa dopo interruzione, oggetti remoti gia riusciti, richieste non applicate, variazione delle ACL, prove sorgente non corrispondenti, conteggi di recupero e journal troncati.
- aggiunto un lease esclusivo per lotto, mantenuto dalla verifica all'applicazione e rilasciato alla chiusura o dal sistema in caso di arresto, per impedire recuperi concorrenti da due istanze dell'app.
- aggiunta nella fase 04 la scheda **Recupero import interrotto**, con elenco dei journal attivi e stati visibili Recuperabile, Completato, Troncato e Corrotto;
- aggiunta l'associazione fail-closed fra lotto e candidati riletti dalla cartella sorgente corrente, inclusi file Excel protetti e correzioni mantenute in memoria;
- aggiunto il riepilogo autenticato delle operazioni già riuscite, non applicate e in conflitto, con indicazione esplicita dell'assenza di azioni distruttive;
- aggiunta la conferma esatta `RECUPERA N` prima della ripresa idempotente, legata a UUID e digest dell'ultima verifica nella stessa sessione;
- aggiunta l'archiviazione esplicita di lotti completati o abbandonati tramite spostamento sotto `Reconciliation\Archive\<stato>`, senza cancellazione del journal;
- aggiunti comandi locali separati per elencare, descrivere e archiviare i lotti senza esporre percorsi o segreti alla GUI;
- completata la documentazione operativa del recupero e attivata la versione 0.13.0.

### Security

- il registro accetta soltanto identificativi, hash, contatori e stati tecnici; rifiuta campi sconosciuti, URL con credenziali, materiale OpenPGP, header di autorizzazione e nomi di campo riconducibili a password, passphrase, MFA, cookie, sessioni o chiavi private;
- l'identificativo utente Passbolt viene trasformato in SHA-256 prima della persistenza e i candidati sono rappresentati soltanto da `candidate_id` e hash SHA-256 del sorgente;
- una riga finale incompleta viene ignorata come conferma ma marca il lotto come da verificare e impedisce ulteriori append automatici; una corruzione interna blocca completamente la lettura fidata;
- i registri sono destinati a `%LOCALAPPDATA%` e sono esclusi dal controllo versione come difesa aggiuntiva;
- ogni intenzione viene sincronizzata prima della richiesta irreversibile a Passbolt e ogni esito viene sincronizzato prima della risposta finale alla GUI;
- gli envelope di avanzamento sono consumati esclusivamente dal backend Python e non modificano il protocollo a risposta singola usato dalla GUI;
- se un evento non e valido o non puo essere scritto, Python termina il bridge e marca il lotto come da verificare;
- prima del recupero vengono confrontati origine e fingerprint del server, hash dell'utente, coppie candidato/sorgente, formati, destinazione e hash della mappatura per cliente;
- le intenzioni di condivisione registrano l'hash della maschera prevista; se la ACL del contenitore o quella dell'oggetto cambia, la ripresa automatica viene bloccata;
- il recupero non cancella, non sposta e non sovrascrive oggetti esistenti; registri corrotti o troncati e stati remoti ambigui richiedono verifica manuale;
- verifica e applicazione sono legate nella stessa sessione tramite UUID e digest del piano di recupero, e i segreti vengono riestratti soltanto per le risorse che devono essere create o ricondivise.
- i journal troncati o corrotti sono visibili ma non possono raggiungere la verifica remota; l'archiviazione richiede UUID, stato corrente, conferma esatta e lease esclusivo e conserva integralmente l'evidenza disponibile;
- dopo una verifica riuscita, la selezione del lotto resta bloccata fino al recupero o alla chiusura della sessione, impedendo di sostituire silenziosamente il piano autenticato.

## 0.12.5 - 2026-08-08

### Added

- aggiunto nella fase 03 il rilevamento dei file `.xlsx` protetti e un prompt mascherato per inserire la password del documento;
- aggiunto il riuso in memoria della password Excel durante visualizzazione esplicita, modifica, dry-run, verifica SHA-256 e importazione;
- aggiunti test automatici con documenti Office realmente cifrati per password mancante, password errata e apertura riuscita.

### Security

- il file Excel viene decifrato soltanto in un buffer volatile, senza produrre copie in chiaro o file temporanei;
- la password del documento passa ai backend locali tramite input standard reindirizzato, viene rimossa dalle strutture di richiesta e non viene inoltrata al bridge Passbolt, inclusa la sessione persistente;
- il backend di revisione continua a serializzare soltanto maschera, lunghezza e metadati della credenziale, senza esporre né la password del documento né quella contenuta nel foglio.

## 0.12.4 - 2026-08-07

### Added

- aggiunto nella fase 03 un toggle per mostrare e nascondere temporaneamente le password, mascherate per impostazione predefinita;
- aggiunto un editor pre-importazione per cliente, titolo, username, URL/host e password;
- aggiunto il riconoscimento di indirizzi IPv4 e IPv6 espliciti o incorporati nei campi non segreti quando URL/host non è valorizzato.

### Changed

- il controllo d'integrità conserva separatamente i metadati originali revisionati e i valori corretti dall'utente, così il dry-run e l'importazione usano le correzioni senza rinunciare alla verifica SHA-256 e alla ricostruzione del candidato;
- una modifica in fase 03 invalida qualsiasi piano precedente e ricalcola immediatamente lo stato **Pronto** o **Da completare**.

### Security

- le password vengono rivelate soltanto dopo conferma esplicita, tramite canali locali reindirizzati, e le copie lette dai sorgenti vengono eliminate dalla UI quando si nascondono le password o si cambia fase;
- le password modificate restano esclusivamente nella memoria della sessione, non entrano nel dry-run, nei log o nei file, e sono consegnate al bridge OpenPGP soltanto per le risorse confermate da creare.

## 0.12.3 - 2026-08-07

### Fixed

- rimossa la chiamata non supportata `POST /share/simulate/folder/{id}`: il dry-run dell'endpoint `/share/simulate` opera sulle risorse, non sulle cartelle;
- allineata la condivisione cartelle al client e al backend ufficiali Passbolt tramite `PUT /share/folder/{id}`;
- aggiunti endpoint, metodo e stato HTTP al messaggio di errore della condivisione cartelle;
- aggiunti versione al titolo degli errori di importazione e ID delle cartelle duplicate al blocco del dry-run.

## 0.12.2 - 2026-08-07

### Fixed

- aggiunto il marcatore `is_new` richiesto dall'API Passbolt per i nuovi permessi di cartelle e risorse condivise;
- aggiunta la riconciliazione sicura delle cartelle personali rimaste dopo una condivisione interrotta, limitata a cartelle vuote con un unico proprietario verificato;
- impedita la creazione di una cartella cliente duplicata durante il recupero da un errore parziale;
- estesi dry-run, conferma e riepilogo finale per distinguere cartelle create, riutilizzate e riconciliate.

## 0.12.1 - 2026-08-07

### Changed

- rimosso l'inserimento manuale della fingerprint dalla fase 01;
- aggiunti rilevamento automatico, visualizzazione in sola lettura e conferma esplicita della fingerprint;
- corretto il marchio testuale nel pannello laterale da `passbolt` a `Passbolt`;
- aggiornata la versione visualizzata e dichiarata dai backend.

### Security

- il rilevamento automatico deve essere richiesto esplicitamente con `--discover-fingerprint`, mentre il probe CLI standard conserva il confronto con una fingerprint attesa;
- dopo la conferma, la fingerprint viene fissata per la sessione e confrontata con quella calcolata dalla chiave OpenPGP effettivamente ricevuta durante GPGAuth;
- aggiunti test unitari per le modalita di rilevamento, confronto riuscito, mancata corrispondenza e selezione obbligatoria della modalita CLI.

## 0.12.0 - 2026-08-07

### Added

- creazione di sottocartelle condivise con maschera di permessi ereditata;
- espansione e deduplicazione dei membri dei gruppi condivisi;
- verifica locale delle chiavi pubbliche dei destinatari;
- condivisione di cartelle e risorse preceduta dalla simulazione Passbolt;
- supporto alla chiave metadati condivisa per risorse v5;
- sessione autenticata riutilizzabile durante l'intero workflow;
- scelta della cartella Passbolt di destinazione, anche distinta per cliente;
- creazione controllata di risorse Passbolt v4 e v5;
- autenticazione GPGAuth con MFA TOTP;
- inventario, revisione mascherata, dry-run con digest e riconciliazione dei fallimenti parziali.

### Security

- URL e fingerprint del server sono ora sempre forniti dall'utente e non sono inclusi nel codice;
- passphrase e TOTP vengono eliminati dalla richiesta e dai campi UI dopo l'apertura della sessione;
- documenti, chiavi, esportazioni e output locali sono esclusi dal controllo versione;
- i redirect esterni, le chiavi non verificabili e i confronti incompleti interrompono il flusso.
