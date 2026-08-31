# Roadmap

La roadmap ordina il lavoro di abilitazione della release; non amplia da sola il perimetro funzionale. Versione e conteggi non vengono duplicati qui: fanno fede [`release-candidate.json`](../release-candidate.json) e i risultati del gate.

## P0 — Verità del candidato

### P0-CONTRACT-01 — Contratto formati e governance

Stato: **implementato nel candidato corrente; verifica locale obbligatoria**.

- allineare README e guida alle 16 estensioni inventariate;
- dichiarare `.xls` rilevato ma conversion-only prima della revisione e rimuovere la promessa ODT;
- impedire con un test il drift fra documenti e liste implementate;
- mantenere regole operative, direzione, roadmap e checklist concise;
- aggiornare l'identità del candidato senza cambiare parser, protocolli o scritture.

### P0-CI-01 — CI Windows sul commit candidato

Stato: **pendente, esterno a P0-CONTRACT-01**.

Eseguire il workflow Windows sullo stesso SHA candidato e conservare soltanto artefatti sintetici. Un gate locale verde non consente di segnare questa attività come completata.

### P0-MATRIX-01 — Matrice reale Passbolt v4

Stato: **pendente e non autorizzato in questa attività**.

Richiede un laboratorio dedicato e usa-e-getta, autorizzazione esplicita dell'operatore e attestazione separata del target prima di qualsiasi contatto o mutazione. Il report sanitizzato deve completare tutti gli scenari dichiarati dal manifesto sul medesimo commit.

### P0-RELEASE-01 — Decisione go/no-go

Stato: **NO-GO per una release stabile** finché CI e matrice reale non sono complete. Un'eventuale distribuzione beta richiede comunque un'autorizzazione esplicita e non modifica `release_authorized=false` nel gate offline.

## Dopo P0

Nuove funzionalità, parser, workflow ACL o supporto v5 richiedono una decisione di scope separata, un nuovo candidato e verifiche proporzionate. Non sono parte di `P0-CONTRACT-01`.
