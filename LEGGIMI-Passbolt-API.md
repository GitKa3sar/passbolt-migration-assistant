# Passbolt Migration Assistant

Applicazione desktop locale per preparare in modo controllato la migrazione delle credenziali dai documenti aziendali a Passbolt.

## Avvio dell'app

Aprire PowerShell nella cartella del progetto ed eseguire:

```powershell
.\run_passbolt_app.ps1
```

Il candidato non ancora rilasciato `0.28.1` usa un'interfaccia nativa Windows (WPF), comprende quattro fasi operative ed è limitato a Passbolt v4. UI e backend inviano soltanto formati v4 espliciti; `auto`, i formati v5 e i server che espongono capability v5 vengono rifiutati fail-closed prima di rendere disponibili importazione o gestione ACL. Il supporto v5 resta fuori scope finché la correzione upstream [passbolt_api #618](https://github.com/passbolt/passbolt_api/pull/618), collegata al difetto [#617](https://github.com/passbolt/passbolt_api/issues/617), non viene integrata e distribuita ufficialmente.

### Architettura dell'informazione della fase 04

La preparazione locale non dipende dalla disponibilità di Passbolt: la fase 01 richiede soltanto una cartella sorgente valida, mentre inventario e revisione continuano a lavorare sul filesystem locale. L'URL HTTPS pianificato può essere indicato e salvato nel progetto, ma la verifica pubblica, il rilevamento e la conferma della fingerprint sono eseguiti nella fase 04, immediatamente prima dell'apertura della sessione GPGAuth. Ogni cambio di URL continua a invalidare fingerprint, sessione e piano; nessun controllo fail-closed viene attenuato.

La fase 04 presenta due percorsi di migrazione allo stesso livello, **Nuova importazione** e **Recupero import interrotto**. **Gestisci ACL esistenti** apre invece uno spazio separato, perché le opzioni di destinazione dell'import non hanno significato per oggetti già presenti; **Torna alla migrazione** ripristina l'ultimo percorso scelto. I formati non sono selezionabili: **Cartelle e risorse: v4** e il badge **Passbolt v4-only** descrivono il contratto attivo. Le barre comandi sono righe fisse sempre raggiungibili alla finestra minima di 1160×740 pixel logici. Pulsanti, input, selettori, righe e schede espongono focus visibile e restano raggiungibili con Tab, frecce e attivazione da tastiera secondo il controllo WPF.

### Feedback sorgenti e ricevute sanitizzate

`passbolt_app.py` e `passbolt_review.py` aggiungono ai risultati esistenti soltanto segnalazioni aggregate `{reason_code, extension, count}`. Le estensioni fuori dal pattern bounded vengono ricondotte a `(altro)` e i problemi dell'inventario restano separati da quelli dell'ultima revisione, evitando di presentarne la somma come numero di file unici. Il riepilogo non riceve nomi, clienti o percorsi e distingue formati non supportati, `.xls` da convertire, collegamenti esclusi, errori di accesso, documenti senza candidati, oltre limite o non analizzabili.

`passbolt_receipt.py` accetta tramite standard input locale soltanto evidenze aggregate a schema chiuso. La ricevuta `preflight` conserva digest del piano, stato, strategia logica della destinazione, formati v4, modalita permessi, conteggi e coppie allow-listed `check id/status`; esclude dettagli testuali dinamici. La ricevuta `migration` richiede in modo congiunto `complete=true`, zero verifiche fallite, uguaglianza fra risorse pianificate, create e verificate e journal `complete`, quindi aggiunge soltanto l'UUID del lotto. Nessuna ricevuta contiene origine o fingerprint del server, identita, sessione, nomi e percorsi sorgente, titoli, username, URL, ID di risorse o cartelle.

Il documento schema 1 viene canonicalizzato, legato a SHA-256 e scritto atomicamente nella destinazione `.json` scelta dall'operatore. Il digest rileva alterazioni accidentali ma non è una firma e la ricevuta non sostituisce il journal: un errore o esito remoto incerto non produce mai una ricevuta finale e deve essere risolto attraverso la verifica autenticata del recupero.

### Correzione verifica temporale GPGAuth 0.28.1

La sfida utente di GPGAuth viene ancora decifrata con la chiave privata locale e deve contenere una firma verificabile con la chiave pubblica del server già vincolata alla fingerprint confermata. La verifica usa anzitutto l'ora locale. Se OpenPGP.js segnala esclusivamente che la firma è stata creata nel futuro, il bridge può ripetere la stessa verifica con l'header HTTP `Date` della risposta che contiene la sfida, purché sia un IMF-fixdate valido e lo scarto assoluto non superi 300 secondi.

Il percorso di compatibilità non disabilita la verifica: firma matematica, firmatario, validità della chiave e policy dell'algoritmo hash restano controllati. Un header assente o malformato produce `AUTH_CHALLENGE_CLOCK_UNVERIFIED`; uno scarto eccessivo produce `AUTH_CHALLENGE_CLOCK_SKEW`; una firma errata o appartenente a un'altra chiave produce `AUTH_CHALLENGE_BAD_SIGNATURE`. La GUI mostra soltanto codice, fase e scarto numerico e suggerisce di controllare sia Windows sia il server Passbolt, senza esporre token, chiavi o URL privati.

### Progetti locali di preparazione 0.28.0

La configurazione espone **Apri progetto...**, mentre inventario e revisione espongono **Salva progetto...**. Un progetto schema 1 conserva esclusivamente l'origine HTTPS pianificata, la cartella sorgente assoluta, l'eventuale profilo di mappatura canonico, i percorsi relativi selezionati e, dalla revisione, le sole coppie tecniche `candidate_id`/SHA-256 dei candidati pronti selezionati. Il backend rifiuta proprietà sconosciute, percorsi assoluti o con attraversamento nella selezione, duplicati case-insensitive, digest incoerenti, profili alterati, limiti in byte e prove tecniche non valide.

Il payload canonicalizzato viene cifrato dalla GUI con Windows DPAPI nello scope `CurrentUser`. Il file `.pbproj` contiene una busta JSON a campi chiusi con solo versione, tipo, metodo di protezione, timestamp, ciphertext Base64 e SHA-256 del ciphertext; la scrittura usa un file temporaneo nella stessa directory, flush durevole e sostituzione atomica. Prima della decifratura vengono ricontrollati schema, Base64 e digest; dopo la decifratura vengono ricontrollati schema e digest del payload. Il progetto dipende intenzionalmente dal profilo di protezione dell'utente Windows corrente e non offre portabilità garantita.

Il ripristino è fail-closed: chiude un'eventuale sessione, azzera fingerprint, cookie, cataloghi e piani, mostra l'origine come pianificata e non apre alcun documento. L'inventario può ricostruire subito la selezione dei soli file ancora presenti senza richieste remote. La revisione richiede ancora l'autorizzazione esplicita e riseleziona un candidato soltanto se `candidate_id`, SHA-256 del sorgente e stato **Pronto** coincidono. La verifica Passbolt e la conferma della fingerprint vengono ripetute nella fase 04. Password Excel, valori delle credenziali, correzioni manuali, chiavi, passphrase, MFA, fingerprint fidate, sessioni, destinazioni Passbolt, ACL, attestazioni e journal non entrano nel progetto.

### Profili di mappatura sorgente 0.27.0

La fase **Inventario** espone un profilo opzionale che associa etichette sorgente non standard ai campi `title`, `username`, `secret` e `uri`. Il profilo schema 1 contiene nome e liste di alias, richiede la password e almeno uno fra username e URL/host e viene normalizzato e validato dal backend Python. Sono rifiutati campi sconosciuti, alias vuoti, duplicati o condivisi fra destinazioni, limiti superati e digest non coerenti.

Con un profilo personalizzato, la revisione usa soltanto corrispondenze esatte dopo normalizzazione e disabilita le euristiche integrate, incluso il recupero implicito di un indirizzo IP. La griglia mascherata costituisce l'anteprima: se due colonne configurate alimentano lo stesso campo, il file produce un avviso e nessun candidato importabile. Caricamento e salvataggio JSON trasferiscono soltanto etichette; valori, password e contenuto dei documenti non entrano nel profilo.

Il documento canonico e il relativo digest SHA-256 accompagnano ogni candidato. La verifica d'integrità rilegge il file applicando lo stesso profilo, ne ricontrolla digest, metadati e identificativo e riestrae la password soltanto per l'handoff immediato in memoria. Il bridge include il digest nel piano deterministico. Cambiare o disattivare il profilo invalida revisione e piano; senza profilo restano invariati rilevamento automatico e identificativi delle revisioni precedenti.

### Recuperi dopo disconnessione di trasporto 0.26.0

Le creazioni di cartelle e risorse distinguono ora anche le richieste terminate senza risposta HTTP. Se `fetch` segnala connessione interrotta, timeout o lettura incompleta, il bridge registra `operation_failed` con `outcome: unknown`, conserva soltanto il codice tecnico enumerato e restituisce un lotto parzialmente applicato; non aggiunge uno stato HTTP inventato e non autorizza una ripetizione immediata.

Il laboratorio espone fault `*-disconnect` pre/post-commit per `POST /resources.json`, `POST /folders.json` e `PUT /share/...`. I fault pre-commit chiudono il socket prima di mutare lo stato e devono essere classificati `not_applied`; quelli post-commit persistono prima la mutazione e interrompono la connessione prima della risposta, quindi devono risultare `remote_success`. L'accettazione esegue dodici percorsi per profilo: sei HTTP 500 e sei disconnessioni, sempre suddivisi fra risorsa, cartella e ACL. I ventiquattro percorsi complessivi restano sintetici, loopback e privi di attestazioni reali.

### Recupero delle creazioni cartella incerte 0.25.0

