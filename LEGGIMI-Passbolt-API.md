# Passbolt Migration Assistant

Applicazione desktop locale per preparare in modo controllato la migrazione delle credenziali dai documenti aziendali a Passbolt.

## Avvio dell'app

Aprire PowerShell nella cartella del progetto ed eseguire:

```powershell
.\run_passbolt_app.ps1
```

La versione `0.12.2` usa un'interfaccia nativa Windows (WPF) e comprende quattro fasi operative.

### Rilevamento automatico della fingerprint 0.12.1

La configurazione richiede soltanto l'URL HTTPS di Passbolt. L'app legge la fingerprint OpenPGP pubblicata da `/auth/verify.json`, la mostra in sola lettura e richiede una conferma esplicita prima di abilitare la fase successiva. Il rilevamento automatico non viene presentato come prova autonoma dell'identita del server: alla prima connessione il valore deve essere confrontato con quello comunicato dall'amministratore tramite un canale indipendente.

Dopo la conferma, la fingerprint resta in memoria per la sessione corrente e viene passata al bridge OpenPGP come valore atteso. Durante GPGAuth il bridge analizza la chiave pubblica effettiva, ne calcola la fingerprint e blocca il login se non coincide con il valore confermato. Il probe da riga di comando conserva invece la modalita con `-ExpectedFingerprint`, adatta alle verifiche automatizzate e al pinning preconfigurato.

### Sottocartelle condivise con permessi ereditati 0.12.0

La versione 0.12.0 completa la modalita **Cartelle per cliente nel contenitore scelto** anche quando il contenitore Passbolt e condiviso. Se la cartella del cliente non esiste, il dry-run ne pianifica la creazione v4 o v5 e copia in modo rigido l'intera maschera User/Group del contenitore. Non e presente un editor dei permessi: la nuova cartella deve ereditare esattamente i destinatari e i livelli Read, Update e Owner gia verificati sul genitore.

Il piano include l'identificatore e il percorso del contenitore, la maschera normalizzata, i gruppi espansi, le fingerprint dei destinatari, il formato della nuova cartella e l'eventuale chiave metadati condivisa. Una modifica a uno di questi elementi cambia il digest e obbliga a ripetere il dry-run prima di qualsiasi scrittura.

La creazione segue questo ordine:

1. crea la cartella personale con `POST /folders.json?contain[permission]=1`;
2. calcola la differenza fra il permesso Owner appena restituito e la maschera del contenitore;
3. simula i cambi con `POST /share/simulate/folder/{id}.json` e verifica che gli utenti concreti restituiti appartengano al piano;
4. applica la maschera con `PUT /share/folder/{id}.json`;
5. soltanto dopo la condivisione riuscita crea le risorse nella nuova cartella e applica a ciascuna la stessa maschera con il flusso risorse della versione 0.11.

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

La versione 0.5.0 completa l'autenticazione degli account protetti da MFA TOTP. Dopo GPGAuth, l'app riconosce la sfida MFA, invia una sola volta il codice a 6 cifre a `POST /mfa/verify/totp.json`, acquisisce il cookie temporaneo `passbolt_mfa` e ripete la richiesta originale nella stessa sessione. Il codice e mascherato nella UI, non viene salvato, non compare negli argomenti dei processi o nei log e viene cancellato dal campo subito dopo ogni operazione. L'opzione persistente `remember` resta disattivata.

### Correzione 0.4.2

La versione 0.4.2 segue i redirect HTTP che rimangono sulla stessa origine HTTPS dell'istanza Passbolt, come il client ufficiale. La correzione gestisce il `302` che alcune configurazioni restituiscono dopo GPGAuth durante la lettura di `/users/me.json`, conserva i cookie impostati lungo il redirect e riconosce l'eventuale risposta MFA finale. I redirect verso un altro host, protocollo o porta vengono sempre rifiutati, le credenziali non vengono inoltrate fuori dall'istanza e il numero di passaggi e limitato.

