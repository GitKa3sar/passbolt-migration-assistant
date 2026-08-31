# Checklist di release

Usare questa checklist sullo **stesso commit candidato**. I dettagli operativi restano in [README](../README.md), i contratti nella [guida tecnica](../LEGGIMI-Passbolt-API.md) e i requisiti di sicurezza in [SECURITY.md](../SECURITY.md).

## 1. Identità e perimetro

- [ ] `release-candidate.json` contiene la versione approvata, `technical_beta` e `passbolt-v4-only`.
- [ ] UI, user agent, progetti, ricevute, laboratorio, matrice, documenti e test dichiarano la stessa versione.
- [ ] I conteggi del manifesto coincidono con le suite realmente eseguite.
- [ ] La classificazione resta non production-ready e il riepilogo dichiara `release_authorized=false`.

## 2. Qualità offline

- [ ] Il test mirato della modifica è verde.
- [ ] Il quality gate Windows completo è verde, incluse tutte le anteprime generate in una directory temporanea.
- [ ] `git diff --check` è verde e `PassboltApp.ps1` conserva UTF-8 con BOM.
- [ ] Il diff è stato revisionato per scope, segreti, dati reali e modifiche involontarie.

## 3. Evidenze esterne

- [ ] La CI GitHub è verde sul medesimo SHA candidato.
- [ ] Un operatore ha autorizzato separatamente la matrice reale e attestato un target v4 dedicato e usa-e-getta.
- [ ] Il report sanitizzato della matrice reale completa tutti gli scenari richiesti, resta fuori dal repository e supera la verifica di integrità.

## 4. Pubblicazione

- [ ] Rischi residui e decisione go/no-go sono documentati.
- [ ] Commit, push, tag, pull request e release hanno ricevuto autorizzazione esplicita.
- [ ] Gli artefatti pubblicabili non contengono credenziali, configurazioni reali, journal, report completi o dati identificativi.

## Stato corrente

La CI GitHub sul candidato e la matrice reale v4 non sono ancora attestate. La release stabile resta **NO-GO** e `release_authorized=false`; questa checklist non autorizza contatti con laboratori reali né operazioni di pubblicazione.
