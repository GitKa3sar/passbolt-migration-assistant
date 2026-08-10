# Changelog

Le modifiche rilevanti del progetto sono documentate in questo file. Il formato segue [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) e il progetto usa [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## In sviluppo - 0.13.0

### Added

- aggiunto il componente locale `passbolt_reconciliation.py` per creare un registro JSON Lines versionato e separato per ogni lotto;
- aggiunti identificativo UUID del lotto, sequenza monotona degli eventi, timestamp UTC, concatenamento SHA-256 e sincronizzazione su disco dopo ogni append;
- definito uno schema a campi consentiti per piano, prove dei sorgenti, intenzioni operative, ID remoti, condivisioni, errori sicuri e completamento del lotto;
- aggiunti test per troncamento dell'ultima scrittura, manomissione, record malformati, associazione fra nome file e lotto e immutabilita dei registri completati;
- collegato il registro alla fase 04: Python lo crea dopo il dry-run e prima della scrittura, quindi inoltra al bridge soltanto l'UUID del lotto;
- aggiunti envelope interni Node-Python per intenzione ed esito di creazione, condivisione, riconciliazione, duplicati saltati e completamento del lotto;
- aggiunti all'esito finale l'UUID e lo stato del registro; la GUI annota il completamento oppure mostra l'UUID del lotto da verificare senza esporre il percorso locale;
- aggiunti test end-to-end per assorbimento degli eventi intermedi, chiusura del registro e interruzione del bridge dopo un'intenzione operativa.

### Security

- il registro accetta soltanto identificativi, hash, contatori e stati tecnici; rifiuta campi sconosciuti, URL con credenziali, materiale OpenPGP, header di autorizzazione e nomi di campo riconducibili a password, passphrase, MFA, cookie, sessioni o chiavi private;
- l'identificativo utente Passbolt viene trasformato in SHA-256 prima della persistenza e i candidati sono rappresentati soltanto da `candidate_id` e hash SHA-256 del sorgente;
- una riga finale incompleta viene ignorata come conferma ma marca il lotto come da verificare e impedisce ulteriori append automatici; una corruzione interna blocca completamente la lettura fidata;
- i registri sono destinati a `%LOCALAPPDATA%` e sono esclusi dal controllo versione come difesa aggiuntiva;
- ogni intenzione viene sincronizzata prima della richiesta irreversibile a Passbolt e ogni esito viene sincronizzato prima della risposta finale alla GUI;
- gli envelope di avanzamento sono consumati esclusivamente dal backend Python e non modificano il protocollo a risposta singola usato dalla GUI;
- se un evento non e valido o non puo essere scritto, Python termina il bridge e marca il lotto come da verificare; la ripresa automatica resta disabilitata fino ai successivi blocchi della 0.13.

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