### Correzione 0.4.1

La versione 0.4.1 corregge la decodifica degli header GPGAuth prodotti con semantica `application/x-www-form-urlencoded`: il carattere `+` viene convertito in spazio prima della decodifica percentuale, mentre i `+` reali del contenuto base64, codificati come `%2B`, vengono preservati. Senza questa distinzione l'header poteva iniziare con `-----BEGIN+PGP+MESSAGE-----` e veniva rifiutato come messaggio OpenPGP non valido anche se chiave e passphrase erano corrette.

## 01 — Configurazione

- verifica che l'URL Passbolt usi HTTPS;
- controlla healthcheck e TLS, rileva la fingerprint pubblica del server e ne richiede la conferma;
- permette di scegliere la cartella principale dei documenti clienti;
- abilita la fase successiva solo quando connessione e cartella sono valide.

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

- riconosce campi comuni in italiano e inglese, come titolo, username, password, URL e host;
- riconosce anche chiavi di configurazione con prefisso, per esempio `DB_USERNAME`, `DB_PASSWORD` e `DB_HOST`;
- mostra i candidati come **Pronti** o **Da completare**;
- permette di filtrare per stato e cercare in cliente, titolo, username, URL e origine;
- mostra una maschera fissa al posto della password e soltanto la sua lunghezza;
- calcola l'hash SHA-256 del documento sorgente, tenuto in memoria, per poter rilevare future modifiche prima dell'importazione;
- consente di selezionare fino a 25 candidati **Pronti** per il lotto di importazione;
- non crea risorse in Passbolt durante la revisione.

La password in chiaro può essere presente temporaneamente nella memoria del processo Python durante il riconoscimento, ma:

- non viene restituita dal backend alla UI;
- non viene inclusa nel JSON;
- non viene scritta nel registro attività;
- non viene salvata in file temporanei o report;
- non viene mostrata nell'interfaccia.

## 04 — Importazione controllata

La fase 04 implementa un'importazione Passbolt v4/v5 condizionata da un dry-run autenticato. Autenticazione, verifiche e scrittura restano operazioni distinte, ma dry-run e importazione condividono una sola sessione protetta in memoria.

### Dry-run autenticato, senza scritture

1. L'utente seleziona soltanto candidati con stato **Pronto**.
2. L'utente seleziona il file della propria chiave privata OpenPGP, inserisce la passphrase e, se l'account lo richiede, il codice MFA TOTP a 6 cifre, quindi usa **Avvia sessione**.
3. Il bridge locale verifica la chiave del server contro la fingerprint rilevata e confermata nella fase 01, esegue GPGAuth, completa TOTP nella stessa sessione e controlla che la chiave privata corrisponda all'identita Passbolt autenticata. Passphrase e TOTP vengono immediatamente rimossi dalla richiesta e dai campi UI.
4. Per ogni dry-run l'app ricalcola SHA-256 e ricostruisce i candidati dai documenti. Se un documento, il record o i metadati sono cambiati dopo la revisione, il flusso si interrompe.
5. L'app verifica che la sessione e l'identita siano ancora valide, quindi legge impostazioni, cartelle, maschere dei permessi, utenti, gruppi, chiavi pubbliche, tipi di risorsa e metadati delle risorse accessibili all'utente. Se incontra cartelle o risorse v5, decifra localmente i metadati con la chiave personale o con la copia verificata della chiave condivisa.
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
- l'istanza consente il formato richiesto o almeno un formato compatibile in modalita Automatica;
- per la destinazione per cliente, l'istanza consente il formato cartella richiesto e tutte le cartelle esistenti necessarie sono leggibili senza ambiguita;
- è disponibile un tipo password compatibile: `password-and-description`, `password-string`, `v5-default` oppure `v5-password-string`;
- per v5 è disponibile e verificata la chiave metadati personale o condivisa richiesta dalle impostazioni del server;
- il confronto duplicati è completo;
- nessun duplicato esatto è stato trovato fuori dalla destinazione prevista;
- Passbolt ha fornito un token CSRF;
- l'utente ha digitato la frase `IMPORTA N`, dove `N` è il numero esatto di nuove risorse;
- l'utente accetta una seconda finestra di conferma.

