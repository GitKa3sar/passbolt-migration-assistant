# Security policy

Passbolt Migration Assistant tratta materiale ad alta sensibilità. Non allegare mai a issue, pull request, commit o log pubblici chiavi private, passphrase, codici MFA, account-kit, cookie, token, documenti dei clienti o credenziali reali.

## Versioni supportate

| Versione | Supporto di sicurezza |
| --- | --- |
| 0.17.x | Sì |
| 0.16.x | No |
| < 0.16 | No |

Finché il progetto è in fase di sviluppo, gli aggiornamenti di sicurezza vengono applicati soltanto all'ultima versione pubblicata.

## Segnalare una vulnerabilità

Non aprire un'issue pubblica con dettagli tecnici sfruttabili. Usa la funzione privata **Report a vulnerability** nella scheda **Security** del repository, quando disponibile. Se il canale privato non è disponibile, apri soltanto un'issue minimale chiedendo al maintainer un canale di contatto riservato, senza includere vulnerabilità, prove, URL privati o dati sensibili.

La segnalazione privata dovrebbe contenere:

- versione e commit interessati;
- prerequisiti e impatto osservato;
- passaggi minimi per riprodurre il problema usando dati sintetici;
- eventuale proposta di correzione;
- indicazione di qualsiasi divulgazione già avvenuta.

Il maintainer confermerà la ricezione, valuterà riproducibilità e impatto e coordinerà correzione e divulgazione. Non è garantito un tempo di risposta specifico.

## Ambito prioritario

Sono particolarmente rilevanti problemi che possano causare esposizione di segreti, aggiramento del pinning applicato dopo la conferma della fingerprint, autenticazione verso un server non fidato, scritture non confermate, riuso improprio della sessione, accesso a file fuori dalla radice selezionata, esecuzione di contenuti attivi o assegnazione errata dei permessi Passbolt.

## Gestione sicura dei dati

Le prove devono usare esclusivamente chiavi, account e documenti creati per il test. Dopo il test, revoca le credenziali temporanee ed elimina in modo sicuro gli artefatti locali. La cartella di lavoro non è un luogo adatto per conservare segreti: `.gitignore` è una difesa aggiuntiva, non sostituisce le procedure operative corrette.

La visualizzazione delle password nella fase 03 è disattivata per impostazione predefinita e richiede una conferma esplicita. I valori vengono trasferiti soltanto fra processi locali tramite input/output standard reindirizzati, non vengono registrati né salvati e le copie lette dai sorgenti vengono rimosse dalla UI quando si ripristina la maschera o si cambia fase. Le password corrette manualmente restano in memoria fino alla scrittura confermata o alla chiusura dell'applicazione.

Per un file `.xlsx` cifrato, l'app richiede la password soltanto dopo aver riconosciuto il contenitore Office protetto. Il documento viene decifrato in un buffer di memoria, senza creare una copia in chiaro o un file temporaneo; la password viene riutilizzata localmente per ricostruire i candidati durante il controllo d'integrità e l'importazione, non viene registrata, serializzata nei risultati o inoltrata al bridge Passbolt ed è eliminata dallo stato applicativo alla nuova revisione, al nuovo inventario o alla chiusura. I file legacy `.xls` protetti non sono supportati.

Il componente di riconciliazione introdotto nella versione 0.13 scrive soltanto registri tecnici sotto il profilo locale dell'utente ed e collegato alle importazioni della fase 04. Python crea il registro dopo un dry-run valido e prima di inviare la richiesta di scrittura; il bridge Node emette un'intenzione prima di ogni operazione irreversibile e il relativo esito dopo la risposta di Passbolt. Python sincronizza ogni evento su disco e assorbe gli envelope intermedi, mentre la GUI riceve soltanto la risposta finale. Se un evento non supera la validazione o non puo essere scritto, il bridge viene terminato e il lotto resta da verificare. La GUI espone il protocollo autenticato di verifica e ripresa soltanto dopo aver associato tutti i candidati del lotto ai documenti riletti dalla cartella sorgente corrente.

Lo schema usa una lista chiusa di campi: identificativi UUID, hash SHA-256, fingerprint, stati, contatori e codici di errore. Rifiuta campi sconosciuti e qualsiasi nome o valore riconducibile a password, passphrase, segreti, chiavi private, MFA, cookie, autorizzazioni o sessioni. Non registra percorsi dei documenti, titolo, username o URL delle credenziali. Dalla versione 0.14 registra modalità e hash della configurazione ACL, ma non gli ID degli utenti o gruppi selezionati. I record sono concatenati tramite SHA-256; troncamento e corruzione bloccano la continuazione automatica e richiedono una verifica manuale. La catena rileva incoerenze accidentali ma non autentica da sola il file contro un utente locale che possa riscriverlo interamente: il recupero ricontrolla quindi origine e fingerprint, hash dell'identita, sorgenti, destinazione, configurazione ACL, oggetti remoti e maschere di permesso tramite una nuova sessione Passbolt. Soltanto stati univoci possono essere ripresi; non sono consentiti delete, move o sovrascritture implicite. Un lease esclusivo resta attivo fra verifica e applicazione per impedire che due processi riprendano lo stesso lotto in parallelo. L'archiviazione richiede UUID canonico, stato corrente e conferma esatta, acquisisce lo stesso lease e sposta il journal sotto la directory `Archive` senza cancellarne l'evidenza.

