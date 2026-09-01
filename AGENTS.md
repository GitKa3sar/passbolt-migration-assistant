# Regole operative del repository

- Mantieni il progetto fail-closed e classificato come beta tecnica. Il profilo corrente supporta Passbolt v4 e, soltanto su scelta esplicita, risorse v5 personali; `auto`, import v5 condivisi, cartelle v5, conversioni di formato e ACL mutative v5 restano bloccati finché i rispettivi gate esterni non sono completi.
- Considera `release-candidate.json` la fonte macchina per versione, stato, profilo e conteggi. Ogni modifica appartiene a una nuova versione; aggiorna tutte le copie controllate dal quality gate e conta soltanto i test realmente presenti.
- Prima di modificare, verifica ref, SHA e worktree. Conserva le modifiche dell'utente e non usare merge, rebase, reset, stash o riscritture non richieste.
- Non usare credenziali o dati reali. Test e laboratori automatici v4/v5 devono restare sintetici e confinati a `127.0.0.1`; le matrici reali richiedono autorizzazioni separate e non fanno parte del gate offline.
- Mantieni `PassboltApp.ps1` in UTF-8 con BOM. Per modifiche funzionali aggiungi una regressione mirata ed esegui `run_tests.ps1` con anteprime in una directory temporanea, quindi `git diff --check` e revisione completa del diff.
- Non creare commit, push, tag, pull request o release senza autorizzazione esplicita.
- Evita duplicazioni documentali: README è operativo, `LEGGIMI-Passbolt-API.md` descrive i contratti correnti, `SECURITY.md` la policy, `CHANGELOG.md` la storia e `docs/` direzione, roadmap e gate.
