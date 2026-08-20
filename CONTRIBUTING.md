# Contributing

Grazie per l'interesse nel progetto. Le modifiche devono preservare il principio fondamentale dell'app: nessuna scrittura remota finché identità, input, destinazione e piano non sono stati verificati e confermati.

## Prima di iniziare

- apri un'issue per modifiche ampie o incompatibili;
- usa dati sintetici e un'istanza Passbolt di test;
- non includere mai segreti, documenti reali, URL privati, fingerprint operative o dati identificativi;
- mantieni separate le fasi di inventario, revisione, dry-run e scrittura;
- non indebolire i controlli fail-closed per aggirare un errore di compatibilità.
- per modifiche ACL restrittive, conserva sempre il proprietario autenticato, riconcilia gli utenti effettivi `added`/`removed` della simulazione e aggiungi test per downgrade, revoca e recupero idempotente.
- se cambi lo schema dei profili sorgente, mantieni i file privi di valori dei documenti, aggiorna forma canonica e digest e verifica la stessa mappatura durante revisione, rilettura e pianificazione.

## Ambiente di sviluppo

Sono richiesti Windows PowerShell 5.1, Python 3.11+, Node.js 18+ e pnpm 11.19.0.

```powershell
pnpm install --frozen-lockfile --ignore-scripts
python -m pip install --requirement requirements-test.txt
```

## Verifiche richieste

Prima di aprire una pull request esegui:

```powershell
.\run_tests.ps1 -Ci
```

I server di test devono restare isolati su `127.0.0.1` e non devono contattare servizi reali. Il laboratorio offline deve usare soltanto identità e documenti sintetici, non deve registrare corpi HTTP e deve rimuovere il workspace temporaneo al termine. La modalità CI blocca `integration-matrix run`; non rimuovere o aggirare questa protezione per eseguire prove automatiche contro un'istanza Passbolt.

## Pull request

Mantieni ogni pull request focalizzata, descrivi il rischio modificato e indica i test eseguiti. Se cambia il piano di importazione, aggiorna anche digest, validazioni, test end-to-end e documentazione. Se cambia un formato o un endpoint, documenta la compatibilità Passbolt v4/v5 interessata.

Le nuove dipendenze devono essere motivate, bloccate nel lockfile e compatibili con AGPL-3.0-only. Evita dipendenze che eseguono script di installazione non necessari.

## Stile dei commit

Usa messaggi brevi all'imperativo e non mescolare refactoring non correlati con correzioni funzionali. Prima del commit controlla sempre l'elenco dei file in staging e cerca materiale sensibile.
