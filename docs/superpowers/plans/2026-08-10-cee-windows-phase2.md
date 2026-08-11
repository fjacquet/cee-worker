# CEE Windows — plan d'implémentation (phase 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Déployer Dell CEE 9.2.0.0 sur Windows Server via les rôles Ansible existants, à partir des faits relevés sur machine réelle plutôt que d'hypothèses.

**Architecture:** Les quatre rôles dispatchent déjà sur `ansible_os_family`. La phase 2 ajoute leurs branches `Windows.yml`, ouvre le gate famille d'OS, et remplace le template XML par des écritures de registre. Les trois gates neutres de `cee_common` servent Windows sans modification.

**Tech Stack:** ansible-core ≥ 2.17, collections `ansible.posix` / `community.general` / `ansible.windows`, connexion OpenSSH avec `ansible_shell_type: powershell`.

**Source de vérité:** `docs/superpowers/specs/2026-08-10-cee-windows-releve.md` — tout ce plan en découle. Aucune valeur ci-dessous n'est devinée.

## Global Constraints

- Les asserts ne sont **jamais** bouclés. Un échec dans un `assert` avec `loop:` est enveloppé en `{"msg": "One or more items failed", "results": [...]}` et le vrai `fail_msg` devient invisible aux blocs `rescue` des tests, qui lisent `ansible_failed_result.msg`. `win_regedit` peut être bouclé — ce n'est pas un assert.
- `ignore_errors: true`, **jamais** `failed_when: false`, quand une tâche ultérieure inspecte le résultat enregistré.
- Aucun `defaults/main.yml`.
- Chaque `fail_msg` nomme la chose précise qui est fausse **et** le vrai correctif.
- Chaque test négatif est mutation-testé : garde désactivée, test vu échouer, garde restaurée.
- Aucun module POSIX (`ansible.builtin.stat`, `file`, `find`, `wait_for`, `systemd_service`, `command`) dans une branche Windows. Équivalents : `win_stat`, `win_file`, `win_find`, `win_wait_for`, `win_service`, `win_shell`.
- Aucune adresse routable, aucun identifiant, aucun nom de fichier de clé dans un fichier suivi.
- Un seul `# noqa` existe dans le dépôt (`test_platform_assertions.yml`). Ne pas en ajouter.
- CEE 9.2.0.0 uniquement. Les défauts diffèrent en 9.3.0.0.

## Faits mesurés dont ce plan dépend

| Fait | Valeur |
|---|---|
| ProductCode 9.2.0.0 | `{81F4A925-A885-4F58-8907-641BC7E82B99}` |
| Installation silencieuse | `<exe> /s /v"/qn /l*v <log>"` — variante InstallScript-MSI, validée |
| Désinstallation | La clé annonce `MsiExec.exe /I{GUID}` — `/I` répare. Construire `msiexec /x <GUID> /qn` |
| **Service portant le listener** | **`EMC Checker Server`** (affiché `EMC CAVA`, binaire `CAVA.exe`) |
| Service annexe | `EMC CEE Monitor` (`CEEMtrSvc.exe`) — ne porte **pas** le listener |
| Racine de configuration | `HKLM:\SOFTWARE\EMC\CEE` |
| Journalisation | Journal d'événements Windows, sources `EMC CEE` et `CEE Monitor`. **Aucun fichier.** |
| `ServerEnabled` par défaut | `0` en 9.2.0.0 — doit être écrit à `1` |
| Bind du listener | `::` (joker IPv6), pas une adresse IPv4 |

Correspondance variable du dépôt → valeur de registre, sous `HKLM:\SOFTWARE\EMC\CEE` :