Il laboratorio espone `next-folder-create-after-commit-500`: `POST /folders.json` crea la cartella nello stato sintetico ma restituisce HTTP 500 prima di comunicarne l'ID al client. `session-recovery-readiness` deve ritrovare una sola cartella nella destinazione pianificata, classificarne l'operazione `remote_success` e legare al digest di recupero l'ID remoto verificato.

Durante `session-recovery-import`, la cartella riconciliata viene reinserita nella mappa volatile delle destinazioni con azione `reuse`. Le risorse ancora assenti possono così essere create sotto quella cartella senza ripetere `POST /folders.json`. Il fault pre-commit `next-folder-create-500` esercita il ramo complementare `not_applied`, che ripete una sola volta la creazione e prosegue con la risorsa. Duplicati, destinazioni ambigue o variazioni del piano restano conflitti fail-closed.

L'accettazione stateful esegue ora sei percorsi per profilo: pre/post-commit per creazione risorsa, creazione cartella e applicazione ACL. I dodici percorsi complessivi usano soltanto identità, chiavi, documenti e password sintetici sul listener loopback e non costituiscono attestazioni di istanze Passbolt reali.

### Recuperi di risposte incerte 0.24.0

Gli errori HTTP 5xx restituiti dalla creazione di cartelle o risorse sono registrati nel journal come `outcome: unknown`: una risposta server non riuscita non dimostra infatti che la mutazione non sia stata applicata. Gli HTTP 4xx restano `outcome: confirmed`. Prima di ripetere una scrittura incerta, `session-recovery-readiness` rilegge cataloghi e ACL nella sessione autenticata e accetta soltanto uno stato univoco `not_applied` oppure `remote_success`.

Il laboratorio espone `next-resource-create-after-commit-500` e `next-share-after-commit-500`. In questi fault la mutazione viene applicata allo stato sintetico prima della risposta 500. L'accettazione stateful esegue per ogni profilo quattro percorsi: import e ACL falliti prima del commit, recuperati con una sola scrittura, e gli stessi fallimenti dopo il commit, chiusi senza alcuna seconda mutazione. Il report conserva soltanto risoluzioni e contatori.

### Accettazione stateful offline 0.23.0

`offline_lab_acceptance.py` usa lo stesso bridge persistente dell'app contro il solo simulatore HTTPS effimero e completa sul profilo v4 i nove scenari che sulla matrice reale restano attestazioni dell'operatore: import in radice, creazione cartella cliente, riuso di una destinazione esistente, rilevamento duplicato senza scritture, condivisione personalizzata, modifica ACL additiva, modifica ACL restrittiva, recupero di un import fallito e recupero di una ACL fallita.

Il simulatore mantiene in memoria risorse, cartelle, segreti cifrati e record ACL. La simulazione `/share/simulate/{folder|resource}/{id}.json` applica le variazioni a una copia della maschera, espande il gruppo sintetico e restituisce gli utenti effettivi aggiunti e rimossi; la successiva `PUT` applica la stessa normalizzazione allo stato reale. Il profilo v5 espone anche una chiave metadati condivisa OpenPGP con fingerprint dichiarata e una sola copia privata cifrata per l'utente sintetico e firmata dalla sua chiave.

I due recuperi impostano tramite endpoint amministrativo locale un fault HTTP 500 monouso, verificano gli eventi tecnici del lotto, ricostruiscono il contesto secret-free e ripetono soltanto l'operazione classificata `not_applied`. Il runner pretende che il fault finale sia `none`, che tutti i progressi appartengano all'UUID previsto e che payload e report non contengano password, passphrase, TOTP, chiavi, descrizioni o metadati delle credenziali.

La modalità positiva della release si avvia con `run_offline_lab.ps1 -Profile v4 -AcceptanceTest` ed è parte del quality gate. Dichiara sempre `synthetic_stateful=true`, `real_instance_attestation=false` e `contains_real_credentials=false`: i suoi esiti non vengono importati nei report reali e non sostituiscono l'esecuzione dei sedici scenari sul laboratorio Passbolt v4 dedicato.

### Dashboard, preflight e verifica post-importazione 0.22.0

La scheda **Attività lotto** riceve gli eventi della normale importazione dopo che il coordinatore Python li ha validati e sincronizzati nel journal durevole. Mostra avanzamento per candidati, create, verificate, errori, fase, operazione, tempo trascorso, stima residua e una timeline limitata. Gli envelope sono vincolati a un lotto e non contengono valori sorgente o segreti.

Il comando **Preflight e dry-run** riusa la sessione GPGAuth/MFA aperta e le stesse letture che costruiscono il piano. La scheda dedicata rende espliciti i controlli su identità, CSRF, formati, chiavi v5, cataloghi risorse/cartelle, directory dei permessi, diritto di creazione e conflitti. Un controllo `blocked` mantiene la scrittura disabilitata; `not_required` indica un requisito non applicabile al piano selezionato.

Dopo le `POST` e le eventuali `PUT` di condivisione, ma prima di `batch_completed`, il bridge rilegge ciascuna risorsa con permessi e segreto dell'utente autenticato. Per v5 decifra metadati e contenuto richiedendo la firma OpenPGP dell'utente; per v4 confronta i campi dichiarati e il contenuto secondo lo schema del resource type. Cartella padre e maschera ACL devono coincidere esattamente con il piano, e l'utente corrente deve restare Owner. Il risultato serializzato contiene solo quattro booleani per risorsa; una difformità lascia il journal recuperabile.

### Laboratorio Passbolt offline 0.21.0

`run_offline_lab.ps1` avvia su `127.0.0.1` un server HTTPS effimero che implementa i contratti v4/v5 esercitati dall'app: healthcheck, GPGAuth, MFA TOTP, identità, settings, resource types, directory dei destinatari, cartelle, risorse, segreti, simulazione/condivisione e logout. Lo stato remoto resta in memoria per la durata della sessione e supporta fault injection monouso; certificato, chiavi OpenPGP, passphrase, TOTP e dataset sintetico vengono generati sotto `%TEMP%` e rimossi alla chiusura.

Il self-test usa la matrice read-only esistente e pretende sette scenari superati e zero oggetti remoti. Il laboratorio non è un'implementazione completa di Passbolt e non sostituisce la matrice finale su istanze reali dedicate.

### Quality gate Windows 0.20.1, esteso in 0.21.0

`run_tests.ps1` riunisce in un solo comando parsing PowerShell, compilazione Python, controllo sintattico Node, self-test dei backend, 143 test Python, suite OpenPGP, matrice read-only v4, 9 scenari stateful offline con dodici percorsi di fault di recupero, autoverifica dei 139 controlli WPF, rendering delle anteprime e `git diff --check`. Le dipendenze dei test sono separate in `requirements-test.txt`: ReportLab serve soltanto a costruire un PDF sintetico e non entra nelle dipendenze runtime dell'app. La modalità `-Ci` imposta un confine fail-closed: il runner della matrice può continuare a validare configurazioni e report, ma il comando `run` che richiede credenziali e contatta un laboratorio reale viene rifiutato. L'accettazione mutativa ammessa in CI usa invece esclusivamente il simulatore effimero vincolato al loopback.

Il workflow `.github/workflows/windows-quality.yml` esegue lo stesso comando su `windows-latest` con Python 3.12 e Node.js 24. Il token GitHub ha il solo permesso `contents: read`, le credenziali del checkout non sono persistite e pnpm installa il lockfile senza lifecycle script. Il quality gate produce 29 PNG sintetiche: le quattro fasi alla dimensione standard, la configurazione alla finestra minima e, per la fase 04, stato iniziale e popolato dei tre spazi a 96, 120, 144 e 192 DPI. Le anteprime non contengono credenziali reali e non inviano richieste remote.

### Contratto del candidato e go/no-go

`0.28.1` resta l'unica identita applicativa e di protocollo; il changelog la qualifica come `Unreleased candidate` finche non esiste una decisione di release. Il JSON terminale di una corsa completa di `run_tests.ps1` distingue `offline_gate=passed` da `release_authorized=false`; con `-SkipUiPreviews` dichiara invece `offline_gate=partial_ui_previews_skipped`. La CI non possiede credenziali, non esegue la matrice reale e non puo attestare da sola una release pronta.

Il gate tecnico locale richiede parsing, self-test, 143 test Python, suite Node/OpenPGP, laboratorio v4 read-only, 9 scenari stateful con 12 percorsi di fault, self-test dei 139 controlli WPF, 29 anteprime e `git diff --check`. Il gate esterno richiede sul medesimo candidato una nuova matrice Passbolt v4 reale `16/16`, digest valido e zero stati diversi da `passed`. Prima degli scenari mutativi devono esistere sia l'autorizzazione esplicita dell'operatore sia l'attestazione che l'istanza v4 e dedicata e usa-e-getta. Il solo report sanitizzato previsto viene conservato fuori dal repository; il runner `summary --require-complete` e l'unico esito macchina positivo della matrice completa. I report v5 storici restano leggibili, ma non accettano nuove attestazioni e non possono soddisfare `--require-complete`. Qualunque requisito mancante produce NO-GO.

### Design system e anteprime UI 0.20.0

La finestra principale usa un design system WPF centralizzato con superfici chiare, contrasto controllato, navigazione laterale, card arrotondate, input con stato di focus, tabelle senza griglie verticali e tab in forma di controllo segmentato. I nomi dei 109 controlli e i relativi handler restano invariati. Gli editor WPF creati dinamicamente riusano lo stesso dizionario di risorse, quindi campi e pulsanti conservano la stessa resa della finestra principale.

La fase 04 dispone sessione sicura e opzioni di destinazione in due colonne. Non cambia l'ordine logico delle operazioni: la sessione deve essere autenticata, la destinazione e i formati devono essere validi e il dry-run rimane obbligatorio prima di qualsiasi conferma. Piano, recupero e ACL continuano a usare gli stessi backend e gli stessi digest.

