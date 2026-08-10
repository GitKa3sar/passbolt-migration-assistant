# Passbolt Migration Assistant for Windows

Windows desktop assistant for safely inventorying, reviewing and importing credentials into Passbolt with OpenPGP, MFA TOTP, v4/v5 resources, folders and sharing.

Passbolt Migration Assistant is a local WPF workflow for controlled credential migrations. It inventories supported documents without opening them during discovery, exposes a masked review step, authenticates with Passbolt through GPGAuth and TOTP, builds a deterministic dry-run plan, and writes only after explicit confirmation.

> [!IMPORTANT]
> This is an independent community project. It is not an official Passbolt product and is not affiliated with or endorsed by Passbolt SA. Version 0.12.5 is a development release: validate it in a non-production environment and keep verified backups before any migration.

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
- creazione di sottocartelle personali e condivise con permessi ereditati;
- espansione controllata dei gruppi e verifica delle chiavi dei destinatari;
- dry-run con digest, rilevamento duplicati e riconciliazione dei fallimenti parziali;
- registro locale durevole e privo di segreti per le operazioni eseguite durante ogni lotto;
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
5. completare revisione, mappatura delle destinazioni e dry-run prima di autorizzare la scrittura.

La GUI non richiede più di digitare la fingerprint. Il valore rilevato non viene considerato una prova autonoma dell'identità del server: dopo la conferma, viene mantenuto in memoria e usato come valore atteso dal bridge OpenPGP, che controlla crittograficamente la chiave effettiva ricevuta durante GPGAuth. La conferma vale per la sessione corrente e non costituisce un archivio persistente di server fidati.

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

La versione 0.12.5 supporta MFA TOTP, ma non altri provider MFA. Il lotto è limitato a 25 candidati e non sono ancora disponibili un editor generale delle ACL, la gestione dei gruppi o operazioni distruttive sulle risorse esistenti. I file Excel cifrati sono supportati nel formato moderno `.xlsx`; i file legacy `.xls` devono essere convertiti prima della revisione.

La fase 0.13 introduce un registro locale di riconciliazione privo di segreti, con identificativo del lotto, hash dei sorgenti, ID remoti e stato di ogni creazione. I primi due blocchi sono presenti: `passbolt_reconciliation.py` definisce il formato JSON Lines versionato, il concatenamento SHA-256, la scrittura sincronizzata e il comportamento sicuro in caso di troncamento o manomissione; il workflow della fase 04 crea ora un registro reale e persiste gli eventi interni emessi dal bridge prima e dopo ogni operazione irreversibile. La GUI continua a ricevere una sola risposta finale e mostra soltanto l'UUID tecnico del lotto.

La ripresa automatica non e ancora abilitata: un registro incompleto segnala che il lotto deve essere verificato e l'operatore deve ripetere il dry-run. Il terzo blocco aggiungera la verifica autenticata dello stato remoto e la ripresa idempotente; il quarto completera interfaccia di recupero, archiviazione e documentazione operativa. La versione operativa resta `0.12.5` finche queste funzioni non saranno complete.

I registri sono conservati sotto `%LOCALAPPDATA%\Passbolt Migration Assistant\Reconciliation`, fuori dalla cartella del progetto. Lo schema ammette soltanto identificativi tecnici, hash, contatori e stati: non accetta password, passphrase, MFA, cookie, chiavi, contenuto dei documenti o metadati delle credenziali. Le fasi successive potranno estendere provider MFA, gestione controllata dei permessi e operazioni sicure sulle risorse esistenti.

## Contribuire

Issue e pull request sono benvenute. Prima di contribuire, leggere [CONTRIBUTING.md](CONTRIBUTING.md) e assicurarsi che test, esempi e log non contengano dati reali.

## Licenza

Copyright (C) 2026 Cesare Polidoro.

Il progetto è distribuito sotto la GNU Affero General Public License v3.0 only (`AGPL-3.0-only`). Vedere [LICENSE](LICENSE) per il testo completo.