| Variable | Chemin |
|---|---|
| `cee_http_port` | `Configuration\HttpPort` |
| `cee_https_port` | `Configuration\HttpsPort` |
| `cee_endpoints` | `CEPP\Audit\Configuration\EndPoint` (format `name@http://host:port;…`) |
| `cee_access_list_enabled` | `Configuration\Security\Access\AccessListEnabled` |
| `cee_access_list` | `Configuration\Security\Access\AccessList` |
| `cee_facilities` | `CEPP\<Facility>\Configuration\Enabled` |
| `cee_cache_size` | `Configuration\CacheSize` |
| `cee_threads` | `Configuration\NumberOfThreads` |
| `cee_debug` | `Configuration\Debug` |
| `cee_verbose` | `Configuration\Verbose` |
| — | `Configuration\Security\Http\ServerEnabled` = `1` (sans équivalent dans le schéma) |
| `cee_log_path` | **aucun équivalent** — voir Task 1 |

## Structure de fichiers

**Créés**

| Fichier | Rôle |
|---|---|
| `ansible/roles/cee_preflight/tasks/Windows.yml` | Gate plateforme + corps preflight Windows |
| `ansible/roles/cee_preflight/tasks/assert_platform_Windows.yml` | Windows Server accepté, édition client refusée |
| `ansible/roles/cee_preflight/tasks/preflight_windows.yml` | Horloge `w32tm`, sonde de port `win_wait_for` |
| `ansible/roles/cee_install/tasks/Windows.yml` | `win_copy` + `win_package` |
| `ansible/roles/cee_configure/tasks/Windows.yml` | `win_regedit`, `win_firewall_rule`, `win_service` |
| `ansible/roles/cee_verify/tasks/Windows.yml` | Service, port, journal d'événements, chaîne fatale |

**Modifiés**

| Fichier | Changement |
|---|---|
| `ansible/roles/cee_preflight/tasks/assert_os_family.yml` | Accepte `Windows` |
| `ansible/roles/cee_common/tasks/assert_required_vars.yml` | Retire `cee_log_path` de la liste neutre |
| `ansible/roles/cee_preflight/tasks/preflight_linux.yml` | Y assure `cee_log_path` |
| `ansible/roles/cee_configure/tasks/main.yml` | Dispatch à deux voies |
| `ansible/roles/cee_verify/tasks/main.yml` | Dispatch à deux voies |
| `ansible/roles/cee_configure/handlers/main.yml` | Seconde tâche `listen` en `win_service` |
| `ansible/requirements.yml` | Ajoute `ansible.windows` |
| `ansible/group_vars/cee_windows.yml.example` | Retire la mention « phase 2 non implémentée » |
| `ansible/tests/test_platform_dispatch.yml` | `Windows` devient un cas **accepté** |
| `ansible/tests/test_platform_assertions.yml` | Cas Windows Server / client |
| `CLAUDE.md`, `docs/ansible-deployment.md`, `docs/acceptance-tests.md`, `CHANGELOG.md` | Documentation |

---

## Task 1 : Sortir `cee_log_path` du contrat neutre

`cee_log_path` n'a aucun équivalent Windows. Il est aujourd'hui exigé par `cee_common/tasks/assert_required_vars.yml`, que les trois plateformes partagent.

Le réflexe serait d'y ajouter une condition sur `ansible_os_family`. C'est le mauvais geste : `cee_common` est neutre par construction, et c'est cette neutralité qui permet aux tests localhost d'exercer tous les gates sans VM. Une condition plateforme y ouvrirait la porte à toutes les suivantes.

À la place, la variable descend là où elle est réellement requise : la branche Linux.

**Files:**
- Modify: `ansible/roles/cee_common/tasks/assert_required_vars.yml`
- Modify: `ansible/roles/cee_preflight/tasks/preflight_linux.yml`
- Modify: `ansible/group_vars/cee_windows.yml.example`
- Test: `ansible/tests/test_required_vars.yml`

**Interfaces:**
- Produces: `cee_common` n'exige plus que les variables communes aux trois OS. `preflight_linux.yml` exige `cee_log_path` en plus, avec son propre message.

- [ ] **Step 1 : Adapter le test à la nouvelle répartition**