`-RenderPreviewPath <file.png>` esegue il layout WPF fuori schermo e salva una PNG sintetica. `-RenderPreviewPage` accetta soltanto `Configuration`, `Inventory`, `Review` o `Import`; per `Import`, `-RenderPreviewImportTab` seleziona `new_import`, `recovery` o `existing_acl` e `-RenderPreviewImportState` seleziona `initial` o `populated`. `-RenderPreviewWidth` e `-RenderPreviewHeight` sono limitati rispettivamente a 1160–3840 e 740–2160; `-RenderPreviewDpi` accetta 96, 120, 144 o 192. La modalità non mostra finestre, non apre documenti, non autentica l'utente e non invia richieste a Passbolt; serve esclusivamente alla verifica visuale ripetibile dell'interfaccia.

### Ottimizzazioni dei lotti estesi 0.19.2

Il bridge Node costruisce indici in memoria per ID e percorso delle cartelle, identità normalizzata delle credenziali, destinazioni del lotto e UUID delle operazioni di recupero. La classificazione conserva l'ordine e le precedenze precedenti (`server_destination`, `batch`, `server_elsewhere`), ma evita di rileggere integralmente cataloghi e piano per ogni candidato. Anche la riconciliazione riusa mappe e insiemi per risorse, operazioni e azioni già verificate.

Il backend Python indicizza per `candidate_id` le richieste relative a ciascun sorgente. Ogni candidato ricostruito continua a essere confrontato con client, posizione, titolo, username, URL/host, stato di protezione e hash osservati in revisione; quando l'ultimo candidato richiesto è stato trovato, il generatore del parser viene chiuso. La revisione normalizza ogni chiave del record una sola volta e mantiene la stessa regola del primo campo corrispondente.

Il journal valida ancora l'intero flusso e la dimensione complessiva prima della creazione, quindi scrive header e blocchi del manifesto separatamente con un'unica sincronizzazione durevole. Non viene costruita una seconda stringa binaria grande quanto tutto il registro. Il limite storico di 10.000 operazioni nel solo oggetto recovery è stato rimosso; restano i limiti di 64 MiB per i messaggi locali e 256 MiB per il journal, oltre ai controlli canonici, alla catena SHA-256 e alle verifiche remote.

### Matrice di integrazione reale v4

`passbolt_integration_matrix.py` riusa il probe HTTPS e il bridge persistente OpenPGP per eseguire sette scenari automatizzati esclusivamente in lettura su profili di laboratorio v4. La configurazione schema 1 contiene un massimo di otto profili e ammette soltanto ID logico, URL HTTPS, fingerprint OpenPGP attesa e formati v4. Un profilo v5 attivo e una fingerprint segnaposto vengono rifiutati.

Il runner verifica healthcheck e `/auth/verify.json`, apre GPGAuth/TOTP, legge `/share/search-aros.json`, il catalogo ACL e due piani sintetici: risorsa nella radice e risorsa in una nuova cartella cliente. Non invia `session-import`, `session-acl-apply` o conferme e registra `remote_writes_performed=0`. Chiave privata, passphrase e TOTP vengono richiesti interattivamente e la sola richiesta che li contiene è `session-open` sullo standard input del bridge.

Il report schema 1 include identificativo casuale del run, ID logico dell'istanza, formati attesi, orari, stati, contatori e codici errore enumerati. Esclude URL, fingerprint, session ID, identità utente, ID e nomi remoti, materiale OpenPGP, messaggi API e segreti. Il digest SHA-256 canonico rileva modifiche e troncamenti ma non è una firma. Nove scenari con scrittura vengono eseguiti tramite l'app su laboratori usa-e-getta e registrati come attestazioni `passed`, `failed` o `blocked`: import root, nuova cartella, destinazione esistente, duplicato, condivisione personalizzata, ACL additiva, ACL restrittiva e i due recuperi interrotti.

### Compatibilità login GPGAuth e TOTP 0.18.1

Il login usa ora come formato primario la struttura documentata `data.gpg_auth` sia per ottenere la sfida utente sia per restituire il token decifrato. Se un'istanza legacy non restituisce l'header della sfida, viene tentato una sola volta il precedente payload non racchiuso. La verifica MFA usa `POST /mfa/verify/totp.json?api-version=v2` con il solo corpo `{ "totp": "......" }`; non viene inviato il campo legacy `remember`, che può essere respinto dalle versioni con validazione rigida.

Ogni errore di autenticazione acquisisce internamente una fase enumerata: chiave server, verifica crittografica del server, richiesta/decifratura/risposta della sfida, cookie di sessione, lettura identità, MFA TOTP e associazione chiave-identità. La GUI visualizza soltanto fase, codice sicuro, eventuale HTTP e scarto temporale bounded ricavato da `servertime`. Non mostra endpoint, URL, cookie, token, chiavi, passphrase o codice MFA.

### Gestione dei journal ACL 0.18.0

Lo spazio **Gestione permessi esistenti** espone **Gestisci journal...** anche senza una sessione Passbolt attiva, perché le operazioni sono esclusivamente locali. La finestra richiama `--acl-reconciliation-list` e mostra tutti i journal attivi negli stati `recovery_required`, `complete`, `truncated` e `corrupt`. È possibile filtrare per stato, cartella/risorsa, ultime 24 ore, 7 giorni o 30 giorni e cercare per UUID, ID oggetto, tipo, stato o modalità.

`--acl-reconciliation-describe` accetta da standard input soltanto `batch_id` e restituisce UUID, data, stato, tipo e ID oggetto, modalità, contatori delle modifiche e contatori degli eventi. Non restituisce percorso del file, origine o fingerprint del server, hash dell'utente, ACL desiderata o ID dei destinatari. Se il journal è corrotto, non ne interpreta il contenuto e restituisce soltanto UUID e stato `corrupt` con i restanti campi tecnici non disponibili.

`--acl-reconciliation-archive` accetta soltanto `batch_id`, `expected_status` e `confirmation`. La conferma deve essere esattamente `ARCHIVIA ACL <UUID>`; il backend risolve il file tramite UUID v4 canonico, acquisisce il lease esclusivo e rilegge lo stato prima dello spostamento. Il journal e il relativo lock vengono preservati sotto `%LOCALAPPDATA%\Passbolt Migration Assistant\AclReconciliation\Archive\<stato>`. L'operazione non cancella evidenze, non legge sorgenti e non contatta Passbolt.

### Riduzioni e revoche ACL protette 0.17.0

`session-acl-plan` classifica ora ogni piano applicabile come `additive`, `mixed` o `restrictive`. Un piano additivo conserva la conferma `APPLICA ACL N XXXXXXXX`; la presenza di almeno un `downgrade` o `revoke` richiede `CONFERMO RIDUZIONE ACL R L XXXXXXXX`, dove `R` è il numero di operazioni restrittive, `L` il numero di utenti effettivi che perderanno completamente l'accesso e il suffisso deriva dal digest del piano. La GUI mostra anche gli utenti effettivi con accesso ottenuto, perso, aumentato o ridotto dopo l'espansione dei gruppi e presenta un secondo avviso prima della scrittura.

Il calcolo dell'impatto aggrega per utente il livello massimo ottenuto da permessi diretti e gruppi. Un soggetto rimosso dal desiderato non viene quindi considerato una perdita effettiva se lo stesso utente conserva accesso attraverso un'altra sorgente. L'impatto entra in `plan_digest` ed è limitato a 2.000 utenti modificati. Il piano viene bloccato se l'utente autenticato non rimane un permesso diretto `Owner` (`15`) o se il risultato non contiene alcun proprietario.

Per una modifica di livello, il bridge invia l'ID del record di permesso corrente e il nuovo `type`; per una revoca invia lo stesso ID con `delete: true`; per una nuova voce continua a usare `is_new: true`. Prima della `PUT`, `POST /share/simulate/{folder|resource}/{id}.json` deve restituire insiemi `changes.added` e `changes.removed` esattamente uguali alla differenza degli utenti effettivi fra ACL corrente e desiderata. Elementi mancanti, duplicati, sovrapposti o inattesi producono `ACL_APPLY_SIMULATION_MISMATCH` e nessuna scrittura finale.

Le risorse vengono decifrate e ricifrate soltanto quando la simulazione conferma nuovi utenti effettivi. Una riduzione o revoca priva di aggiunte non legge il segreto. Il journal ACL registra ora, oltre ai dati 0.16.0, `downgrade_count`, `revoke_count`, `apply_mode`, utenti effettivi rimossi e indicatore delle azioni restrittive. I campi sono opzionali in lettura per mantenere recuperabili i journal additivi creati dalla 0.16.0, ma sono obbligatori e coerenti per i nuovi journal 0.17.0.

Il recupero continua ad accettare soltanto `remote_success` oppure `not_applied`. Nel secondo caso, un journal restrittivo deve ricostruire gli stessi conteggi e lo stesso `plan_digest`, richiede `RECUPERA RIDUZIONE ACL R XXXXXXXX` e un secondo avviso. Un risultato intermedio o una variazione di ACL, directory, chiavi, gruppi, proprietario o impatto effettivo blocca il retry.

### Applicazione ACL additiva e recupero 0.16.0

Il risultato di `session-acl-plan` espone `additive_apply_available` e una conferma esatta soltanto quando tutte le operazioni sono `add` o `upgrade`. `downgrade` e `revoke` restano nel confronto ma rendono il piano non applicabile. Prima di inoltrare `session-acl-apply`, Python verifica che sessione, ID piano e tre digest coincidano con l'ultimo dry-run osservato, crea un journal ACL dedicato e consegna a Node soltanto il relativo UUID.

