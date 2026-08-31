# Direzione del progetto

## Missione

Passbolt Migration Assistant aiuta un operatore Windows a inventariare, revisionare e migrare credenziali verso Passbolt v4 con controlli espliciti, dati sensibili confinati localmente e recupero fail-closed degli esiti incerti.

## Fase corrente

Il prodotto resta una **technical beta**, non production-ready, con profilo `passbolt-v4-only`. Il gate offline dimostra coerenza e comportamento su dati sintetici; non sostituisce la CI sul commit candidato né la matrice completa su un laboratorio Passbolt v4 reale. Lo stato macchina e i conteggi correnti sono in [`release-candidate.json`](../release-candidate.json).

## Principi decisionali

1. Sicurezza e recuperabilità prevalgono su automazione e comodità.
2. Inventario, revisione, verifica remota, dry-run e scrittura restano fasi separate.
3. Una capability non attestata viene rifiutata; non viene inferita da fixture o prove storiche.
4. Versione, documentazione, UI e report devono descrivere lo stesso candidato.
5. Una promozione richiede evidenze riproducibili sul medesimo commit, senza segreti nel repository.

## Fuori perimetro corrente

- Passbolt v5 e formati v5;
- nuovi parser o formati sorgente non coperti da implementazione, dipendenze e test;
- cancellazione o spostamento remoto e modifica della composizione dei gruppi;
- automazione non autorizzata della matrice reale o uso del progetto in produzione.

I contratti tecnici restano nella [guida corrente](../LEGGIMI-Passbolt-API.md), la gestione dei dati sensibili in [SECURITY.md](../SECURITY.md) e la cronologia in [CHANGELOG.md](../CHANGELOG.md).