`test_required_vars.yml` inclut `cee_common/tasks/assert_required_vars.yml` avec des jeux de variables incomplets. Le cas qui retire `cee_log_path` doit désormais **passer** ce gate. Repérer ce cas et l'ajuster ; si aucun ne cible spécifiquement `cee_log_path`, ne rien inventer — vérifier simplement que les cas existants tiennent toujours.

Ajouter un play qui inclut `preflight_linux.yml`… **non** : ce fichier appelle des modules qui touchent l'hôte. Le gate `cee_log_path` doit donc vivre dans son propre fichier incluable, `assert_required_vars_linux.yml`, sur le modèle des autres gates isolés du dépôt. Ajouter un play négatif qui l'inclut sans `cee_log_path` et attend l'échec.

- [ ] **Step 2 : Lancer, voir échouer**

```bash
ansible-playbook ansible/tests/test_required_vars.yml
```

Attendu : ÉCHEC sur `assert_required_vars_linux.yml` introuvable.

- [ ] **Step 3 : Créer le gate Linux**

`ansible/roles/cee_preflight/tasks/assert_required_vars_linux.yml` :

```yaml
---
# Linux-only variable gate. Isolated from preflight_linux.yml so tests/
# can include it with a deliberately incomplete variable set, like every
# other gate in this repo.
#
# cee_log_path lives here rather than in cee_common because it has no
# Windows equivalent: CEE 9.2.0.0 on Windows logs to the Application
# Event Log and exposes no log-path setting anywhere in its registry
# tree. Putting a platform condition inside cee_common would cost that
# role the neutrality that lets ansible/tests/ exercise every shared gate
# on a localhost control node with no VM.

- name: Linux hosts must define cee_log_path
  ansible.builtin.assert:
    that:
      - cee_log_path is defined
    fail_msg: >-
      cee_log_path is undefined. Copy
      ansible/group_vars/cee_linux.yml.example to
      ansible/group_vars/cee_linux.yml and fill it in. This variable is
      Linux-only: it is rendered into emc_cee_config.xml for config
      consistency, and Windows has no equivalent.
```

- [ ] **Step 4 : Le retirer de la liste neutre et l'inclure côté Linux**

Dans `cee_common/tasks/assert_required_vars.yml`, retirer `- cee_log_path is defined` de la liste `that:` et retirer `cee_log_path` de l'énumération du `fail_msg`.

En tête de `preflight_linux.yml` :

```yaml
- name: Assert the Linux-only variables are defined
  ansible.builtin.include_tasks: assert_required_vars_linux.yml
```

- [ ] **Step 5 : Retirer la fausse variable de l'exemple Windows**

`cee_windows.yml.example` ne doit plus définir `cee_log_path`. Conserver la note expliquant que Windows journalise dans l'Event Log.

- [ ] **Step 6 : Vérifier et commiter**

```bash
ansible/tests/run.sh
yamllint ansible/ .github/
(cd ansible && ansible-playbook --syntax-check site.yml)
ansible-lint ansible/
```

Puis mutation-tester le nouveau gate, et commiter en `refactor(ansible):`.

---

## Task 2 : Preflight Windows

**Files:**
- Create: `ansible/roles/cee_preflight/tasks/assert_platform_Windows.yml`
- Create: `ansible/roles/cee_preflight/tasks/preflight_windows.yml`
- Create: `ansible/roles/cee_preflight/tasks/Windows.yml`
- Modify: `ansible/roles/cee_preflight/tasks/assert_os_family.yml`
- Modify: `ansible/requirements.yml`
- Test: `ansible/tests/test_platform_dispatch.yml`, `ansible/tests/test_platform_assertions.yml`

**Interfaces:**
- Consumes: la convention de dispatch existante.
- Produces: `Windows` devient une famille acceptée ; `assert_platform_Windows.yml` incluable par les tests avec des faits surchargés.

- [ ] **Step 1 : Déclarer `ansible.windows`**

Dans `ansible/requirements.yml`, après `community.general` :

