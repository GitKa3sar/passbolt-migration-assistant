# Roadmap

La roadmap ordina il lavoro di abilitazione della release; non amplia da sola il perimetro funzionale. Versione e conteggi fanno fede in [`release-candidate.json`](../release-candidate.json) e nei risultati del gate.

## P0.29 — Risorse v5 preview

### P0.29-SCOPE-01 — Contratto duale ristretto

Stato: **completato nel worktree del candidato corrente**; resta da fissare in un commit candidato autorizzato.

- mantenere invariato il percorso Passbolt v4;
- consentire risorse v5 personali soltanto su scelta esplicita e legata al piano;
- mantenere fail-closed `auto`, import v5 condivisi, cartelle v5, conversioni e ACL mutative v5;
- aggiornare UI, bridge, ricevute, manifesto e documentazione come un unico contratto.

### P0.29-OFFLINE-01 — Accettazione sintetica v4/v5

Stato: **completato localmente** sul worktree corrente; il risultato non sostituisce CI e matrici reali sul futuro SHA candidato.

Eseguire su `127.0.0.1` i gate read-only, stateful e recovery per v4 e per risorse v5 con cartelle v4. I conteggi devono derivare dalle suite realmente presenti e il percorso v4 non deve regredire.

### P0.29-CI-01 — CI Windows

Stato: **pendente sul futuro SHA candidato**.

Il workflow Windows deve essere verde sull'esatto commit candidato e conservare soltanto artefatti sintetici. Il gate locale non attesta la CI.

### P0.29-MATRIX-01 — Matrici reali separate

Stato: **pendente e non autorizzato**.

Le matrici v4 e v5-resource-preview richiedono laboratori dedicati e usa-e-getta, autorizzazione esplicita e report sanitizzati separati sullo stesso commit. La precedente evidenza v5 `14/16` resta soltanto storica.

### P0.29-RELEASE-01 — Decisione go/no-go

Stato: **NO-GO per una release stabile** finché CI e matrici reali non sono complete. `release_authorized=false` resta obbligatorio nel gate offline.

## Dopo P0.29

La creazione di cartelle v5 richiede una decisione separata dopo la chiusura o mitigazione verificata del difetto upstream `passbolt_api #617/#618`, verifica post-write dedicata e matrice reale completa. Lo stesso vale per import v5 condivisi, ACL mutative v5, conversioni e negoziazione `auto`.