Node riverifica `/users/me.json`, rilegge `/resources.json`, `/folders.json` e `/share/search-aros.json`, ricostruisce lo stesso piano e confronta `object_state_digest`, `desired_acl_digest`, `directory_state_digest` e `plan_digest`. Il digest della directory lega al piano membri effettivi dei gruppi, stato degli utenti e fingerprint delle chiavi, senza esporre tali prove alla GUI. Per ogni aumento usa l'ID del permesso esistente; per ogni aggiunta usa `is_new: true`. Nessuna voce corrente può essere omessa o ridotta. Prima della scrittura viene chiamato `POST /share/simulate/{folder|resource}/{id}.json`; una rimozione nella risposta blocca l'operazione. La modifica finale usa `PUT /share/{folder|resource}/{id}.json`.

Per una risorsa, gli utenti aggiunti dalla simulazione devono appartenere all'espansione verificata della ACL desiderata. Il bridge legge `GET /secrets/resource/{id}.json`, decifra il messaggio con la chiave privata già presente nella sessione e ricifra per ogni nuovo utente l'esatto testo del segreto. Non effettua parsing o riserializzazione, quindi conserva lo schema originale di segreti v4 e v5. Il valore in chiaro non attraversa Python/WPF e viene eliminato dai riferimenti locali al termine dell'operazione.

`passbolt_acl_reconciliation.py` scrive file `acl-batch-<UUID>.jsonl` sotto `%LOCALAPPDATA%\Passbolt Migration Assistant\AclReconciliation`. Ogni record è bounded, sincronizzato e concatenato tramite SHA-256. Lo schema accetta soltanto prove tecniche, ACL desiderata normalizzata, intenzione, esito, verifica e completamento; rifiuta campi sensibili e materiale OpenPGP. Gli ID User/Group sono presenti perché il recupero deve poter ricostruire il desiderato dopo il riavvio, ma non sono memorizzati segreti, chiavi, cookie, MFA o ID di sessione.

I comandi `session-acl-recovery-readiness` e `session-acl-recovery-apply` riaprono il journal con lease esclusivo e ricontrollano server, fingerprint e hash dell'utente. Se la ACL remota ha il digest del desiderato, lo stato è `remote_success` e il journal viene chiuso senza `PUT`. Se ha ancora il digest dello snapshot originale, lo stato è `not_applied` e può essere ripetuto esclusivamente lo stesso piano additivo. Qualunque altro digest è `ACL_RECOVERY_CONFLICT` e richiede verifica manuale. La GUI elenca solo journal integri e incompleti; journal troncati o corrotti non vengono recuperati automaticamente.

### Dry-run ACL degli oggetti esistenti 0.15.1

Dopo aver caricato il catalogo nello spazio **Gestione permessi esistenti**, **Simula modifica...** è disponibile soltanto se l'oggetto ha una maschera completa, tutti i soggetti sono verificati e l'utente autenticato possiede il livello Owner (`15`). L'editor rilegge la directory autenticata, precompila utenti e gruppi esterni presenti nella ACL corrente e mantiene il proprietario fuori dalla lista modificabile. È possibile simulare una lista esterna vuota, ma solo per rappresentare una revoca nel piano: nessuna modifica viene applicata.

Python riduce la richiesta `session-acl-plan` ai soli campi `session_id`, `object_type`, `object_id` e `desired_permissions`; ogni voce desiderata conserva esclusivamente `aro`, `aro_foreign_key` e `type`. Node riverifica `/users/me.json` e ricostruisce un catalogo fresco usando le stesse sole richieste `GET` del visualizzatore. Se l'oggetto non è più univoco, la ACL è incompleta, l'accesso corrente non è Owner o un soggetto/chiave/gruppo non è verificabile, il piano viene bloccato.

Il confronto normalizza entrambe le maschere e classifica ogni differenza come `add`, `upgrade`, `downgrade` o `revoke`; le riduzioni, le revoche e le concessioni del livello Owner sono marcate sensibili. Una ACL desiderata è limitata a 500 voci e un confronto a 2.000 operazioni. La risposta include conteggi, righe sicure per la GUI, `object_state_digest`, `desired_acl_digest` e `plan_digest`. Dichiara obbligatoriamente `read_only: true`, `write_requests: 0`, `remote_writes_planned: 0` e `generated_from_fresh_remote_state: true`. La GUI rifiuta un risultato privo di queste garanzie, non mostra alcun pulsante di applicazione e invalida il piano quando cambia oggetto, catalogo o sessione.

### Visualizzatore ACL read-only 0.15.0

La fase 04 apre **Gestione permessi esistenti** come spazio distinto dalla migrazione. Dopo l'apertura della sessione GPGAuth, **Leggi permessi** invia il comando locale `session-acl-catalog`; Python inoltra al bridge esclusivamente comando e UUID della sessione, senza candidati, percorsi sorgente, passphrase, MFA o segreti. Node riverifica `/users/me.json`, quindi usa soltanto richieste `GET` verso `/resources.json`, `/folders.json` e `/share/search-aros.json`. Nel profilo attuale, capability o oggetti v5 vengono rifiutati prima di abilitare il catalogo.

Il bridge ricostruisce i percorsi gerarchici, normalizza le maschere User/Group e associa ogni soggetto alla directory autenticata. La GUI mostra tipo, percorso, accesso corrente, stato personale/condiviso e stato della ACL. Per la voce selezionata distingue utenti diretti e gruppi, visualizza Read (`1`), Update (`7`) o Owner (`15`), stato della verifica e numero di destinatari effettivi. Un gruppo viene considerato verificato soltanto se Passbolt ne restituisce integralmente la composizione e le chiavi dei membri risultano valide.

La risposta non contiene chiavi, fingerprint, password, segreti o materiale OpenPGP e resta soltanto in memoria. Una maschera assente, parzialmente malformata o riferita a soggetti non verificabili viene marcata **Incompleta** o **Con avvisi**, non affidabile. Il protocollo impone al massimo 2.000 oggetti, 20.000 righe di permesso e 3 MiB di catalogo serializzato. Il risultato dichiara `read_only: true` e `write_requests: 0`; la GUI rifiuta risposte che non rispettano entrambi i valori. Il catalogo 0.15.0 non esponeva controlli di modifica; la versione 0.15.1 ha aggiunto l'editor del desiderato e il confronto read-only, mentre la 0.16.0 aggiunge il percorso applicativo separato e vincolato al piano.

### Editor autenticato dei permessi 0.14.0

Nella fase 04 il pulsante **Modifica permessi...** usa la sessione GPGAuth gia aperta per interrogare `/share/search-aros.json`. L'editor elenca utenti e gruppi Passbolt esistenti e assegna a ciascuno uno dei livelli Lettura (`1`), Aggiornamento (`7`) o Proprietario (`15`). Il proprietario autenticato non compare fra i soggetti modificabili: il bridge lo aggiunge sempre come `User` Owner e rifiuta qualunque richiesta che tenti di inserirlo o declassarlo esplicitamente.

Il catalogo non inoltra chiavi pubbliche alla GUI. Node verifica localmente stato dell'utente, fingerprint, scadenza e corrispondenza della chiave, espande integralmente i gruppi e restituisce soltanto identificatori, etichette operative, disponibilita e conteggi. Un utente senza chiave valida o un gruppo incompleto resta visibile come non disponibile e non puo essere salvato nella ACL.

La modalita predefinita resta **Eredita dalla destinazione**. In modalita personalizzata, la maschera normalizzata viene applicata a nuove risorse nella radice e a nuove cartelle/risorse create dall'import. Una cartella gia esistente viene riutilizzata soltanto se possiede gia esattamente la stessa ACL; il piano non modifica permessi di oggetti preesistenti. Modalita, voci e livelli entrano nel digest del dry-run, vengono riletti dalla directory e ricontrollati prima della scrittura.

Il journal salva soltanto `permission_mode` e `permission_configuration_hash`, non gli ID dei soggetti. Un recupero con ACL personalizzata richiede quindi di ricreare la stessa configurazione nell'editor; Python confronta l'hash prima di contattare il bridge e Node riconferma il piano e lo stato remoto. I journal precedenti, privi dei nuovi campi opzionali, sono interpretati come importazioni con permessi ereditati.

### Recupero guidato degli import interrotti 0.13.0

La fase 04 offre due modalità nello stesso percorso di migrazione: **Nuova importazione** e **Recupero import interrotto**. Il recupero elenca i journal locali attivi distinguendo gli stati Recuperabile, Completato, Troncato e Corrotto. **Gestisci ACL esistenti** apre uno spazio separato e non eredita destinazione o opzioni della migrazione. Un lotto recuperabile viene associato soltanto se tutti i suoi `candidate_id` sono stati riletti dalla cartella sorgente corrente e risultano pronti; eventuali modifiche effettuate nella revisione originale devono essere riapplicate prima della verifica.

La verifica richiede una sessione GPGAuth attiva e controlla nuovamente server, fingerprint, utente, sorgenti, destinazioni, formati, oggetti remoti e permessi. La GUI mostra operazioni gia riuscite, operazioni dimostrate come non applicate e conflitti. Soltanto un piano senza conflitti e senza azioni distruttive abilita la conferma esatta `RECUPERA N`. Dopo la ripresa, il journal viene chiuso con `batch_completed` e puo essere spostato nell'archivio locale. Anche un lotto troncato o corrotto puo essere archiviato esplicitamente come abbandonato, ma non puo essere verificato o ripreso automaticamente.

### File Excel protetti 0.12.5

Quando la fase 03 riconosce un documento Office `.xlsx` cifrato, apre un prompt con campo password mascherato e consente di mostrarne temporaneamente il contenuto durante l'inserimento. Una password errata riapre il prompt con un messaggio specifico; l'annullamento interrompe la revisione senza aprire il documento.