```yaml
  # ansible.windows supplies win_package, win_regedit, win_service,
  # win_firewall_rule, win_wait_for and the Windows implementation of
  # setup. Without it, `gather_facts: true` in site.yml crashes against a
  # Windows host before the OS-family gate can reject anything, because
  # ansible.builtin.setup is a POSIX module executed target-side under
  # Python — which a Windows Server does not have.
  - name: ansible.windows
    version: ">=2.5.0"
```

- [ ] **Step 2 : Écrire les tests d'abord**

Dans `test_platform_dispatch.yml`, `Windows` passe de rejeté à **accepté** — inverser le play existant et mutation-tester.

Dans `test_platform_assertions.yml`, ajouter : Windows Server accepté, édition client (Workstation) rejetée.

Les faits à surcharger sont `ansible_os_family: Windows` et `ansible_os_product_type` (`server` / `workstation`). **Vérifier le nom exact du fait sur la VM avant d'écrire le test** — ne pas le deviner :

```bash
ansible -i <inv> winvm -m ansible.windows.setup | grep -i product_type
```

- [ ] **Step 3 : Ouvrir le gate famille d'OS**

`assert_os_family.yml` accepte `['RedHat', 'Suse', 'Windows']`. Adapter le `fail_msg` : il nomme aujourd'hui Windows comme non implémenté.

- [ ] **Step 4 : Gate plateforme Windows**

`assert_platform_Windows.yml` : exiger une édition Serveur. Le message doit expliquer que CEE est un service serveur et que les éditions client ne sont pas qualifiées par Dell.

- [ ] **Step 5 : Corps preflight Windows**

`preflight_windows.yml` — équivalents stricts du corps Linux :

- Synchronisation horloge : `win_shell: w32tm /query /status`, `changed_when: false`, assertion non bouclée sur l'absence d'un état désynchronisé. Le message doit dire la même chose que côté Linux : baie, hôte CEE et consommateur doivent partager l'heure.
- Sonde de port : `ansible.windows.win_wait_for` sur `{{ cee_http_port }}`, `state: stopped`, `timeout: 3`, `ignore_errors: true` — **pas** `failed_when: false`, une tâche ultérieure inspecte le résultat.
- Rapport d'un listener préexistant, en `win_shell` ou `debug`.

`Windows.yml` inclut le gate puis le corps, exactement comme `RedHat.yml` et `Suse.yml`.

- [ ] **Step 6 : Vérifier, mutation-tester, commiter**

---

## Task 3 : Installation Windows

**Files:**
- Create: `ansible/roles/cee_install/tasks/Windows.yml`

**Interfaces:**
- Consumes: le dispatch de `cee_install/tasks/main.yml`.
- Produits: CEE 9.2.0.0 installé, les deux services présents.

- [ ] **Step 1 : Localiser et copier l'installeur**

Glob `playbook_dir + '/../bin/EMC_CEE_Pack_x64_*.exe'`, exiger exactement un résultat avec un `fail_msg` propre, puis `win_copy` vers `C:\Windows\Temp\`.

Reproduire le garde-fou LFS de `install_linux_locate.yml` : `ansible.builtin.stat` avec `delegate_to: localhost`, taille > 1 Mo, message nommant `git lfs install && git lfs pull`. L'exe est suivi par LFS comme le rpm SLES, et un pointeur de 130 octets passerait l'assertion d'unicité exactement de la même façon.

- [ ] **Step 2 : Installer**

```yaml
- name: Install CEE
  ansible.windows.win_package:
    path: C:\Windows\Temp\{{ cee_install_exe_local | basename }}
    product_id: '{81F4A925-A885-4F58-8907-641BC7E82B99}'
    arguments: /s /v"/qn"
    state: present
  become: false
  notify: Restart emc_cee
