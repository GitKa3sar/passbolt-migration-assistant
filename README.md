# Passbolt Migration Assistant for Windows

Windows desktop assistant for safely inventorying, reviewing and importing credentials into Passbolt with OpenPGP, MFA TOTP, v4/v5 resources, folders and sharing.

Passbolt Migration Assistant is a local WPF workflow for controlled credential migrations. It inventories supported documents without opening them during discovery, exposes a masked review step, authenticates with Passbolt through GPGAuth and TOTP, builds a deterministic dry-run plan, and writes only after explicit confirmation.

> [!IMPORTANT]
> This is an independent community project. It is not an official Passbolt product and is not affiliated with or endorsed by Passbolt SA. Version 0.15.0 is a development release: validate it in a non-production environment and keep verified backups before any migration.

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
- espansione controllata dei gruppi e verifica delle chiavi dei destinatari;
- dry-run con digest, rilevamento duplicati e riconciliazione dei fallimenti parziali;
- registro locale durevole e privo di segreti per le operazioni eseguite durante ogni lotto;
- recupero guidato e idempotente degli import interrotti, con verifica autenticata e archiviazione non distruttiva dei journal;
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

La GUI non richiede più di digitare la fingerprint. Il valore rilevato non viene considerato una prova autonoma dell'identità del server: dopo la conferma, viene mantenuto in memoria e usato come valore atteso dal bridge OpenPGP, che controlla crittograficamente la chiave effettiva ricevuta durante GPGAuth. La conferma vale per la sessione corrente e non costituisce un archivio persistente di server fidati.

Se un import si interrompe dopo l'avvio delle scritture, non ripetere direttamente una nuova importazione dello stesso lotto. Nella fase 04 aprire **Recupero import interrotto**, quindi:

1. selezionare il journal indicato dall'errore;
2. usare la stessa cartella sorgente e rivedere tutti i documenti del lotto, riapplicando eventuali correzioni fatte nella fase 03;
3. avviare la sessione autenticata; se il lotto usava una ACL personalizzata, ricreare nell'editor la stessa selezione di utenti, gruppi e livelli, quindi scegliere **Verifica lotto**;
4. controllare i conteggi **Già riuscite**, **Da applicare** e **Conflitti**, verificando che non siano previste azioni distruttive;
5. digitare la frase esatta `RECUPERA N` e confermare la ripresa;
6. al completamento, archiviare il journal dalla stessa scheda.

I journal troncati o corrotti vengono mostrati ma restano bloccati in modalità fail-closed: richiedono un controllo manuale su Passbolt. Possono essere archiviati esplicitamente come abbandonati, senza essere cancellati.

Per consultare i permessi già presenti su Passbolt, nella fase 04 aprire **Permessi esistenti**, mantenere attiva la stessa sessione autenticata e scegliere **Leggi permessi**. La scheda consente di filtrare cartelle e risorse, cercare per nome, percorso o ID e visualizzare la ACL del singolo oggetto. Le voci dirette e quelle assegnate tramite gruppo restano distinte; per i gruppi viene mostrato il numero di destinatari effettivi verificati. La versione 0.15.0 non espone comandi di modifica in questa scheda e non invia richieste HTTP mutative.

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

I test non contattano un'istanza Passbolt reale. Il test JavaScript usa esclusivamente un server simulato su `127.0.0.1`.

```powershell
python .\passbolt_app.py --self-test
python .\passbolt_review.py --self-test
python .\passbolt_import.py --self-test
'{"command":"self-test"}' | node .\passbolt_crypto.mjs
node .\test_passbolt_crypto.mjs
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\PassboltApp.ps1 -SelfTest
python -m unittest -v test_passbolt_api_probe.py test_passbolt_app.py test_passbolt_review.py test_passbolt_import.py test_passbolt_reconciliation.py
```

La descrizione completa del comportamento, degli endpoint e dei controlli implementati è disponibile in [LEGGIMI-Passbolt-API.md](LEGGIMI-Passbolt-API.md).

## Limiti attuali e roadmap

La versione 0.15.0 supporta MFA TOTP; gli altri provider MFA sono intenzionalmente fuori dallo scope corrente della roadmap. Il lotto è limitato a 25 candidati. L'editor ACL usa utenti e gruppi già presenti in Passbolt, ma non modifica la composizione dei gruppi e non cambia ancora i permessi di cartelle o risorse esistenti. Le operazioni distruttive sulle risorse esistenti restano escluse. I file Excel cifrati sono supportati nel formato moderno `.xlsx`; i file legacy `.xls` devono essere convertiti prima della revisione.

