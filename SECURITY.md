# Security policy

Passbolt Migration Assistant tratta materiale ad alta sensibilità. Non allegare mai a issue, pull request, commit o log pubblici chiavi private, passphrase, codici MFA, account-kit, cookie, token, documenti dei clienti o credenziali reali.

## Versioni supportate

| Versione | Supporto di sicurezza |
| --- | --- |
| 0.12.x | Sì |
| < 0.12 | No |

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

Il componente di riconciliazione in sviluppo per la versione 0.13 scrive soltanto registri tecnici sotto il profilo locale dell'utente e non e ancora collegato alle importazioni reali. Lo schema usa una lista chiusa di campi: identificativi UUID, hash SHA-256, fingerprint, stati, contatori e codici di errore. Rifiuta campi sconosciuti e qualsiasi nome o valore riconducibile a password, passphrase, segreti, chiavi private, MFA, cookie, autorizzazioni o sessioni. Non registra percorsi dei documenti, titolo, username o URL delle credenziali. I record sono concatenati tramite SHA-256; troncamento e corruzione bloccano la continuazione automatica e richiedono una verifica del lotto. La catena rileva incoerenze accidentali ma non autentica il file contro un utente locale che possa riscriverlo interamente: prima di una futura ripresa, origine, fingerprint, identita, sorgenti e oggetti remoti dovranno comunque essere ricontrollati tramite una nuova sessione Passbolt.