La decifratura avviene esclusivamente in un buffer di memoria. La password del documento resta disponibile soltanto nello stato volatile dell'app per rileggere lo stesso sorgente durante visualizzazione, modifica, controllo d'integrita, dry-run e importazione. Non viene inserita negli argomenti dei processi, nei log, nel JSON di risultato, nei file temporanei o nella richiesta inviata al bridge Passbolt. Una nuova revisione, un nuovo inventario o la chiusura dell'app eliminano la password dallo stato applicativo. Il supporto riguarda il formato moderno `.xlsx`; il formato legacy `.xls` continua a richiedere una conversione preventiva.

### Revisione modificabile e rilevamento IP 0.12.4

La fase 03 mantiene le password mascherate per impostazione predefinita, ma consente di mostrarle temporaneamente dopo una conferma esplicita e di correggere cliente, titolo, username, URL/host e password prima del dry-run. I metadati originali e quelli corretti restano distinti: il backend ricostruisce il candidato originale e verifica l'hash del file, mentre il piano e la risorsa Passbolt usano i valori corretti.

Se non è presente un URL o host esplicito, la revisione riconosce indirizzi IPv4 e IPv6 validi anche in etichette come `Indirizzo IP`, `IP address`, `IPv4` e `IPv6`, oppure incorporati in un altro campo non segreto. Un indirizzo che compare nel campo password non viene mai usato come host.

### Rilevamento automatico della fingerprint 0.12.1

La configurazione richiede soltanto l'URL HTTPS di Passbolt. L'app legge la fingerprint OpenPGP pubblicata da `/auth/verify.json`, la mostra in sola lettura e richiede una conferma esplicita prima di abilitare la fase successiva. Il rilevamento automatico non viene presentato come prova autonoma dell'identita del server: alla prima connessione il valore deve essere confrontato con quello comunicato dall'amministratore tramite un canale indipendente.

Dopo la conferma, la fingerprint resta in memoria per la sessione corrente e viene passata al bridge OpenPGP come valore atteso. Durante GPGAuth il bridge analizza la chiave pubblica effettiva, ne calcola la fingerprint e blocca il login se non coincide con il valore confermato. Il probe da riga di comando conserva invece la modalita con `-ExpectedFingerprint`, adatta alle verifiche automatizzate e al pinning preconfigurato.

### Sottocartelle condivise con permessi ereditati 0.12.0

La versione 0.12.0 completa la modalita **Cartelle per cliente nel contenitore scelto** anche quando il contenitore Passbolt e condiviso. Se la cartella del cliente non esiste, il dry-run ne pianifica la creazione v4 o v5 e copia in modo rigido l'intera maschera User/Group del contenitore. Non e presente un editor dei permessi: la nuova cartella deve ereditare esattamente i destinatari e i livelli Read, Update e Owner gia verificati sul genitore.

Il piano include l'identificatore e il percorso del contenitore, la maschera normalizzata, i gruppi espansi, le fingerprint dei destinatari, il formato della nuova cartella e l'eventuale chiave metadati condivisa. Una modifica a uno di questi elementi cambia il digest e obbliga a ripetere il dry-run prima di qualsiasi scrittura.

La creazione segue questo ordine:

1. crea la cartella personale con `POST /folders.json?contain[permission]=1`;
2. calcola la differenza fra il permesso Owner appena restituito e la maschera del contenitore;
3. applica la maschera con `PUT /share/folder/{id}.json`, come il client Passbolt ufficiale;
4. soltanto dopo la condivisione riuscita crea le risorse nella nuova cartella e applica a ciascuna la stessa maschera con il flusso risorse della versione 0.11, che comprende la simulazione prevista per le risorse.

I metadati di una nuova cartella v5 condivisa sono cifrati e firmati fin dalla creazione con la chiave metadati condivisa verificata. Se la chiave non e disponibile e il formato e **Automatico**, il piano puo ripiegare su v4 quando consentito dall'istanza; un formato v5 richiesto esplicitamente resta invece bloccato.

Se la cartella viene creata ma simulazione o applicazione dei permessi falliscono, il lotto si interrompe prima di creare risorse al suo interno. L'errore contiene l'ID della cartella e lo stato **creata ma non condivisa**; l'app non cancella automaticamente la cartella e richiede un nuovo dry-run per riconciliare lo stato remoto. Se al nuovo controllo una cartella omonima sotto il contenitore condiviso risulta ancora personale, il piano viene bloccato mostrando il suo ID: non viene mai riutilizzata automaticamente, per evitare che le risorse successive restino personali o che contenuti preesistenti vengano esposti involontariamente.

### Condivisioni e gruppi 0.11.0

La versione 0.11.0 consente di importare direttamente in una cartella Passbolt condivisa esistente e scrivibile, anche quando i permessi sono assegnati tramite gruppi. Il catalogo distingue le cartelle personali da quelle condivise e mostra, per ogni destinazione condivisa pronta, il numero di destinatari effettivi.

Il dry-run legge la maschera completa dei permessi della cartella e l'elenco degli utenti e gruppi condivisibili. Le appartenenze ai gruppi vengono espanse in utenti concreti, i destinatari sovrapposti vengono deduplicati e ogni chiave pubblica viene analizzata localmente verificando la corrispondenza con la fingerprint dichiarata da Passbolt. Una cartella condivisa non viene proposta se la composizione di un gruppo e incompleta, un destinatario non e attivo o una chiave pubblica manca, e scaduta oppure non supera la verifica.

La scrittura segue lo stesso ordine del client ufficiale Passbolt:

1. crea la risorsa con la copia del segreto cifrata per l'utente autenticato;
2. calcola la differenza fra il permesso iniziale Owner e la maschera della cartella;
3. invia soltanto i cambi di permesso a `POST /share/simulate/resource/{id}.json`;
4. usa gli utenti concreti restituiti dalla simulazione per cifrare e firmare una copia separata del segreto con ciascuna chiave pubblica;
5. applica permessi e segreti con `PUT /share/resource/{id}.json`.

Per una risorsa v5 condivisa, i metadati vengono cifrati fin dalla creazione con la chiave metadati condivisa verificata, anche quando l'istanza permette normalmente le chiavi personali. Una mappatura per cliente puo combinare radice, cartelle personali e cartelle condivise nello stesso lotto; il digest include maschere, destinatari, fingerprint e chiavi metadati effettive.

Passbolt non offre una transazione unica fra creazione e condivisione. Se la simulazione o l'applicazione dei permessi fallisce dopo la creazione, l'app identifica esplicitamente la risorsa come **creata ma non condivisa**, non la elimina automaticamente e impone un nuovo dry-run per riconciliare lo stato. La limitazione storica della 0.11 sulla creazione di sottocartelle dentro contenitori condivisi e stata rimossa dalla versione 0.12.

### Sessione autenticata per il workflow 0.10.0

La versione 0.10.0 richiede chiave privata, passphrase e MFA una sola volta all'inizio della fase di importazione. Il pulsante **Avvia sessione** apre una sessione locale persistente: il bridge OpenPGP mantiene esclusivamente in memoria la chiave privata decifrata, l'identita verificata e i cookie Passbolt ottenuti con GPGAuth e TOTP. I campi passphrase e MFA vengono cancellati subito dopo il tentativo di apertura e i valori non vengono salvati, registrati o inseriti negli argomenti dei processi.

Dry-run e scritture successive riutilizzano la stessa sessione senza memorizzare o riprodurre il codice TOTP. Prima di ogni operazione l'app verifica nuovamente `/users/me.json`, l'identita autenticata e lo stato MFA. Se Passbolt ha fatto scadere la sessione o l'autorizzazione MFA, il workflow viene bloccato e deve essere aperta una nuova sessione con un codice corrente.

La sessione viene chiusa e ripulita:

- con il pulsante **Chiudi sessione**;
- alla chiusura dell'app;
- se cambia l'URL Passbolt o la cartella sorgente;
- dopo 30 minuti senza dry-run o importazioni;
- se l'identita cambia o Passbolt dichiara scaduta la sessione/MFA.

Una sessione valida puo essere riutilizzata per piu lotti provenienti dalla stessa cartella sorgente. Ogni lotto conserva comunque il proprio dry-run, la propria frase `IMPORTA N` e la seconda conferma esplicita. I documenti sorgenti vengono nuovamente verificati e i segreti vengono estratti soltanto immediatamente prima di ogni scrittura.

### Mappatura distinta per cliente 0.9.0

La versione 0.9.0 aggiunge la modalita **Mappatura distinta per ogni cliente**. Dopo che il primo dry-run autenticato ha caricato il catalogo delle cartelle Passbolt, il pulsante **Mappa clienti** apre una finestra che elenca una sola volta ogni cliente presente nel lotto. Per ciascun cliente deve essere scelta esplicitamente una cartella Passbolt esistente e scrivibile, personale o condivisa, oppure la radice personale.

Le risorse vengono create direttamente nella destinazione associata al cliente; questa modalita non crea cartelle e non modifica o sposta risorse esistenti. Due clienti possono essere associati alla stessa cartella, mentre un cliente puo essere associato alla radice. Le cartelle con permesso Read non vengono proposte. Dalla versione 0.11, una cartella condivisa viene proposta soltanto quando tutti i destinatari e le relative chiavi pubbliche sono verificabili. Una mappatura incompleta, una cartella non piu disponibile o un permesso non piu sufficiente blocca il piano senza scritture.

La mappatura viene normalizzata per cliente, ordinata in modo deterministico e inclusa nel digest del dry-run insieme al `folder_parent_id` effettivo di ogni candidato. Se una destinazione cambia, il piano viene invalidato e il dry-run deve essere ripetuto nella sessione autenticata attiva. Al momento dell'importazione il server viene interrogato nuovamente e la mappatura deve produrre esattamente lo stesso digest.

### Selezione della cartella Passbolt 0.8.0

