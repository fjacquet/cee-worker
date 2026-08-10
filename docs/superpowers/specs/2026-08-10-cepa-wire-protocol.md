# CEPA wire protocol — what CEE sends with no array present

Date: 2026-08-10
Statut: observations brutes, partiellement concluantes. Lire la section
« Ce qui n'est pas établi » avant de s'appuyer sur quoi que ce soit ici.

## Pourquoi ce document

La question posée était : peut-on mocker PowerStore pour tester la chaîne
sans baie ? L'intuition de départ — partagée — était que CEE, simple
relais, se tait tant qu'aucun événement n'entre.

**C'est faux.** CEE contacte son endpoint de lui-même, sans qu'aucune baie
n'existe. Il y a donc un signal aval exploitable dès aujourd'hui.

## Montage

Trois hôtes CEE déployés par ce dépôt, tous configurés avec le même
endpoint `ceeexporter@http://<sles>:12229` :

| Hôte | Plateforme |
|---|---|
| rhel | RHEL 9.8 |
| sles | SLES 15 SP7 |
| winvm | Windows Server 2025 Datacenter |

Un consommateur factice en Python écoute sur `12229`, journalise chaque
requête et répond. Aucune baie PowerStore, aucun événement de système de
fichiers, aucun `cee-exporter`.

## Ce qui est établi

**CEE émet spontanément.** Toutes les ~10 secondes — l'intervalle
correspond à `HeartBeatIntervalSecs = 10`, présent dans le registre
Windows et rendu par le template XML Linux.

**Les trois plateformes le font.** Observé depuis les trois adresses
sources. Une conclusion antérieure selon laquelle « le CEE Linux
n'émettrait jamais » était fausse : elle venait de fenêtres
d'observation trop courtes, et RHEL a produit huit requêtes consécutives
dès qu'il a été redémarré pendant l'écoute.

**La requête, verbatim :**

```
PUT / HTTP/1.1
Host: <endpoint host>:<endpoint port>
Accept: text/xml
Accept-Charset: utf-16
Content-Type: text/xml
Content-Length: 38

<RegisterRequest />
```

Le corps fait 38 octets pour 19 caractères : il est encodé en
**UTF-16LE**, sans BOM. Le verbe est `PUT`, la cible `/` — pas un chemin
applicatif.

**Le format d'endpoint est confirmé** conforme à ce que ce dépôt
documente déjà : `PartnerId@http://adresse:port`, liste séparée par des
points-virgules, et `Enabled = 1` requis sur Audit ou VCAPS selon le
consommateur.

**La réponse attendue : HTTP 200 avec un corps VIDE.**

C'est la seule affirmation de ce document qui vienne d'une implémentation
en production plutôt que d'une observation ou d'une page web. Le paquet
`pkg/server/server.go` de `cee-exporter`, qui reçoit ces requêtes pour de
vrai, l'énonce en tête de fichier :

```go
//  1. RegisterRequest: respond HTTP 200 with an EMPTY body.  Any XML in the
//     response causes a fatal parse error on the PowerStore side.
//  2. Response latency: the CEPA heartbeat timeout is ~3 seconds.  The handler
//     ACKs immediately and delegates work to the async queue.
//  3. VCAPS batches: a single PUT may contain thousands of events.
```

**La documentation publique est trompeuse sur ce point.** Netwrix et les
fils Dell Community décrivent une réponse XML de la forme
`<RegisterResponse><Status>Success</Status></RegisterResponse>`, et
mentionnent des rejets « Incomplete XML » quand `Name` ou `FriendlyName`
manque. Répondre cela à CEE 9.2.0.0 provoque une erreur de parsing fatale
côté émetteur. Ces sources décrivent vraisemblablement une variante ou une
version antérieure du protocole ; elles restent citées plus bas, mais ne
doivent pas servir de référence d'implémentation.

Deux contraintes supplémentaires en découlent, absentes de toute source
publique : l'acquittement doit partir en **moins de trois secondes**, et
un seul `PUT` peut porter des milliers d'événements en mode VCAPS.

### Erreur commise pendant cette enquête, consignée pour mémoire

Le premier consommateur factice répondait `HTTP 200` avec un corps vide —
c'était **correct**. Il a ensuite été « corrigé » pour renvoyer la
`RegisterResponse` XML de la documentation publique, ce qui l'a rendu
**non conforme**. Les essais UTF-8 contre UTF-16 qui ont suivi
comparaient donc deux réponses invalides, et leurs résultats — des hôtes
qui se taisent, d'autres qui réémettent — n'ont aucune valeur
probante. La documentation publique a été préférée au code qui implémente
réellement le protocole, dans un dépôt voisin.

## Ce qui n'est pas établi

**Ce qui suit un enregistrement réussi.** Aucun essai n'a été mené avec
une réponse conforme et un consommateur stable. La séquence complète —
enregistrement, puis flux d'événements — reste inobservée.

**Ce qui suit l'enregistrement.** On ne sait pas si un enregistrement
réussi ouvre une session, ni ce que CEE attend ensuite. Aucun événement
n'a jamais circulé.

**La sémantique du silence.** Un hôte qui cesse d'émettre peut avoir
réussi son enregistrement, ou avoir abandonné. Les deux sont
indistinguables depuis le consommateur sans lire les journaux de CEE.

## Ce que ça change pour la suite

**Un test aval devient possible sans baie.** Un consommateur qui répond
correctement au `RegisterRequest` prouve que CEE a lu sa configuration,
résolu son endpoint et atteint le réseau. C'est trois maillons de plus
que ce que `cee_verify` peut établir aujourd'hui — il sonde `127.0.0.1`
et ne voit rien de la chaîne de publication.

**Le mock d'émetteur reste nécessaire pour tester l'ingestion**, et son
format n'est toujours pas connu : `RegisterRequest` est ce que CEE envoie
*en aval*, pas ce que PowerStore lui envoie *en amont*.

## Prochaine étape

Ne pas refaire de consommateur factice. `cee-exporter` implémente déjà le
protocole correctement et se déploie nativement
(`deploy/systemd/cee-exporter.service`). Le brancher en face de nos trois
CEE apprend davantage, plus vite, et sans reconstituer par essais ce
qu'un dépôt voisin sait déjà.

Il manque pour cela une visibilité que l'exporter n'expose pas encore :
aucune métrique ne dit qu'un publieur est toujours vivant, donc « zéro
événement » y reste aussi ambigu qu'ici. Suivi en
<https://github.com/fjacquet/cee-exporter/issues/27>.

## Limites

- Aucune baie PowerStore n'a jamais été dans la boucle.
- L'hôte Windows est hors domaine.
- Le consommateur factice n'est pas `cee-exporter` ; rien ici ne dit ce
  que `cee-exporter` fait de ces requêtes.

## Sources

- <https://docs.netwrix.com/docs/activitymonitor/8_0/admin/agents/properties/dellceeoptions>
- <https://www.dell.com/community/en/conversations/celerra/error-during-cepa-registration-incomplete-xml/647eab9bf4ccf8a8de909312>
- <https://www.dell.com/support/kbdoc/en-us/000019572/unity-dell-emc-unity-cee-cepa-user-correctable>