La versione 0.15 introduce la consultazione autenticata degli oggetti esistenti. Il bridge legge cartelle, risorse, maschere e directory con sole richieste `GET`, decifra localmente i nomi v5, normalizza i livelli Read/Update/Owner e segnala ACL incomplete o soggetti non verificabili. Il catalogo è bounded e resta in memoria; la GUI non riceve chiavi, fingerprint o segreti. Questa fase non crea journal perché non esegue alcuna operazione remota irreversibile.

La versione 0.14 introduce l'editor esplicito dei permessi nella fase 04. La directory di utenti e gruppi viene letta soltanto nella sessione autenticata; ogni chiave pubblica e ogni appartenenza di gruppo vengono verificate prima di rendere il destinatario selezionabile. Il proprietario autenticato viene aggiunto sempre come `Owner` e non può essere rimosso o declassato. La ACL normalizzata entra nel digest del dry-run e viene ricontrollata subito prima della scrittura.

I permessi personalizzati si applicano soltanto alle nuove cartelle e risorse create dall'import. Se il piano punta a una cartella esistente, l'importazione è consentita soltanto quando quella cartella possiede già esattamente la stessa ACL; in caso contrario il dry-run si blocca senza modificare l'oggetto. Il journal conserva soltanto modalità e hash della configurazione, non gli ID dei destinatari. Per questo un recupero riavviato deve ricreare la stessa ACL nell'editor e superare il confronto dell'hash.

La versione 0.13 completa il registro locale di riconciliazione privo di segreti, con identificativo del lotto, hash dei sorgenti, ID remoti e stato di ogni creazione. `passbolt_reconciliation.py` definisce il formato JSON Lines versionato, il concatenamento SHA-256, la scrittura sincronizzata e il comportamento sicuro in caso di troncamento o manomissione; il workflow della fase 04 persiste gli eventi prima e dopo ogni operazione irreversibile; il protocollo di sessione riapre un lotto incompleto, riverifica server, fingerprint, utente, sorgenti e stato remoto e costruisce una ripresa idempotente.

La ripresa accetta soltanto stati non ambigui: un'unica risorsa esatta nella destinazione prevista, una richiesta dimostrabilmente non applicata oppure una maschera ancora limitata al solo proprietario. Un esito riuscito seguito dalla scomparsa dell'oggetto, duplicati multipli, contenuti spostati, permessi parziali o variazioni della ACL prevista bloccano ogni automatismo. La GUI distingue lotti recuperabili, completati, troncati e corrotti; presenta il riepilogo autenticato, richiede `RECUPERA N` e non pianifica cancellazioni, spostamenti o sovrascritture.

I registri attivi sono conservati sotto `%LOCALAPPDATA%\Passbolt Migration Assistant\Reconciliation`, fuori dalla cartella del progetto. L'archiviazione li sposta sotto `Reconciliation\Archive\<stato>` e non elimina l'evidenza. Lo schema ammette soltanto identificativi tecnici, hash, contatori e stati: non accetta password, passphrase, MFA, cookie, chiavi, contenuto dei documenti o metadati delle credenziali.

La prossima fase della roadmap aggiungera il dry-run read-only delle modifiche ACL: selezione esplicita dell'oggetto, confronto prima/dopo, digest dello stato remoto e distinzione fra aggiunte, aumenti di livello, riduzioni e revoche. Soltanto dopo la validazione di questo piano potranno essere introdotte operazioni additive, journal dedicato e recupero idempotente; riduzioni e revoche resteranno un blocco successivo con conferma rafforzata. Seguira il miglioramento della gestione operativa dei lotti. Il supporto ad altri provider MFA resta saltato come scelta di scope.

## Contribuire

Issue e pull request sono benvenute. Prima di contribuire, leggere [CONTRIBUTING.md](CONTRIBUTING.md) e assicurarsi che test, esempi e log non contengano dati reali.

## Licenza

Copyright (C) 2026 Cesare Polidoro.

Il progetto è distribuito sotto la GNU Affero General Public License v3.0 only (`AGPL-3.0-only`). Vedere [LICENSE](LICENSE) per il testo completo.