```

Commenter : le ProductCode vient d'une installation réelle, pas d'une supposition ; l'installeur est un wrapper InstallShield 27 et non un MSI nu, d'où `arguments` explicite ; la clé Uninstall annonce `/I` (réparation) et non `/X`, donc toute désinstallation future doit construire `msiexec /x <GUID> /qn` plutôt que réutiliser la chaîne enregistrée.

- [ ] **Step 3 : Vérifier le layout**

`win_stat` sur `C:\Program Files\EMC\CEE\CAVA.exe` et `CEEMtrSvc.exe`, assertion non bouclée.

- [ ] **Step 4 : Nettoyer, vérifier, commiter**

---

## Task 4 : Configuration Windows

**Files:**
- Create: `ansible/roles/cee_configure/tasks/Windows.yml`
- Modify: `ansible/roles/cee_configure/tasks/main.yml`
- Modify: `ansible/roles/cee_configure/handlers/main.yml`

- [ ] **Step 1 : Dispatch à deux voies**

```yaml
- name: Run the platform-specific configuration
  ansible.builtin.include_tasks: >-
    {{ 'Windows.yml' if ansible_os_family == 'Windows' else 'Linux.yml' }}
```

Idem pour `cee_verify/tasks/main.yml` en Task 5.

- [ ] **Step 2 : Écritures de registre**

`win_regedit` pour chaque ligne du tableau de correspondance. Points de vigilance :

- Les ports, `CacheSize`, `NumberOfThreads`, `Debug`, `Verbose`, `AccessListEnabled` et les `Enabled` de facilités sont des `DWord`.
- `EndPoint` et `AccessList` sont des `String`.
- `Security\Http\ServerEnabled` doit être écrit à **`1`** : 9.2.0.0 livre `0`. C'est l'équivalent exact de ce que fait déjà le template XML côté Linux.
- Les facilités se bouclent sur `cee_facilities` — un `win_regedit` bouclé est légitime, ce n'est pas un assert.
- `EndPoint` se construit comme le template Linux : `name@http://host:port`, joints par `;`, **ordre préservé**. CEE surveille le premier endpoint pour décider s'il publie.

Toutes les écritures notifient `Restart emc_cee`.

- [ ] **Step 3 : Pare-feu**

`ansible.windows.win_firewall_rule` sur `{{ cee_http_port }}/tcp` en entrée, sous `when: cee_manage_firewall | bool`. Le chemin où la variable est fausse doit être **aussi bruyant que sur Linux** : le pare-feu Windows ne filtre pas davantage le loopback, donc un hôte pare-feuté passerait tous les contrôles en rejetant chaque événement réel. Reprendre le fond du message Linux.

- [ ] **Step 4 : Service**

```yaml
- name: Enable and start CEE
  ansible.windows.win_service:
    name: EMC Checker Server
    start_mode: auto
    state: started
```

Commenter impérativement : **c'est `EMC Checker Server` (affiché `EMC CAVA`, binaire `CAVA.exe`) qui porte le listener CEPA sur 12228, mesuré, pas `EMC CEE Monitor` malgré son nom.** Piloter le moniteur laisserait le port mort en rapportant `Running`.

- [ ] **Step 5 : Handler Windows**

Dans `handlers/main.yml`, seconde tâche :

```yaml
- name: Restart emc_cee on Windows
  listen: Restart emc_cee
  ansible.windows.win_service:
    name: EMC Checker Server
    state: restarted
  when: ansible_os_family == 'Windows'
```

Ajouter `when: ansible_os_family != 'Windows'` est déjà en place sur la tâche Linux. Aucun `notify:` ne change.

- [ ] **Step 6 : Vérifier, commiter**

---

## Task 5 : Vérification Windows

**Files:**
- Create: `ansible/roles/cee_verify/tasks/Windows.yml`
- Modify: `ansible/roles/cee_verify/tasks/main.yml`

Quatre contrôles, mêmes intentions que Linux, mécanismes différents.

- [ ] **Step 1 : Service démarré**

`ansible.windows.win_service_info` sur `EMC Checker Server`, assertion sur `state == 'started'`. Le `fail_msg` doit orienter vers le journal d'événements, pas vers un fichier.

