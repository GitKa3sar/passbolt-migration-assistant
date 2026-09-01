# Direzione del progetto

## Missione

Passbolt Migration Assistant aiuta un operatore Windows a inventariare, revisionare e migrare credenziali verso Passbolt con controlli espliciti, dati sensibili confinati localmente e recupero fail-closed degli esiti incerti.

## Fase corrente

Il prodotto resta una **technical beta**, non production-ready, con profilo `passbolt-v4-v5-resource-preview`. Passbolt v4 rimane il percorso completo; le sole risorse v5 personali possono essere scelte esplicitamente, mentre `auto`, import v5 condivisi, cartelle v5, conversioni e ACL mutative v5 restano fail-closed. Il gate offline dimostra coerenza su dati sintetici e non sostituisce CI o matrici reali sul medesimo commit. Stato e conteggi sono in [`release-candidate.json`](../release-candidate.json).

## Principi decisionali

1. Sicurezza e recuperabilità prevalgono su automazione e comodità.
2. Inventario, revisione, verifica remota, dry-run e scrittura restano fasi separate.
3. Una capability non attestata viene rifiutata; non viene inferita da fixture o prove storiche.
4. Versione, documentazione, UI e report devono descrivere lo stesso candidato.
5. Una promozione richiede evidenze riproducibili sul medesimo commit, senza segreti nel repository.

## Fuori perimetro corrente

- import v5 condivisi, creazione o riuso operativo di cartelle v5, conversioni v4/v5 e selezione automatica del formato;
- modifica delle ACL di oggetti v5; il catalogo resta consultabile in sola lettura;
- nuovi parser o formati sorgente non coperti da implementazione, dipendenze e test;
- cancellazione o spostamento remoto e modifica della composizione dei gruppi;
- automazione non autorizzata della matrice reale o uso del progetto in produzione.

I contratti tecnici restano nella [guida corrente](../LEGGIMI-Passbolt-API.md), la gestione dei dati sensibili in [SECURITY.md](../SECURITY.md) e la cronologia in [CHANGELOG.md](../CHANGELOG.md).
