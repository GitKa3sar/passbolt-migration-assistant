# Checklist di release

Usare questa checklist sullo **stesso commit candidato**. README resta operativo, la guida tecnica descrive i contratti e `SECURITY.md` definisce la policy.

## 1. Identità e perimetro

- [ ] `release-candidate.json` contiene versione approvata, `technical_beta` e `passbolt-v4-v5-resource-preview`.
- [ ] UI, user agent, progetti, ricevute, laboratori, matrice, documenti e test dichiarano la stessa versione.
- [ ] Le risorse ammettono soltanto v4 o v5 personale selezionato esplicitamente; import v5 condivisi, cartelle v5, `auto`, conversioni e ACL mutative v5 restano bloccati.
- [ ] I conteggi schema 2 coincidono con le suite realmente eseguite per ciascun profilo.
- [ ] La classificazione resta non production-ready e il riepilogo dichiara `release_authorized=false`.

## 2. Qualità offline

- [ ] Regressioni positive v5-resource-preview, schema capability stretto, drift readiness/import/recovery e destinazioni ACL personali/non attestate sono verdi.
- [ ] Laboratori read-only, stateful e recovery v4 e v5 sono verdi e confinati a `127.0.0.1`.
- [ ] Il quality gate Windows completo è verde, incluse tutte le anteprime in una directory temporanea.
- [ ] `git diff --check` è verde e `PassboltApp.ps1` conserva UTF-8 con BOM.
- [ ] Il diff è revisionato per scope, segreti, dati reali e modifiche involontarie.

## 3. Evidenze esterne

- [ ] La CI GitHub è verde sul medesimo SHA candidato.
- [ ] Un operatore ha autorizzato separatamente laboratori reali dedicati e usa-e-getta.
- [ ] Le matrici v4 e v5-resource-preview completano separatamente tutti gli scenari richiesti.
- [ ] Le prove negative v5 attestano `ACL_V5_MUTATION_DISABLED` e zero scritture; i contratti per-scenario sono coerenti con il profilo.
- [ ] I report sanitizzati restano fuori dal repository e superano verifica schema/digest.

## 4. Pubblicazione

- [ ] Rischi residui, limiti v5 e decisione go/no-go sono documentati.
- [ ] Commit, push, tag, pull request e release hanno ricevuto autorizzazione esplicita.
- [ ] Gli artefatti non contengono credenziali, configurazioni reali, journal, report completi o dati identificativi.

## Stato corrente

Il gate Windows locale completo è verde sul worktree corrente dopo l'hardening: 154 test Python, Node/OpenPGP, laboratori sintetici v4 e v5-resource-preview, WPF e 29 anteprime sono coerenti con il manifesto. Non esiste ancora un commit candidato; CI GitHub e matrici reali separate restano non attestate. La release stabile resta **NO-GO**; questa checklist non autorizza contatti con laboratori reali né operazioni di pubblicazione.