La versione 0.8.0 consente di scegliere una cartella Passbolt esistente come destinazione. Il primo dry-run autenticato legge le cartelle accessibili all'utente, decifra localmente i nomi v5 e restituisce alla UI un catalogo ordinato per percorso, per esempio `Clienti / Cliente Alfa`. Sono proposte come destinazioni soltanto le cartelle per cui Passbolt dichiara il permesso Update o Owner; se il server non restituisce il dettaglio del permesso, la richiesta di creazione resta comunque soggetta al controllo autorizzativo del server. Nessun nome decifrato viene salvato su disco.

Sono disponibili tre modalita:

- **Cartelle per cliente nel contenitore scelto**: la cartella Passbolt selezionata diventa il genitore comune. Per esempio, scegliendo `Clienti`, il cliente `Cliente Alfa` viene riutilizzato o creato come `Clienti / Cliente Alfa`. Se si lascia selezionata la radice, il comportamento resta quello della versione 0.7;
- **Direttamente nella cartella scelta**: tutte le risorse selezionate vengono create nella cartella Passbolt esistente, senza creare una sottocartella per cliente;
- **Radice personale Passbolt**: tutte le risorse vengono create nella radice personale.

Dopo il primo dry-run, cambiare modalita o cartella invalida il piano. Il secondo dry-run riutilizza la sessione autenticata attiva, senza richiedere nuovamente passphrase o TOTP. L'identificatore della cartella selezionata, il percorso di destinazione, le cartelle figlie da creare e ogni `folder_parent_id` entrano nel digest ricontrollato prima della scrittura.

### Cartelle e destinazioni 0.7.0

La versione 0.7.0 conserva la struttura per cliente durante l'importazione. La destinazione predefinita e **Cartelle per cliente**: per ogni cartella sorgente di primo livello il dry-run cerca una cartella personale Passbolt omonima alla radice; se ne trova una sola la riutilizza, altrimenti ne pianifica la creazione. I candidati provenienti direttamente dalla radice sorgente restano nella radice Passbolt. In alternativa l'utente puo scegliere **Radice personale Passbolt** per non creare cartelle.

Il formato delle nuove cartelle puo essere **Automatico**, **v4** o **v5**. Automatico segue `default_folder_type` e i flag `allow_creation_of_v4_folders` / `allow_creation_of_v5_folders`. Una cartella v4 invia il nome in chiaro; una cartella v5 cifra e firma localmente un documento `PASSBOLT_FOLDER_METADATA`. Le cartelle esistenti v5 vengono decifrate soltanto in memoria per ricostruirne il nome. Formato, chiave metadati, cartelle da creare o riutilizzare e `folder_parent_id` di ogni risorsa fanno parte del digest del piano e vengono ricontrollati prima della scrittura.

Il confronto duplicati distingue tre casi: un duplicato esatto gia nella destinazione viene saltato, un duplicato interno allo stesso lotto e alla stessa destinazione viene saltato, mentre una credenziale uguale trovata in una cartella diversa blocca il piano. L'app non sposta risorse e non sceglie implicitamente una destinazione diversa.

### Risorse v4 e v5 0.7.0

La versione 0.7.0 crea risorse password sia v4 sia v5. Nella schermata di importazione il formato puo essere impostato su **Automatico**, **v4** o **v5**. Automatico segue `default_resource_types` comunicato dall'istanza e, se il formato v5 predefinito non e utilizzabile ma il server consente v4, ripiega in modo esplicito su v4. Il formato effettivamente scelto, il tipo di risorsa e l'eventuale chiave metadati entrano nel digest del dry-run e vengono ricontrollati prima della scrittura.

Per v5 nome, username, URL e nota vengono inseriti nel documento `PASSBOLT_RESOURCE_METADATA` e cifrati localmente. La password e la parte segreta della nota vengono inserite in `PASSBOLT_SECRET_DATA` quando il tipo usa un segreto JSON; i tipi `password-string` conservano invece il segreto come stringa e la nota nella posizione prevista dal relativo schema. L'app usa la chiave personale quando le impostazioni lo consentono, altrimenti recupera la copia della chiave metadati condivisa destinata all'utente, ne verifica firma, dominio, fingerprint e corrispondenza fra parte pubblica e privata, e la mantiene soltanto in memoria per la durata dell'operazione.

### Supporto MFA TOTP 0.5.0

La versione 0.5.0 completa l'autenticazione degli account protetti da MFA TOTP. Dopo GPGAuth, l'app riconosce la sfida MFA, invia una sola volta il codice a 6 cifre a `POST /mfa/verify/totp.json`, acquisisce il cookie temporaneo `passbolt_mfa` e ripete la richiesta originale nella stessa sessione. Il codice e mascherato nella UI, non viene salvato, non compare negli argomenti dei processi o nei log e viene cancellato dal campo subito dopo ogni operazione. Dalla versione 0.18.1 il client non richiede alcuna persistenza `remember` e invia il solo campo TOTP documentato.

### Correzione 0.4.2

La versione 0.4.2 segue i redirect HTTP che rimangono sulla stessa origine HTTPS dell'istanza Passbolt, come il client ufficiale. La correzione gestisce il `302` che alcune configurazioni restituiscono dopo GPGAuth durante la lettura di `/users/me.json`, conserva i cookie impostati lungo il redirect e riconosce l'eventuale risposta MFA finale. I redirect verso un altro host, protocollo o porta vengono sempre rifiutati, le credenziali non vengono inoltrate fuori dall'istanza e il numero di passaggi e limitato.

### Correzione 0.4.1

La versione 0.4.1 corregge la decodifica degli header GPGAuth prodotti con semantica `application/x-www-form-urlencoded`: il carattere `+` viene convertito in spazio prima della decodifica percentuale, mentre i `+` reali del contenuto base64, codificati come `%2B`, vengono preservati. Senza questa distinzione l'header poteva iniziare con `-----BEGIN+PGP+MESSAGE-----` e veniva rifiutato come messaggio OpenPGP non valido anche se chiave e passphrase erano corrette.

## 01 — Preparazione locale

- permette di scegliere la cartella principale dei documenti clienti;
- valida localmente l'eventuale URL HTTPS pianificato, senza contattare Passbolt;
- abilita inventario e revisione quando la cartella è valida, anche se Passbolt non è disponibile;
- salva nei progetti soltanto l'origine pianificata, mai fingerprint, fiducia o stato di sessione.

## 02 — Inventario file

- considera ogni cartella di primo livello come un cliente;
- elenca i file supportati usando esclusivamente metadati del filesystem;
- mostra percorso relativo, formato, categoria, dimensione e data di modifica;
- filtra per cliente, formato o testo nel percorso;
- consente la selezione multipla con `Ctrl` o `Maiusc`;
- segnala file ignorati, percorsi non accessibili e collegamenti a file o cartelle;
- esporta il report completo in CSV UTF-8 compatibile con Excel.

I nomi file che iniziano con caratteri interpretabili come formule vengono neutralizzati nell'export CSV.

## 03 — Revisione controllata

La revisione apre il contenuto **soltanto dei file selezionati dall'utente** e soltanto dopo una conferma esplicita. L'elaborazione avviene localmente.

La fase:

- riconosce campi comuni in italiano e inglese, come titolo, username, password, URL, host e indirizzi IP;
- riconosce anche chiavi di configurazione con prefisso, per esempio `DB_USERNAME`, `DB_PASSWORD` e `DB_HOST`;
- mostra i candidati come **Pronti** o **Da completare**;
- permette di filtrare per stato e cercare in cliente, titolo, username, URL e origine;
- mostra per impostazione predefinita una maschera fissa al posto della password e soltanto la sua lunghezza;
- riconosce i file `.xlsx` cifrati e richiede la password del documento soltanto quando necessaria;
- consente, dopo conferma esplicita, di mostrare o nascondere temporaneamente le password;
- consente di modificare cliente, titolo, username, URL/host e password, ricalcolando lo stato del candidato e invalidando un eventuale piano precedente;
- calcola l'hash SHA-256 del documento sorgente, tenuto in memoria, per poter rilevare future modifiche prima dell'importazione;
- consente di selezionare tutti i candidati **Pronti** necessari, senza un tetto numerico applicativo per il lotto di importazione;
- non crea risorse in Passbolt durante la revisione.

La password in chiaro può essere presente temporaneamente nella memoria locale durante il riconoscimento, la visualizzazione esplicita, la modifica o l'importazione, ma:

- non viene restituita dal backend di revisione ordinario alla UI e non viene inclusa nel relativo JSON;
- viene restituita dal gate di importazione alla UI soltanto per l'azione esplicita di visualizzazione o modifica, attraverso input/output standard reindirizzati localmente;
- non viene scritta nel registro attività;
- non viene salvata in file temporanei o report;
- viene nuovamente mascherata e rimossa dalla UI quando l'utente disattiva la visualizzazione o cambia fase; una password corretta manualmente resta in memoria fino all'importazione o alla chiusura.

La password usata per aprire un `.xlsx` protetto è distinta dalle credenziali contenute nel foglio. Viene passata soltanto ai parser locali attraverso input standard reindirizzato, riutilizzata per i controlli successivi e rimossa dallo stato alla nuova revisione, al nuovo inventario o alla chiusura. Il documento decifrato non viene mai scritto su disco.

## 04 — Importazione controllata

La fase 04 implementa un'importazione Passbolt v4 condizionata da un dry-run autenticato. Autenticazione, verifiche e scrittura restano operazioni distinte, ma dry-run e importazione condividono una sola sessione protetta in memoria. Formati `auto` e v5 vengono rifiutati prima della pianificazione.

### Dry-run autenticato, senza scritture

