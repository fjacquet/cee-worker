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

**La réponse attendue, d'après la documentation publique** (Netwrix pour
Dell Activity Monitor, fils Dell Community sur l'enregistrement CEPA) :

```xml
<?xml version="1.0" encoding="UTF-8"?>
<RegisterResponse>
  <Status>Success</Status>
</RegisterResponse>
```

## Ce qui n'est pas établi

**L'encodage de la réponse.** La documentation publique montre de
l'UTF-8. CEE annonce `Accept-Charset: utf-16` et envoie lui-même de
l'UTF-16LE. Les deux ont été essayés :

- Réponse UTF-8 : l'hôte Windows a continué à réémettre toutes les 10 s.
- Réponse UTF-16 : des hôtes se sont tus, d'autres non.

**Ces observations sont contaminées.** Le consommateur factice a levé une
exception sur certaines requêtes (`do_PUT`, connexion probablement
rompue), donc on ne sait pas si CEE a reçu une réponse valide, une
réponse tronquée, ou rien. Aucune conclusion sur UTF-8 contre UTF-16 ne
doit être tirée de ces essais.

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

Reprendre la mesure avec un consommateur qui ne lève pas d'exception, et
comparer proprement UTF-8 contre UTF-16 sur des redémarrages contrôlés,
en croisant avec les journaux de CEE des deux côtés — journald sur Linux,
journal d'événements Windows — pour distinguer un enregistrement réussi
d'un abandon.

## Limites

- Aucune baie PowerStore n'a jamais été dans la boucle.
- L'hôte Windows est hors domaine.
- Le consommateur factice n'est pas `cee-exporter` ; rien ici ne dit ce
  que `cee-exporter` fait de ces requêtes.

## Sources

- <https://docs.netwrix.com/docs/activitymonitor/8_0/admin/agents/properties/dellceeoptions>
- <https://www.dell.com/community/en/conversations/celerra/error-during-cepa-registration-incomplete-xml/647eab9bf4ccf8a8de909312>
- <https://www.dell.com/support/kbdoc/en-us/000019572/unity-dell-emc-unity-cee-cepa-user-correctable>