L'editor dei permessi della versione 0.14 opera soltanto nella sessione autenticata. Il bridge valida directory, stato degli utenti, appartenenze ai gruppi, chiavi pubbliche e fingerprint, aggiunge sempre il proprietario corrente come Owner e lega la ACL al digest del piano. I permessi personalizzati vengono applicati soltanto a oggetti nuovi; una cartella esistente con ACL diversa blocca il dry-run invece di essere modificata implicitamente.

Il visualizzatore ACL della versione 0.15 usa soltanto endpoint Passbolt in `GET` e restituisce alla GUI esclusivamente nomi, percorsi, ID, livelli e stati operativi bounded. Chiavi pubbliche, fingerprint e materiale OpenPGP vengono usati soltanto nel bridge per verificare utenti e gruppi e non attraversano il protocollo verso WPF. La GUI accetta il risultato soltanto se dichiara `read_only=true` e `write_requests=0`; maschere mancanti o non normalizzabili e directory incomplete restano visibili come avvisi e non vengono promosse a stato verificato. Il catalogo è volatile, non viene scritto nei journal e viene eliminato alla chiusura della sessione.

Il dry-run ACL della versione 0.15.1 non amplia i privilegi remoti dell'applicazione. Prima di costruire il piano, il bridge riverifica sessione e identità, rilegge da Passbolt oggetti, maschere e directory, richiede che l'utente corrente sia `Owner` e blocca maschere incomplete o soggetti non verificabili. Il proprietario autenticato viene reinserito implicitamente come Owner e non può comparire nelle voci modificabili. Snapshot corrente, ACL desiderata e operazioni classificate sono legati da digest separati; il desiderato è limitato a 500 voci e il confronto a 2.000 operazioni. Python inoltra soltanto una lista chiusa di campi ACL e rimuove candidati, segreti e proprietà sconosciute. La risposta dichiara anche `remote_writes_planned=0`; la GUI non espone un'azione di applicazione, il bridge non chiama endpoint mutativi e non viene creato alcun journal.

La versione 0.16.0 aggiunge un percorso di scrittura separato e limitato alle sole operazioni `add` e `upgrade`. Python accetta l'applicazione soltanto per l'ultimo piano osservato nella stessa sessione, richiede una conferma che incorpora numero di modifiche e prefisso del digest e crea un journal ACL prima di consegnare l'UUID al bridge. Node rilegge lo stato remoto, ricostruisce il piano e pretende la coincidenza di snapshot, desiderato, directory verificata e digest complessivo; il digest della directory include membri dei gruppi e fingerprint delle chiavi, così una variazione dei destinatari invalida il dry-run. L'omissione di un soggetto corrente, un livello inferiore o una rimozione riportata dalla simulazione Passbolt bloccano la `PUT`. Gli aumenti conservano l'ID del permesso corrente e le aggiunte usano `is_new`, senza inviare delete.

Quando una risorsa ottiene nuovi utenti effettivi, il bridge legge il segreto cifrato dell'utente autenticato, lo decifra esclusivamente in memoria e ricifra l'esatto testo per le chiavi pubbliche verificate indicate dalla simulazione. Il segreto in chiaro non attraversa Python o WPF, non entra negli envelope di avanzamento e non viene scritto nel journal. Il journal dedicato sotto `AclReconciliation` contiene origine e fingerprint del server, hash dell'identità, tipo e ID dell'oggetto, digest, contatori e ACL desiderata normalizzata. Gli ID User/Group sono una prova tecnica necessaria al recupero riavviato; lo schema rifiuta password, segreti, chiavi, passphrase, MFA, cookie, autorizzazioni, ID di sessione, materiale OpenPGP e campi sconosciuti.

Il recupero ACL acquisisce un lease esclusivo e accetta soltanto uno stato remoto uguale al digest finale atteso oppure uguale allo snapshot originale. Nel primo caso chiude il journal senza ripetere la scrittura; nel secondo ricostruisce e ripete soltanto lo stesso piano additivo. Stati intermedi, oggetti mancanti o ambigui, variazioni della directory e digest differenti bloccano l'automatismo. La catena SHA-256 del journal rileva corruzione e troncamento ma non costituisce una firma: server, fingerprint, hash dell'utente, oggetto e stato remoto vengono sempre verificati nuovamente tramite la sessione autenticata. Riduzioni e revoche restano non applicabili.

La versione 0.17.0 estende il percorso di scrittura a `downgrade` e `revoke` senza permettere modifiche implicite. Il bridge calcola l'accesso effettivo di ciascun utente dopo l'espansione completa dei gruppi, include le variazioni nel digest del piano e limita a 2.000 gli utenti coinvolti. L'utente autenticato deve comparire nella ACL corrente e desiderata come permesso diretto `Owner`; il risultato deve conservare almeno un Owner. Queste proprietà vengono ricontrollate durante dry-run, applicazione e recupero, dopo una nuova lettura autenticata dello stato remoto.

Ogni revoca usa esclusivamente l'ID del record corrente con `delete: true`; ogni downgrade conserva l'ID e cambia il livello. La simulazione Passbolt deve restituire esattamente gli utenti effettivi aggiunti e rimossi previsti dal piano: destinatari duplicati, sovrapposti, mancanti o inattesi bloccano la `PUT`. La GUI richiede una frase che incorpora conteggio delle operazioni restrittive, utenti che perderanno accesso e digest, quindi un secondo avviso. Il journal registra modalità e conteggi restrittivi senza segreti; il recupero può ripetere una riduzione soltanto se snapshot, desiderato, directory, piano e conteggi sono ancora identici. I journal additivi 0.16.0 restano leggibili.
