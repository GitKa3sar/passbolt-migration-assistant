# Changelog

Le modifiche rilevanti del progetto sono documentate in questo file. Il formato segue [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) e il progetto usa [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