Subito prima della scrittura, la validita della sessione viene ricontrollata e i sorgenti vengono nuovamente aperti e verificati. Le nuove cartelle vengono create per prime con `POST /folders.json`; se devono ereditare una condivisione, la relativa simulazione e applicazione devono riuscire prima che il loro identificatore venga usato come `folder_parent_id` nelle risorse. Le password vengono estratte soltanto in quel momento, passate al bridge OpenPGP persistente tramite input standard e cifrate localmente con la chiave pubblica dell'utente; il messaggio cifrato viene anche firmato con la chiave privata. Per una destinazione condivisa, dopo la simulazione viene prodotta una copia cifrata e firmata per ogni nuovo destinatario concreto indicato da Passbolt. Per cartelle e risorse v5 anche i metadati vengono cifrati e firmati localmente. Chiave, passphrase, TOTP e password non sono inseriti negli argomenti dei processi, nelle variabili d'ambiente, nei log o nei file temporanei. La sessione resta attiva dopo un'importazione riuscita, cosi puo essere usata per il lotto successivo.

Le creazioni sono sequenziali e Passbolt non espone una transazione unica per l'intero lotto. Se una richiesta fallisce dopo alcune creazioni, l'app mostra separatamente cartelle e risorse gia create, non elimina automaticamente nulla e obbliga a ripetere il dry-run: il nuovo confronto riutilizza le cartelle riuscite e riconcilia le risorse riuscite come duplicati.

### Limiti attuali dell'importazione

- massimo 25 candidati per lotto;
- massimo 65.536 caratteri per password;
- supporto alla creazione di risorse password v4 e v5 nei quattro tipi compatibili elencati sopra;
- supporto a cartelle personali e condivise v4/v5 sotto la radice o sotto il contenitore scelto, riutilizzate per nome univoco o create prima delle risorse;
- supporto a un contenitore Passbolt esistente comune oppure a una cartella esistente usata come destinazione diretta;
- supporto alla mappatura distinta di ogni cliente del lotto verso una cartella personale o condivisa esistente e scrivibile oppure verso la radice personale;
- supporto alle cartelle condivise esistenti con permessi User e Group Read, Update e Owner, simulazione preventiva e cifratura separata per ogni destinatario concreto;
- le nuove sottocartelle cliente dentro un contenitore condiviso ereditano obbligatoriamente la sua maschera completa; non e possibile modificarla durante la creazione;
- una sottocartella omonima ma personale trovata dentro un contenitore condiviso blocca il piano e deve essere verificata in Passbolt prima di continuare;
- se una chiave metadati v5 manca, non appartiene al dominio configurato, non coincide con la fingerprint dichiarata o la sua copia privata non e firmata dalla chiave utente, la scrittura viene bloccata;
- se un metadato v5 esistente non puo essere decifrato e validato, il confronto duplicati viene considerato incompleto e la scrittura viene bloccata;
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

Ogni sessione di revisione applica questi limiti:

- massimo 50 file selezionati;
- massimo 20 MB per file;
- massimo 100 MB non compressi per un documento Office;
- massimo 5.000 record per file;
- massimo 200 pagine per PDF;
- massimo 2.000 candidati complessivi;
- nessuna apertura di collegamenti simbolici a file;
- nessun percorso esterno alla cartella clienti configurata;
- rifiuto degli XML contenenti DTD o dichiarazioni di entità;
- nessuna esecuzione di macro, formule Excel, script o collegamenti Office esterni.

I documenti Office vengono aperti in modalità di lettura. Le formule presenti in XLSX non vengono calcolate né eseguite.

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

