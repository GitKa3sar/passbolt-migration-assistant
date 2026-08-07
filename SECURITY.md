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

Sono particolarmente rilevanti problemi che possano causare esposizione di segreti, aggiramento del pinning della fingerprint, autenticazione verso un server non fidato, scritture non confermate, riuso improprio della sessione, accesso a file fuori dalla radice selezionata, esecuzione di contenuti attivi o assegnazione errata dei permessi Passbolt.

## Gestione sicura dei dati

Le prove devono usare esclusivamente chiavi, account e documenti creati per il test. Dopo il test, revoca le credenziali temporanee ed elimina in modo sicuro gli artefatti locali. La cartella di lavoro non è un luogo adatto per conservare segreti: `.gitignore` è una difesa aggiuntiva, non sostituisce le procedure operative corrette.
