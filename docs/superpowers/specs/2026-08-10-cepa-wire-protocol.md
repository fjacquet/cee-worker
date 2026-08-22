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

```http
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

**La réponse attendue : un document `<RegisterResponse>`.**

> **Corrigé le 2026-08-21.** Ce document affirmait l'inverse — « HTTP 200
> avec un corps VIDE » — et cette erreur a coûté deux mises en service.
> La version d'origine est conservée plus bas, parce que la manière dont
> elle s'est trompée est instructive.

CEE analyse la réponse et la refuse si elle n'a pas de nœud racine. Les
messages d'erreur de `CEndPoint::Init()`, extraits de `libCEPPFilter.so`
dans le rpm CEE 9.2.0.0 versionné sous `bin/` :

```text
Top node is not RegisterResponse. Fail: %d.
Incomplete XML. Required Name or FriendlyName not present
Incomplete XML. Required description not present
Guid or FriendlyName not specified.
```

La forme attendue n'est pas déduite : c'est celle que CEE utilise pour son
propre proxy SplunkHEC intégré, littéral présent dans
`libCEPPAPIWrapper.so` :

```xml
<RegisterResponse>   <EndPoint friendlyName="SplunkHEC"
  guid="0fce0c69-ef49-4362-bae9-180ef0bf97c2" version="1.0"
  desc="Dell EMC SplunkHEC Proxy" />    <Filter protocol="0,1">
  <EventTypeFilter value="0xFFFFFFFF0000000000000000" />
  </Filter></RegisterResponse>
```

Codes de protocole, lus dans la table `ProtocolDesc` de CEE : **0=CIFS,
1=NFS, 2=FTP, 3=Unknown**. La valeur `EventTypeFilter` fait 24 chiffres
hexadécimaux, soit trois mots de 32 bits — un par phase (pre, post-success,
post-failure) — ce que confirme `CEPPEventTable`, 28 emplacements × 3
drapeaux. **L'ordre des trois mots n'est pas établi.**

### Conséquence : c'était la cause de `CEPP_NOT_FOUND`

Un corps vide n'a pas de nœud racine : `CEndPoint::Init()` ne peut pas
aboutir, et un consommateur que CEE n'enregistre jamais ne recevra jamais
d'événement.

**C'était bien la cause du `0x16`, et c'est corrigé.** Le contrôle « adresse
morte » — la baie reçoit le même `status="0x16"` — semblait innocenter ce
segment ; c'est un faux négatif, une adresse morte et un enregistrement refusé
signifiant tous deux « aucun partenaire ». Il manquait une condition : CEE
n'enregistre que les consommateurs de sa liste blanche compilée (`CGuidStore`,
clé *(friendlyName, facility)* → GUID). Voir
`docs/cee-partner-allowlist.md` et `docs/cepa-2026-08-22-powerstore-session.md`.

Et la réémission toutes les dix secondes
— que ce document interprétait comme un battement de cœur, et qu'une
première correction a réinterprétée comme une poignée de main qui échoue —
**n'est ni l'un ni l'autre**. Trois CEE identiques placés devant trois
consommateurs qui renvoient respectivement une `RegisterResponse` valide, un
corps vide et du charabia non-XML se comportent de façon rigoureusement
identique : `PUT /` toutes les dix secondes, indéfiniment, sans jamais
émettre de `<HeartBeatRequest />`. La cadence ne dit donc rien de
l'acceptation. Ce qui reste établi vient du code de CEE, pas de son
comportement.

### Ce que la version d'origine avait bien vu, et où elle a dérapé

Les deux contraintes suivantes tiennent toujours : l'acquittement doit
partir en **moins de trois secondes**, et un seul `PUT` peut porter des
milliers d'événements en mode VCAPS.

Ce qui a dérapé, c'est la hiérarchie des sources. Le commentaire en tête de
`pkg/server/server.go` a été traité comme la seule affirmation « venant
d'une implémentation en production », donc comme faisant autorité — alors
que c'était un commentaire, non vérifié, dans un code qui n'avait jamais vu
un enregistrement réussi. Ce document le disait lui-même, quelques lignes
plus bas, dans « Ce qui n'est pas établi ». Les deux affirmations
coexistaient sans que la contradiction soit relevée.

Et la note d'origine sur la documentation publique s'inverse : Netwrix et
les fils Dell Community décrivaient une réponse XML `<RegisterResponse>` et
des rejets « Incomplete XML » quand `Name` ou `FriendlyName` manque. **Ils
avaient raison**, jusqu'au message d'erreur, qui figure mot pour mot dans le
binaire. Ils ont été écartés sur la foi d'une expérience que ce document
qualifie lui-même de non probante.

Le commentaire fautif a été réécrit dans `cee-exporter`, et non supprimé,
pour la même raison que cette section est conservée.

### La version d'origine, conservée pour mémoire

> **La réponse attendue : HTTP 200 avec un corps VIDE.**
>
> C'est la seule affirmation de ce document qui vienne d'une implémentation
> en production plutôt que d'une observation ou d'une page web. Le paquet
> `pkg/server/server.go` de `cee-exporter`, qui reçoit ces requêtes pour de
> vrai, l'énonce en tête de fichier :
>
> ```go
> //  1. RegisterRequest: respond HTTP 200 with an EMPTY body.  Any XML in the
> //     response causes a fatal parse error on the PowerStore side.
> ```
>
> **La documentation publique est trompeuse sur ce point.** Netwrix et les
> fils Dell Community décrivent une réponse XML de la forme
> `<RegisterResponse><Status>Success</Status></RegisterResponse>`, et
> mentionnent des rejets « Incomplete XML » quand `Name` ou `FriendlyName`
> manque. Répondre cela à CEE 9.2.0.0 provoque une erreur de parsing fatale
> côté émetteur.
>
> #### Erreur commise pendant cette enquête, consignée pour mémoire
>
> Le premier consommateur factice répondait `HTTP 200` avec un corps vide —
> c'était **correct**. Il a ensuite été « corrigé » pour renvoyer la
> `RegisterResponse` XML de la documentation publique, ce qui l'a rendu
> **non conforme**. Les essais UTF-8 contre UTF-16 qui ont suivi
> comparaient donc deux réponses invalides, et leurs résultats n'ont aucune
> valeur probante.

Relire ce dernier paragraphe avec la réponse correcte en main : le
« consommateur factice non conforme » était en fait le seul conforme des
deux, et les essais qui ont suivi ne comparaient pas deux réponses
invalides mais une valide et une vide.

## Ce qui n'est pas établi

**Ce qui suit un enregistrement réussi.** Aucun essai n'a été mené avec
une réponse conforme et un consommateur stable. On ne sait donc pas si
l'enregistrement ouvre une session, ni ce que CEE attend ensuite. Aucun
événement n'a jamais circulé.

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