L'autenticazione usa gli endpoint GPGAuth `/auth/verify.json` e `/auth/login.json`. Se Passbolt richiede TOTP, viene usato `POST /mfa/verify/totp.json` con `remember=0`; i cookie `passbolt_session`, `passbolt_mfa` e CSRF restano soltanto nella sessione del bridge in memoria. La scrittura usa `POST /folders.json` e `POST /resources.json` soltanto dopo tutte le conferme descritte sopra. Per una destinazione condivisa usa inoltre `POST /share/simulate/folder/{id}.json` e `PUT /share/folder/{id}.json` per le nuove cartelle, quindi `POST /share/simulate/resource/{id}.json` e `PUT /share/resource/{id}.json` per le risorse. Ogni `PUT` viene eseguita soltanto dopo una simulazione riuscita. `POST /auth/logout.json` viene tentato alla chiusura esplicita, automatica o finale della sessione.

JWT è il metodo indicato come preferenziale dalla documentazione Passbolt recente. La versione 0.12.2 usa GPGAuth con MFA TOTP per compatibilità con l'istanza verificata; il codice mantiene il pinning della fingerprint dopo la conferma e verifica crittograficamente le sfide di entrambi i lati.

Per eseguire soltanto il controllo da riga di comando:

```powershell
.\run_passbolt_probe.ps1 `
  -BaseUrl "https://passbolt.example.com" `
  -ExpectedFingerprint "0123456789ABCDEF0123456789ABCDEF01234567"
```

## Controlli per lo sviluppo

Il bridge OpenPGP usa `openpgp` 6.3.1. Dopo un nuovo clone o se manca `node_modules`, installare la dipendenza bloccata dal lockfile senza eseguire script di pacchetto:

```powershell
pnpm install --frozen-lockfile --ignore-scripts
```

I backend e la UI espongono self-test locali:

```powershell
python .\passbolt_app.py --self-test
python .\passbolt_review.py --self-test
python .\passbolt_import.py --self-test
'{"command":"self-test"}' | node .\passbolt_crypto.mjs
node .\test_passbolt_crypto.mjs
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\PassboltApp.ps1 -SelfTest
python -m unittest -v test_passbolt_api_probe.py test_passbolt_app.py test_passbolt_review.py test_passbolt_import.py
```

`test_passbolt_crypto.mjs` avvia un server simulato soltanto su `127.0.0.1` e verifica end-to-end GPGAuth stage 0/1/2, redirect interni, blocco dei redirect esterni, TOTP mancante, TOTP rifiutato, TOTP valido, cookie di sessione e MFA, riuso della sessione per due dry-run senza un secondo login o un secondo TOTP, CSRF, piano duplicati v4/v5, chiave metadati personale, chiave metadati condivisa verificata, catalogo gerarchico delle cartelle, contenitore padre selezionato, destinazione diretta, mappature distinte v4/v5, destinazione radice per singolo cliente, rifiuto delle destinazioni incomplete o in sola lettura, lettura e creazione cartelle v4/v5, ereditarieta User/Group per nuove sottocartelle condivise, digest della maschera, simulazione prima dell'applicazione, chiave condivisa per i metadati v5, assegnazione di `folder_parent_id`, blocco dei duplicati presenti altrove, riconciliazione dei fallimenti parziali e creazione risorse v4/v5 con segreti e metadati OpenPGP cifrati. Non contatta l'istanza Passbolt reale.

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

## Passaggio successivo

La fase successiva prevista e la versione 0.13: un registro locale di riconciliazione privo di segreti, con identificativo del lotto, hash dei sorgenti, ID remoti e stato di ogni creazione, per verificare o riprendere in sicurezza importazioni piu ampie. Le fasi successive potranno aggiungere un editor esplicito dei permessi e dei gruppi, altri provider MFA e le operazioni controllate sulle risorse esistenti. L'app continua a interrompersi in modo sicuro quando non può dimostrare l'identità, verificare l'integrità del sorgente, validare le chiavi metadati o confrontare completamente cartelle e duplicati.