- [ ] **Step 2 : Port en écoute**

`ansible.windows.win_wait_for` sur `{{ cee_http_port }}`, `state: started`, `ignore_errors: true`, puis assertion séparée sur le résultat enregistré — jamais `failed_when: false`.

Le `fail_msg` doit nommer la cause la plus probable, qui est mesurée : **9.2.0.0 livre `Security\Http\ServerEnabled=0`**, et si le listener manque, c'est d'abord là qu'il faut regarder.

Attention au bind : le listener s'attache à `::`. Sonder `127.0.0.1` fonctionne en double pile, mais le commentaire doit signaler que le bind n'est pas IPv4.

- [ ] **Step 3 : CEE a bien journalisé**

Équivalent Windows du contrôle journald. Interroger le journal d'événements via `win_shell` :

```powershell
Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='EMC CEE'; StartTime=<service start>} -ErrorAction SilentlyContinue
```

Ancrer `StartTime` sur le démarrage du service, obtenu au Step 1 — même raisonnement que `ActiveEnterTimestamp` côté Linux : sans ancre, un événement d'un démarrage antérieur ferait passer ou échouer à tort.

L'assertion doit exiger la présence d'événements de la source **`EMC CEE`**, pas simplement une sortie non vide : c'est l'équivalent du préfixe `[EMC CEE]` côté Linux, et pour la même raison — le service peut être `Running` sans que le processus ait rien dit.

- [ ] **Step 4 : Absence de la chaîne fatale**

Chercher `Platform is not supported` dans les mêmes événements. Absente sur un Windows Server légitime — vérifié lors du relevé.

- [ ] **Step 5 : Rapport final**

Équivalent du `debug` Linux : service actif, port, endpoints, et l'orientation vers le journal d'événements plutôt qu'un fichier.

- [ ] **Step 6 : Vérifier, commiter**

---

## Task 6 : Déploiement réel et documentation

- [ ] **Step 1 : Déployer sur `winvm`**

Ajouter l'hôte au groupe `cee_windows` de l'inventaire réel (gitignoré), puis `ansible-playbook site.yml --limit winvm`.

**La VM porte déjà une installation 9.2.0.0 configurée à la main pendant le relevé.** C'est un test d'idempotence involontaire mais réel : le rôle doit converger sans casser. Consigner ce qui est rapporté `changed`.

- [ ] **Step 2 : Second passage**

Relancer immédiatement. Consigner les `changed` résiduels et leur cause — le chemin Linux en a deux, dus au transit du rpm.

- [ ] **Step 3 : Vérifier depuis le réseau**

Le security group AWS n'ouvre pas 12228 en entrée sur l'hôte Windows. Soit l'ouvrir hors Ansible comme pour les hôtes Linux, soit consigner que le chemin réseau reste non vérifié côté Windows. **Ne pas laisser croire qu'il l'est.**

- [ ] **Step 4 : Documentation**

`CLAUDE.md`, `docs/ansible-deployment.md`, `docs/acceptance-tests.md`, `CHANGELOG.md`, `group_vars/cee_windows.yml.example`.

Ce qui doit y figurer sans ambiguïté :

- Le service à piloter est `EMC Checker Server`, et pourquoi le nom trompe.
- Windows n'a pas de log fichier ; la vérification passe par le journal d'événements.
- `cee_log_path` est Linux-only.
- Ce qui **n'est pas** prouvé : rien n'a jamais tourné contre une baie PowerStore, et le relevé s'est fait sur une machine hors domaine, donc rien de ce qui dépend du domaine n'est validé.

- [ ] **Step 5 : Revue finale de branche**

## Hors périmètre

- La facilité VCAPS, non supportée sur toutes les plateformes.
- Le chemin conteneur, qui reste RHEL/UBI9.
- WinRM comme transport alternatif.
- Toute automatisation de désinstallation.
- La validation en domaine, impossible sur la VM disponible.