1. L'utente seleziona soltanto candidati con stato **Pronto**.
2. L'utente verifica l'URL HTTPS nella fase 04, confronta la fingerprint rilevata con una fonte indipendente e la conferma; un cambio di URL invalida conferma, sessione e piano.
3. L'utente seleziona il file della propria chiave privata OpenPGP, inserisce la passphrase e, se l'account lo richiede, il codice MFA TOTP a 6 cifre, quindi usa **Avvia sessione**. Il bridge locale verifica la chiave del server contro la fingerprint appena confermata, esegue GPGAuth, completa TOTP nella stessa sessione e controlla che la chiave privata corrisponda all'identita Passbolt autenticata. Passphrase e TOTP vengono immediatamente rimossi dalla richiesta e dai campi UI.
4. Per ogni dry-run l'app ricalcola SHA-256 e ricostruisce i candidati dai documenti usando i metadati originali della revisione. Se un documento o il record sono cambiati, il flusso si interrompe; le correzioni effettuate nell'editor restano separate e vengono usate nel piano.
5. L'app verifica che la sessione e l'identita siano ancora valide, quindi legge impostazioni, cartelle, maschere dei permessi, utenti, gruppi, chiavi pubbliche, tipi di risorsa e metadati v4 delle risorse accessibili all'utente. Capability o oggetti v5 bloccano il percorso fail-closed.
6. Il catalogo delle cartelle viene mostrato nella UI. Se l'utente cambia contenitore, destinazione diretta, modalita oppure una singola associazione cliente-cartella, il piano appena prodotto viene invalidato e il dry-run deve essere ripetuto nella stessa sessione.
7. Viene costruito il mapping cliente-destinazione con cartelle **Da creare**, **Da creare e condividere con permessi ereditati**, **Esistenti da riutilizzare**, **Mappate per cliente**, **Cartella diretta** oppure **Radice Passbolt**.
8. Viene costruito un piano con risorse **Da creare**, **Gia nella destinazione**, **Duplicate nel lotto** o **Presenti altrove - bloccate**. Un duplicato esatto richiede uguaglianza di titolo, username e URL/host, ignorando soltanto maiuscole/minuscole e spazi esterni. La password non viene decifrata dal server e non partecipa al confronto.
9. Nessuna cartella o risorsa viene creata o modificata durante il dry-run. La sessione resta attiva in memoria per la scrittura o per un altro dry-run.

La passphrase e il codice TOTP vengono cancellati dai campi subito dopo l'apertura della sessione e non devono essere reinseriti per la scrittura. Il TOTP non viene conservato ne riprodotto: viene conservata soltanto l'autorizzazione MFA rappresentata dal cookie di sessione emesso da Passbolt.

Non copiare mai la chiave privata, la passphrase o codici MFA nella cartella del progetto. La chiave puo essere selezionata dalla sua posizione protetta tramite la finestra dell'app; passphrase e TOTP devono essere digitati nell'interfaccia e non salvati in un file. I formati di chiave OpenPGP `.asc`, `.gpg` e `.pgp` sono esclusi dal controllo versione come ulteriore protezione, ma questa esclusione non sostituisce una corretta custodia dei segreti.

### Scrittura confermata

Il pulsante di importazione si abilita soltanto se:

- il dry-run è riuscito;
- la stessa sessione autenticata usata per il dry-run e ancora attiva e associata alla stessa cartella sorgente;
- l'istanza è attestata come Passbolt v4 e consente il formato v4 richiesto esplicitamente;
- per la destinazione per cliente, l'istanza consente il formato cartella richiesto e tutte le cartelle esistenti necessarie sono leggibili senza ambiguita;
- è disponibile un tipo password v4 compatibile: `password-and-description` oppure `password-string`;
- il confronto duplicati è completo;
- nessun duplicato esatto è stato trovato fuori dalla destinazione prevista;
- Passbolt ha fornito un token CSRF;
- l'utente ha digitato la frase `IMPORTA N`, dove `N` è il numero esatto di nuove risorse;
- l'utente accetta una seconda finestra di conferma.

Subito prima della scrittura, la validita della sessione viene ricontrollata e i sorgenti vengono nuovamente aperti e verificati. Le nuove cartelle vengono create per prime con `POST /folders.json`; se devono ereditare una condivisione, la relativa simulazione e applicazione devono riuscire prima che il loro identificatore venga usato come `folder_parent_id` nelle risorse. Le password non modificate vengono estratte dai sorgenti soltanto in quel momento; quelle corrette nella fase 03 sono mantenute esclusivamente in memoria. Entrambe vengono passate al bridge OpenPGP persistente tramite input standard e cifrate localmente con la chiave pubblica dell'utente; il messaggio cifrato viene anche firmato con la chiave privata. Per una destinazione condivisa, dopo la simulazione viene prodotta una copia cifrata e firmata per ogni nuovo destinatario concreto indicato da Passbolt. Per cartelle e risorse v5 anche i metadati vengono cifrati e firmati localmente. Chiave, passphrase, TOTP e password non sono inseriti negli argomenti dei processi, nelle variabili d'ambiente, nei log o nei file temporanei. La sessione resta attiva dopo un'importazione riuscita, cosi puo essere usata per il lotto successivo.

Le creazioni sono sequenziali e Passbolt non espone una transazione unica per l'intero lotto. Se una richiesta fallisce dopo alcune creazioni, l'app mostra separatamente cartelle e risorse gia create, non elimina automaticamente nulla e obbliga a ripetere il dry-run: il nuovo confronto riutilizza le cartelle riuscite e riconcilia le risorse riuscite come duplicati.

### Limiti attuali dell'importazione

- nessun massimo numerico applicativo di candidati per lotto; la capacità effettiva dipende dalla memoria, dai messaggi locali e dall'istanza Passbolt;
- massimo 65.536 caratteri per password;
- supporto alla creazione di risorse password v4 nei due tipi compatibili elencati sopra;
- supporto a cartelle personali e condivise v4 sotto la radice o sotto il contenitore scelto, riutilizzate per nome univoco o create prima delle risorse;
- supporto a un contenitore Passbolt esistente comune oppure a una cartella esistente usata come destinazione diretta;
- supporto alla mappatura distinta di ogni cliente del lotto verso una cartella personale o condivisa esistente e scrivibile oppure verso la radice personale;
- supporto alle cartelle condivise esistenti con permessi User e Group Read, Update e Owner, simulazione preventiva e cifratura separata per ogni destinatario concreto;
- le nuove sottocartelle cliente dentro un contenitore condiviso ereditano obbligatoriamente la sua maschera completa; non e possibile modificarla durante la creazione;
- una sottocartella omonima ma personale trovata dentro un contenitore condiviso blocca il piano e deve essere verificata in Passbolt prima di continuare;
- se il server espone plugin, endpoint o resource type v5, la sessione viene chiusa e nessuna funzione di importazione o ACL diventa disponibile;
- gli account con MFA TOTP sono supportati; provider diversi da TOTP vengono riconosciuti ma interrompono il flusso senza scritture;
- vengono confrontate soltanto le cartelle e le risorse che l'identità autenticata può leggere;
- la versione 0.12 non sposta risorse esistenti, non crea o modifica gruppi e non consente di disegnare nuove maschere di condivisione: riutilizza o eredita esclusivamente la maschera di una cartella condivisa esistente e verificata.

## Formati riconosciuti

L'inventario riconosce:

```text
.txt .csv .tsv .json .xml .yaml .yml .ini .cfg .conf
.env .properties .docx .xlsx .xls .pdf
```

La revisione locale supporta gli stessi formati con una limitazione: i vecchi file `.xls` vengono segnalati e devono essere salvati come `.xlsx`. L'app non esegue conversioni automatiche.

Per i file YAML viene riconosciuta la sintassi semplice `chiave: valore`; non viene eseguito un parser YAML capace di creare oggetti o richiamare codice.

## Limiti di sicurezza della revisione

Ogni sessione di revisione non impone un massimo numerico di file selezionati o di candidati complessivi. Applica comunque questi limiti di sicurezza:

- massimo 20 MB per file;
- massimo 100 MB non compressi per un documento Office;
- massimo 5.000 record per file;
- massimo 200 pagine per PDF;
- nessuna apertura di collegamenti simbolici a file;
- nessun percorso esterno alla cartella clienti configurata;
- rifiuto degli XML contenenti DTD o dichiarazioni di entità;
- nessuna esecuzione di macro, formule Excel, script o collegamenti Office esterni.

I documenti Office vengono aperti in modalità di lettura. Le formule presenti in XLSX non vengono calcolate né eseguite. Per gli XLSX protetti, anche il contenuto decifrato resta esclusivamente in memoria; i file legacy XLS non sono aperti.

## Verifica preliminare delle API

Il controllo di connessione esegue esclusivamente richieste pubbliche e in sola lettura verso:

- `GET /healthcheck/status.json`
- `GET /auth/verify.json`

L'applicazione non contiene URL o fingerprint preconfigurati. Nella GUI la fingerprint OpenPGP viene rilevata automaticamente, mostrata in sola lettura e confermata dall'utente. Alla prima connessione deve essere confrontata con quella letta direttamente dalla configurazione di Passbolt o comunicata dall'amministratore attraverso un canale indipendente.

Una volta confermata, la fingerprint viene usata come pin per la sessione corrente. Se la chiave effettiva ricevuta durante GPGAuth non coincide, il programma termina con errore. Non modificare il controllo per ignorare la differenza finché la rotazione della chiave non è stata confermata.

Il dry-run della fase 04 usa inoltre questi endpoint autenticati, tutti in lettura:

- `GET /users/me.json`
- `GET /settings.json`
- `GET /metadata/types/settings.json` quando disponibile
- `GET /metadata/keys/settings.json` quando serve il supporto v5
- `GET /metadata/keys.json?contain[metadata_private_keys]=1` quando servono chiavi metadati condivise o il confronto di risorse v5
- `GET /resource-types.json`
- `GET /resources.json`
- `GET /folders.json?contain[permission]=1&contain[permissions]=1&contain[permissions.user.profile]=1&contain[permissions.group]=1`
- `GET /share/search-aros.json?contain[gpgkey]=1&contain[groups_users]=1`

