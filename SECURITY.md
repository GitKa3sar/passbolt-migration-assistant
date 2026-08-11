# Security policy

Passbolt Migration Assistant tratta materiale ad alta sensibilità. Non allegare mai a issue, pull request, commit o log pubblici chiavi private, passphrase, codici MFA, account-kit, cookie, token, documenti dei clienti o credenziali reali.

## Versioni supportate

| Versione | Supporto di sicurezza |
| --- | --- |
| 0.15.x | Sì |
| < 0.15 | No |

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

Il visualizzatore ACL della versione 0.15 resta separato dall'editor e non offre azioni di modifica. Ogni caricamento riverifica sessione e identita, usa soltanto endpoint Passbolt in `GET` e restituisce alla GUI esclusivamente nomi, percorsi, ID, livelli e stati operativi bounded. Chiavi pubbliche, fingerprint e materiale OpenPGP vengono usati soltanto nel bridge per verificare utenti e gruppi e non attraversano il protocollo verso WPF. La GUI accetta il risultato soltanto se dichiara `read_only=true` e `write_requests=0`; maschere mancanti o non normalizzabili e directory incomplete restano visibili come avvisi e non vengono promosse a stato verificato. Il catalogo è volatile, non viene scritto nei journal e viene eliminato alla chiusura della sessione.