L'autenticazione usa gli endpoint GPGAuth `/auth/verify.json` e `/auth/login.json`. Se Passbolt richiede TOTP, viene usato `POST /mfa/verify/totp.json` con il solo campo `totp`; i cookie `passbolt_session`, `passbolt_mfa` e CSRF restano soltanto nella sessione del bridge in memoria. La scrittura usa `POST /folders.json` e `POST /resources.json` soltanto dopo tutte le conferme descritte sopra. Per una destinazione condivisa usa inoltre `PUT /share/folder/{id}.json` per le cartelle, secondo il flusso del client Passbolt ufficiale, quindi `POST /share/simulate/resource/{id}.json` e `PUT /share/resource/{id}.json` per le risorse. La condivisione delle risorse viene applicata soltanto dopo una simulazione riuscita. `POST /auth/logout.json` viene tentato alla chiusura esplicita, automatica o finale della sessione.

JWT è il metodo indicato come preferenziale dalla documentazione Passbolt recente. La versione 0.17.0 usa GPGAuth con MFA TOTP per compatibilità con l'istanza verificata; il codice mantiene il pinning della fingerprint dopo la conferma e verifica crittograficamente le sfide di entrambi i lati. Il supporto ad altri provider MFA è intenzionalmente fuori dallo scope corrente.

Per eseguire soltanto il controllo da riga di comando:

```powershell
.\run_passbolt_probe.ps1 `
  -BaseUrl "https://passbolt.example.com" `
  -ExpectedFingerprint "0123456789ABCDEF0123456789ABCDEF01234567"
```

## Controlli per lo sviluppo

I parser locali, incluso il supporto Office cifrato, sono bloccati in `requirements.txt`. Il bridge OpenPGP usa `openpgp` 6.3.1. Dopo un nuovo clone, installare le dipendenze Python e, se manca `node_modules`, la dipendenza Node bloccata dal lockfile senza eseguire script di pacchetto:

```powershell
python -m pip install --requirement .\requirements.txt
pnpm install --frozen-lockfile --ignore-scripts
```

I backend e la UI espongono self-test locali:

```powershell
python -m pip install --requirement requirements-test.txt
.\run_tests.ps1
```

`test_passbolt_crypto.mjs` avvia un server simulato soltanto su `127.0.0.1` e verifica end-to-end GPGAuth stage 0/1/2, redirect interni, blocco dei redirect esterni, TOTP mancante, TOTP rifiutato, TOTP valido, cookie di sessione e MFA, riuso della sessione per due dry-run senza un secondo login o un secondo TOTP, CSRF, piano duplicati v4/v5, chiave metadati personale, chiave metadati condivisa verificata, catalogo gerarchico delle cartelle, contenitore padre selezionato, destinazione diretta, mappature distinte v4/v5, destinazione radice per singolo cliente, rifiuto delle destinazioni incomplete o in sola lettura, lettura e creazione cartelle v4/v5, ereditarieta User/Group per nuove sottocartelle condivise, digest della maschera, applicazione diretta dei permessi cartella, simulazione prima della condivisione delle risorse, chiave condivisa per i metadati v5, assegnazione di `folder_parent_id`, envelope di intenzione/esito/completamento privi di segreti, classificazione autenticata del recupero, blocco dei conflitti, ripresa di richieste non applicate, blocco dei duplicati presenti altrove, riconciliazione dei fallimenti parziali e creazione risorse v4/v5 con segreti e metadati OpenPGP cifrati. Non contatta l'istanza Passbolt reale.

È possibile creare un inventario JSON o un report CSV anche da riga di comando:

```powershell
python .\passbolt_app.py --inventory "C:\Documenti\Clienti" --json
python .\passbolt_app.py --inventory "C:\Documenti\Clienti" --csv ".\inventario.csv" --json
```

Una revisione mascherata può essere eseguita indicando esclusivamente percorsi relativi alla radice:

```powershell
python .\passbolt_review.py `
  --root "C:\Documenti\Clienti" `
  --file "Cliente Alfa\accessi.xlsx" `
  --file "Cliente Beta\server.txt" `
  --json
```

## Registro e recupero della versione 0.13

La versione 0.13 introduce `passbolt_reconciliation.py`, il componente di persistenza, e lo collega alle operazioni reali della fase 04: dopo un dry-run valido, Python crea il registro prima di consegnare le risorse al bridge Node e passa al bridge soltanto l'UUID del lotto. Il protocollo persistente esegue verifica autenticata e ripresa idempotente; l'interfaccia espone selezione dei lotti, associazione dei sorgenti, riepilogo del piano, conferma esatta e archiviazione per l'operatore.

Ogni lotto usa un file `batch-<UUID>.jsonl` sotto `%LOCALAPPDATA%\Passbolt Migration Assistant\Reconciliation`. Il primo evento lega il registro a versione dell'app, origine e fingerprint del server, hash dell'identita Passbolt, digest del piano, formati, destinazione, eventuale hash della mappatura cliente/cartella, modalità e hash della configurazione permessi. Per i lotti piccoli include anche le coppie `candidate_id`/SHA-256 del sorgente; per i lotti estesi queste prove vengono concatenate in eventi `candidate_manifest` da massimo 200 elementi, senza imporre un massimo numerico al lotto. Gli eventi operativi successivi possono contenere soltanto intenzioni, hash della destinazione e della maschera di permessi prevista, ID remoti, stati di creazione e condivisione, contatori e codici di errore tecnici. Non sono ammessi titolo, username, URL delle credenziali, percorsi dei documenti, password, password Excel, chiavi, passphrase, MFA, cookie o identificatori di sessione.

Ogni riga contiene numero di sequenza, timestamp UTC, hash della riga precedente e hash SHA-256 del record corrente. La scrittura viene sincronizzata prima di confermare l'append. Node emette `operation_intent` subito prima delle richieste irreversibili e un evento di esito dopo la risposta; Python consuma questi envelope internamente, quindi il protocollo WPF continua a ricevere un solo documento `{ok,result|error}` per comando. Soltanto dopo `batch_completed` Python accetta un esito finale riuscito. Una riga finale parziale non viene considerata un evento riuscito, marca il lotto come da verificare e blocca nuove scritture; un errore o un'alterazione in una riga interna rende il registro non fidato. Un lotto concluso diventa immutabile. La catena SHA-256 rileva corruzioni e modifiche non coerenti, ma non e una firma digitale: per questo il recupero non si basa mai sul solo contenuto del file.

Se la persistenza di un evento fallisce o il bridge si interrompe, il lotto conserva gli eventi gia sincronizzati e l'esito finale contiene l'UUID con stato `verification_required`. I comandi `session-recovery-readiness` e `session-recovery-import` riusano una sessione Passbolt autenticata. Python apre il lotto soltanto tramite UUID nella directory applicativa, verifica nuovamente gli SHA-256 dei documenti, confronta origine, fingerprint e hash dell'utente e impone gli stessi formati e la stessa destinazione. Per la modalita `client_mapping` viene confrontato anche l'hash dell'intera mappatura, senza salvare i nomi dei clienti.

Node rilegge cartelle, risorse e permessi e classifica ogni intenzione storica. Una creazione incerta puo diventare `remote_success` soltanto se esiste un unico oggetto esatto nella destinazione prevista; puo diventare `not_applied` se l'oggetto e ancora assente. Un esito gia registrato come riuscito non viene mai ricreato se l'oggetto scompare. Una condivisione puo essere ripetuta soltanto se la maschera prevista coincide ancora con quella del piano e l'oggetto conserva esattamente il solo permesso proprietario; ACL incomplete o parzialmente mutate sono conflitti. Le verifiche vengono registrate come `operation_verified`, quindi chiuse da `recovery_verified` con UUID e digest. L'applicazione deve presentare lo stesso UUID e digest nella medesima sessione; prima della scrittura lo stato remoto viene analizzato di nuovo.

La ripresa puo creare contenuti mancanti e completare condivisioni non applicate, riestraendo il segreto soltanto per le risorse che devono essere create o ricifrate per i destinatari. Non pianifica mai cancellazioni, spostamenti o sovrascritture. Duplicati multipli, oggetti in una destinazione diversa, variazioni della ACL, identita o sorgenti non corrispondenti, journal corrotti o code troncate bloccano il piano e richiedono una verifica manuale.

I comandi locali `--reconciliation-list`, `--reconciliation-describe` e `--reconciliation-archive` mantengono la GUI separata dai percorsi fisici. L'archiviazione richiede UUID canonico, stato atteso, conferma esatta e lease esclusivo, quindi sposta il journal sotto `%LOCALAPPDATA%\Passbolt Migration Assistant\Reconciliation\Archive\<stato>` senza cancellarlo. La versione 0.16.0 ha aggiunto `--acl-reconciliation-list` e il journal ACL; la 0.17.0 estende lo stesso protocollo a piani misti e restrittivi; la 0.18.0 completa la gestione locale con `--acl-reconciliation-describe`, `--acl-reconciliation-archive`, filtri e dettagli sicuri nella GUI; la 0.19.0 fornisce il runner e il report della matrice reale v4/v5; la 0.23.0 esegue nel laboratorio sintetico i nove scenari mutativi di entrambi i profili senza attestarli come prove reali; la 0.24.0 aggiunge la copertura post-commit `remote_success` senza riscrittura; la 0.25.0 completa lo stesso percorso per la creazione cartella e riusa la destinazione verificata senza duplicarla; la 0.26.0 estende le stesse garanzie alle disconnessioni prive di stato HTTP; la 0.27.0 lega profili locali privi di segreti a revisione, rilettura e piano; la 0.28.0 aggiunge progetti di preparazione DPAPI senza persistere trust, sessione o valori sorgente. Il prossimo gate eseguirà tutti i sedici scenari sulle due istanze Passbolt dedicate prima della preparazione della distribuzione Windows. La composizione dei gruppi e gli altri provider MFA restano fuori dallo scope corrente.
