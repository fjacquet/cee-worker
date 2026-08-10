# CEE multiplateforme — plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Étendre le déploiement Ansible de Dell CEE 9.2.0.0 de RHEL 9 seul à RHEL 9 + SLES 15, et préparer la structure qui accueillera Windows Server en phase 2.

**Architecture:** Un rôle `cee_common` porte les trois gates neutres (variables, endpoints, sub-facilities) partagés par toutes les plateformes. Les quatre rôles existants dispatchent sur `ansible_os_family` vers des fichiers de tâches par OS, tandis que leurs gates plateforme continuent de juger sur `ansible_distribution`. RHEL et SLES partagent `cee_configure` et `cee_verify` sans modification, parce que les deux rpm livrent un produit identique.

**Tech Stack:** ansible-core ≥ 2.17, collections `ansible.posix` / `community.general` / `ansible.windows`, yamllint, ansible-lint (profil production), Git LFS.

**Spec:** `docs/superpowers/specs/2026-08-10-cee-multiplateforme-design.md`

## Global Constraints

- CEE 9.2.0.0 pour les trois plateformes. Aucun artefact d'une autre version dans `bin/`.
- Les rôles ne livrent **aucun** `defaults/main.yml`. Un refus explicite vaut mieux qu'un défaut qui rend une config fausse en silence.
- Les asserts ne sont **jamais** bouclés. Un échec dans un `assert` avec `loop:` est enveloppé par Ansible en `{"msg": "One or more items failed", "results": [...]}` et le vrai `fail_msg` n'est lisible que sous `results[n].msg` — là où les blocs `rescue` des tests, qui lisent `ansible_failed_result.msg`, ne le voient pas. Utiliser `selectattr`/`rejectattr` sur la liste entière.
- `ignore_errors: true`, **jamais** `failed_when: false`, quand une tâche ultérieure inspecte le résultat enregistré. `failed_when` écrase la clé `failed` du résultat.
- Chaque `fail_msg` nomme la chose précise qui est fausse, jamais une erreur générique. CEE échoue en silence ; c'est la raison d'être de tout ce dépôt.
- Chaque test négatif est mutation-testé : garde désactivée, test observé en échec, garde restaurée.
- Les ports sont des entiers nus. Le contrôle « chiffres uniquement » passe **avant** le contrôle de plage (le filtre `int` de Jinja fait `int(float(v))` et blanchirait `12228.5`).
- `ansible/inventory/hosts.yml` et `ansible/group_vars/all.yml` sont gitignorés. Ne jamais les commiter ; seuls les `.example` sont suivis.
- Commits conventionnels (`feat(ansible):`, `fix(ansible):`, `docs:`, `chore:`). `CHANGELOG.md` suit Keep a Changelog.
- Le suite de tests doit rester exécutable sur localhost, sans VM ni réseau.

## Écart assumé par rapport au spec

Le spec demande un gate de famille d'OS **avant chaque dispatch**, soit quatre copies du même assert. Ce plan le place **uniquement dans `cee_preflight`**.

Justification : `cee_preflight` est le premier rôle du play et fait échouer l'exécution entière. Les trois rôles suivants sont inatteignables avec une famille non supportée. Trois copies supplémentaires seraient du bruit que la discipline du dépôt rejette ailleurs.

## Structure de fichiers

**Créés**

| Fichier | Responsabilité |
|---|---|
| `ansible/roles/cee_common/tasks/main.yml` | Inclut les trois gates neutres, dans l'ordre |
| `ansible/roles/cee_common/tasks/assert_required_vars.yml` | Déplacé depuis `cee_preflight` |
| `ansible/roles/cee_common/tasks/validate_endpoints.yml` | Déplacé depuis `cee_configure` |
| `ansible/roles/cee_common/tasks/assert_facilities.yml` | Déplacé depuis `cee_configure` |
| `ansible/roles/cee_preflight/tasks/RedHat.yml` | Gate RHEL + corps Linux |
| `ansible/roles/cee_preflight/tasks/Suse.yml` | Gate SLES + corps Linux |
| `ansible/roles/cee_preflight/tasks/assert_platform_RedHat.yml` | Renommage de `assert_platform.yml` |
| `ansible/roles/cee_preflight/tasks/assert_platform_Suse.yml` | Gate SLES, isolé pour les tests |
| `ansible/roles/cee_preflight/tasks/preflight_linux.yml` | Horloge + sonde de port, partagé RHEL/SLES |
| `ansible/roles/cee_install/tasks/RedHat.yml` | Contenu actuel de `cee_install/tasks/main.yml` |
| `ansible/roles/cee_install/tasks/Suse.yml` | Glob SLES, copie, zypper |
| `ansible/roles/cee_configure/tasks/Linux.yml` | Contenu actuel, moins les deux gates déplacés |
| `ansible/roles/cee_verify/tasks/Linux.yml` | Contenu actuel |
| `ansible/group_vars/cee_linux.yml.example` | `cee_log_path` Linux |
| `ansible/group_vars/cee_windows.yml.example` | `cee_log_path` Windows + connexion |
| `ansible/tests/test_platform_dispatch.yml` | Gate famille d'OS |
| `.gitattributes` | Suivi Git LFS des artefacts |

**Modifiés**

| Fichier | Changement |
|---|---|
| `ansible/site.yml` | `cee_common` ajouté en tête |
| `ansible/roles/cee_preflight/tasks/main.yml` | Réduit au gate famille + dispatch |
| `ansible/roles/cee_install/tasks/main.yml` | Réduit au dispatch |
| `ansible/roles/cee_configure/tasks/main.yml` | Réduit au dispatch |
| `ansible/roles/cee_verify/tasks/main.yml` | Réduit au dispatch |
| `ansible/roles/cee_configure/handlers/main.yml` | Deux tâches en `listen:` |
| `ansible/requirements.yml` | `community.general`, `ansible.windows` |
| `ansible/group_vars/all.yml.example` | Perd `cee_log_path` |
| `ansible/inventory/hosts.yml.example` | Groupes `cee_linux` / `cee_windows` |
| `ansible/tests/test_required_vars.yml` | Chemins d'include |
| `ansible/tests/test_endpoint_validation.yml` | Chemins d'include |
| `ansible/tests/test_facility_gate.yml` | Chemins d'include |
| `ansible/tests/test_platform_assertions.yml` | Chemins d'include + cas SLES |
| `.github/workflows/ansible.yml` | Seed des trois `group_vars` |
| `CLAUDE.md`, `docs/ansible-deployment.md`, `docs/acceptance-tests.md`, `CHANGELOG.md` | Documentation |

**Supprimés**

`ansible/roles/cee_preflight/tasks/assert_platform.yml` (renommé), `bin/EMC_CEE_Pack_9_2_0_0.iso`, `bin/EMC_CEE_Pack_9_2_2_0.iso`, `bin/EMC_CEE_Pack_x64_9_3_0_0.exe`, `bin/emc_cee_SLES-9.2.0.0.i386.rpm`.

`ansible/tests/test_template_render.yml` n'est **pas** touché : il référence directement `../roles/cee_configure/templates/emc_cee_config.xml.j2`, qui ne bouge pas.

---

# Phase 1 — sans dépendance Windows

## Task 1 : Extraire le rôle `cee_common`

**Files:**
- Create: `ansible/roles/cee_common/tasks/main.yml`
- Move: `ansible/roles/cee_preflight/tasks/assert_required_vars.yml` → `ansible/roles/cee_common/tasks/`
- Move: `ansible/roles/cee_configure/tasks/validate_endpoints.yml` → `ansible/roles/cee_common/tasks/`
- Move: `ansible/roles/cee_configure/tasks/assert_facilities.yml` → `ansible/roles/cee_common/tasks/`
- Modify: `ansible/site.yml`
- Modify: `ansible/roles/cee_preflight/tasks/main.yml`
- Modify: `ansible/roles/cee_configure/tasks/main.yml`
- Test: `ansible/tests/test_required_vars.yml`, `ansible/tests/test_endpoint_validation.yml`, `ansible/tests/test_facility_gate.yml`

**Interfaces:**
- Produces: le rôle `cee_common`, à inclure en tête de `site.yml`. Ses trois fichiers de tâches sont incluables par chemin relatif depuis `ansible/tests/` sous `../roles/cee_common/tasks/<nom>.yml`.
- Consumes: rien.

- [ ] **Step 1 : Établir la ligne de base verte**

```bash
ansible-galaxy collection install -r ansible/requirements.yml
ansible/tests/run.sh
```

Attendu : `All Ansible tests passed.` Si ça échoue déjà, arrêter et régler avant toute chose — le reste du plan suppose une base verte.

- [ ] **Step 2 : Repointer les includes des tests vers `cee_common`**

Dans `ansible/tests/test_required_vars.yml`, remplacer les 4 occurrences :

```
../roles/cee_preflight/tasks/assert_required_vars.yml
```

par :

```
../roles/cee_common/tasks/assert_required_vars.yml
```

Dans `ansible/tests/test_endpoint_validation.yml`, remplacer les 7 occurrences :

```
../roles/cee_configure/tasks/validate_endpoints.yml
```

par :

```
../roles/cee_common/tasks/validate_endpoints.yml
```

Dans `ansible/tests/test_facility_gate.yml`, remplacer les 4 occurrences :

```
../roles/cee_configure/tasks/assert_facilities.yml
```

par :

```
../roles/cee_common/tasks/assert_facilities.yml
```

- [ ] **Step 3 : Lancer les tests pour les voir échouer**

```bash
ansible/tests/run.sh
```

Attendu : ÉCHEC sur `test_endpoint_validation.yml` (premier par ordre alphabétique parmi les trois modifiés), avec un message de la forme `Could not find or access '../roles/cee_common/tasks/validate_endpoints.yml'`.

C'est le point du cycle : les tests exigent le nouvel emplacement avant qu'il existe.

- [ ] **Step 4 : Déplacer les trois gates**

```bash
mkdir -p ansible/roles/cee_common/tasks
git mv ansible/roles/cee_preflight/tasks/assert_required_vars.yml ansible/roles/cee_common/tasks/
git mv ansible/roles/cee_configure/tasks/validate_endpoints.yml ansible/roles/cee_common/tasks/
git mv ansible/roles/cee_configure/tasks/assert_facilities.yml ansible/roles/cee_common/tasks/
```

Ne pas éditer le contenu de ces trois fichiers. Ils sont neutres tels quels ; les commentaires internes qui justifient leur forme (asserts non bouclés, ordre entier-avant-plage) restent valables mot pour mot.

- [ ] **Step 5 : Écrire `cee_common/tasks/main.yml`**

```yaml
---
# Platform-neutral gates, shared by every supported OS.
#
# Everything in this role operates on variables only, in pure Jinja, with
# no module whose behaviour depends on the target platform. That is what
# lets ansible/tests/ exercise the whole gate suite on a localhost control
# node with no VM, no CEE install and no network — and it is why the same
# three files serve RHEL, SLES and Windows without being rewritten.
#
# Keep it that way. A gate that needs a module belongs in the platform
# branch of cee_preflight, not here.
#
# Order matters. assert_required_vars runs first so that a missing
# group_vars/all.yml is named here, rather than surfacing several tasks
# later as a raw Jinja undefined against the wrong task.

- name: Assert every required variable is defined
  ansible.builtin.include_tasks: assert_required_vars.yml

# These two used to live in cee_configure, which ran after cee_install.
# Their own comments claim they are "enforced before anything is written
# to the target host" — a promise that position did not quite keep. Here
# it does: nothing has touched the host yet.
- name: Validate endpoints before touching the host
  ansible.builtin.include_tasks: validate_endpoints.yml

- name: Assert the sub-facility selection is one CEE will actually publish
  ansible.builtin.include_tasks: assert_facilities.yml
```

- [ ] **Step 6 : Retirer les includes déplacés de leurs anciens rôles**

Dans `ansible/roles/cee_preflight/tasks/main.yml`, supprimer les 4 premières lignes de tâche :

```yaml
# First task in the first role, on purpose: nothing else in this playbook
# should run before the variables it depends on are known to exist.
- name: Assert every required variable is defined
  ansible.builtin.include_tasks: assert_required_vars.yml
```

Le fichier commence désormais par `- name: Gather facts needed for the platform gate`.

Dans `ansible/roles/cee_configure/tasks/main.yml`, supprimer les deux premières tâches :

```yaml
- name: Validate endpoints before touching the host
  ansible.builtin.include_tasks: validate_endpoints.yml

- name: Assert the sub-facility selection is one CEE will actually publish
  ansible.builtin.include_tasks: assert_facilities.yml
```

Le fichier commence désormais par `- name: Render the CEE configuration`.

- [ ] **Step 7 : Ajouter `cee_common` à `site.yml`**

```yaml
---
- name: Deploy Dell CEE
  hosts: cee
  gather_facts: true
  roles:
    # Variable, endpoint and sub-facility gates. First, and platform-neutral:
    # every one of these can fail before a single byte reaches the host.
    - cee_common
    - cee_preflight
    - cee_install
    - cee_configure
    - cee_verify
```

Le nom du play perd « to a RHEL 9 host » : il en couvrira trois.

- [ ] **Step 8 : Lancer les tests pour les voir passer**

```bash
ansible/tests/run.sh
```

Attendu : `All Ansible tests passed.`

- [ ] **Step 9 : Lint et syntax check**

```bash
yamllint ansible/ .github/
cp -n ansible/inventory/hosts.yml.example ansible/inventory/hosts.yml
cp -n ansible/group_vars/all.yml.example ansible/group_vars/all.yml
(cd ansible && ansible-playbook --syntax-check site.yml)
ansible-lint ansible/
```

Attendu : aucune sortie de `yamllint`, `syntax check` OK, `ansible-lint` sans violation.

- [ ] **Step 10 : Commit**

```bash
git add ansible/roles/cee_common ansible/roles/cee_preflight/tasks/main.yml \
        ansible/roles/cee_configure/tasks/main.yml ansible/site.yml \
        ansible/tests/test_required_vars.yml ansible/tests/test_endpoint_validation.yml \
        ansible/tests/test_facility_gate.yml
git commit -m "refactor(ansible): extract platform-neutral gates into cee_common

The three gates operate on variables only, in pure Jinja, so they serve
every supported OS unchanged. Moving them into their own role is what
lets SLES and Windows reuse the subtle logic — endpoint ordering, plain
integer ports, audit-only sub-facility — instead of duplicating it.

Side effect, and the point: endpoint and sub-facility validation now runs
before cee_install rather than after, which is what their own comments
already claimed."
```

---

## Task 2 : Dispatch par famille d'OS, RHEL seul

Restructuration pure. Aucun changement de comportement sur un hôte RHEL 9 : la suite de tests doit rester verte du début à la fin de cette tâche.

**Files:**
- Create: `ansible/roles/cee_preflight/tasks/RedHat.yml`
- Create: `ansible/roles/cee_preflight/tasks/preflight_linux.yml`
- Rename: `ansible/roles/cee_preflight/tasks/assert_platform.yml` → `assert_platform_RedHat.yml`
- Create: `ansible/roles/cee_install/tasks/RedHat.yml`
- Create: `ansible/roles/cee_configure/tasks/Linux.yml`
- Create: `ansible/roles/cee_verify/tasks/Linux.yml`
- Modify: les quatre `tasks/main.yml` correspondants
- Modify: `ansible/roles/cee_configure/handlers/main.yml`
- Test: `ansible/tests/test_platform_assertions.yml`, `ansible/tests/test_platform_dispatch.yml`

**Interfaces:**
- Consumes: le rôle `cee_common` de la Task 1.
- Produces: la convention de dispatch `include_tasks: "{{ ansible_os_family }}.yml"` dans `cee_preflight` et `cee_install` ; `include_tasks: Linux.yml` dans `cee_configure` et `cee_verify`. Le gate famille d'OS vit dans `cee_preflight/tasks/main.yml` et nulle part ailleurs. Le handler s'appelle toujours `Restart emc_cee` — les `notify:` existants ne changent pas.

- [ ] **Step 1 : Écrire le test du gate famille d'OS**

Créer `ansible/tests/test_platform_dispatch.yml` :

```yaml
---
# The OS-family gate. Without it, an unsupported family reaches
# include_tasks and fails with a bare "Could not find or access
# 'Debian.yml'" — an error that names a missing file instead of an
# unsupported operating system.

- name: An unsupported OS family is rejected by name
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    ansible_os_family: Debian
  tasks:
    - name: Expect the OS-family gate to fail
      block:
        - name: Assert the OS family
          ansible.builtin.include_tasks: ../roles/cee_preflight/tasks/assert_os_family.yml
        - name: Should be unreachable
          ansible.builtin.fail:
            msg: "The OS-family gate did not reject Debian."
      rescue:
        - name: Confirm it failed for the OS-family reason
          ansible.builtin.assert:
            that:
              - "'supports RHEL 9 and SLES 15' in (ansible_failed_result.msg | default('') | string)"
            fail_msg: "Failed, but not with the unsupported-OS-family message."

- name: The RedHat family is accepted
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    ansible_os_family: RedHat
  tasks:
    - name: Assert the OS family
      ansible.builtin.include_tasks: ../roles/cee_preflight/tasks/assert_os_family.yml
```

Noter : le gate est extrait dans son propre fichier `assert_os_family.yml`, pour la même raison que tous les autres gates du dépôt — pouvoir être inclus par les tests avec des faits volontairement faux.

- [ ] **Step 2 : Lancer le test pour le voir échouer**

```bash
ansible-playbook ansible/tests/test_platform_dispatch.yml
```

Attendu : ÉCHEC avec `Could not find or access '../roles/cee_preflight/tasks/assert_os_family.yml'`.

- [ ] **Step 3 : Écrire le gate famille d'OS**

Créer `ansible/roles/cee_preflight/tasks/assert_os_family.yml` :

```yaml
---
# OS-family gate. Isolated from main.yml so tests/ can include it directly
# with overridden facts.
#
# This gate lives in cee_preflight and nowhere else. cee_preflight is the
# first role of the play and its failure aborts the run, so cee_install,
# cee_configure and cee_verify cannot be reached with an unsupported
# family. Three more copies would be noise.
#
# Note the asymmetry with assert_platform_*.yml: dispatch keys on
# ansible_os_family, the platform gates key on ansible_distribution. That
# is deliberate. Rocky and AlmaLinux report ansible_os_family == 'RedHat',
# so they are routed to RedHat.yml, where the strict
# ansible_distribution == 'RedHat' check rejects them and says why. The
# dispatch routes; the gate judges.

- name: The OS family must be one this playbook supports
  ansible.builtin.assert:
    that:
      - ansible_os_family in ['RedHat', 'Suse']
    fail_msg: >-
      ansible_os_family is '{{ ansible_os_family }}'. This playbook
      supports RHEL 9 and SLES 15. Windows Server is planned but not yet
      implemented — see docs/superpowers/plans/2026-08-10-cee-multiplateforme.md,
      phase 2. Without this assertion the dispatch below would fail with
      "Could not find or access '{{ ansible_os_family }}.yml'", naming a
      missing file rather than an unsupported operating system.
```

- [ ] **Step 4 : Lancer le test pour le voir passer**

```bash
ansible-playbook ansible/tests/test_platform_dispatch.yml
```

Attendu : les deux plays passent, `failed=0`.

- [ ] **Step 5 : Mutation-tester le nouveau gate**

Convention du dépôt : tout test négatif doit être vu en échec quand sa garde est désactivée.

Dans `assert_os_family.yml`, remplacer temporairement la condition par `- true`, puis :

```bash
ansible-playbook ansible/tests/test_platform_dispatch.yml
```

Attendu : ÉCHEC sur `The OS-family gate did not reject Debian.` Restaurer ensuite la condition et relancer pour retrouver le vert.

- [ ] **Step 6 : Renommer le gate plateforme RHEL et repointer son test**

```bash
git mv ansible/roles/cee_preflight/tasks/assert_platform.yml \
       ansible/roles/cee_preflight/tasks/assert_platform_RedHat.yml
```

Dans `ansible/tests/test_platform_assertions.yml`, remplacer les 3 occurrences de :

```
../roles/cee_preflight/tasks/assert_platform.yml
```

par :

```
../roles/cee_preflight/tasks/assert_platform_RedHat.yml
```

Le contenu du gate ne change pas.

- [ ] **Step 7 : Extraire le corps Linux de `cee_preflight`**

Créer `ansible/roles/cee_preflight/tasks/preflight_linux.yml` en y déplaçant, **inchangées**, les tâches actuelles de `cee_preflight/tasks/main.yml` à partir de `Check whether chrony is present` jusqu'à la fin du fichier :

```yaml
---
# Host checks shared by RHEL and SLES. Both use chrony and both run a
# Python interpreter, so the same modules serve them.
#
# This file has no Windows counterpart by accident: chronyc and
# ansible.builtin.wait_for are POSIX modules executed target-side under
# Python, and a Windows Server has neither. The Windows branch reimplements
# the same two checks with w32tm and ansible.windows.win_wait_for.

- name: Check whether chrony is present
  ansible.builtin.stat:
    path: /usr/bin/chronyc
  register: cee_preflight_chronyc

- name: Time must be synchronised
  when: cee_preflight_chronyc.stat.exists
  block:
    - name: Query chrony tracking state
      ansible.builtin.command: chronyc tracking
      register: cee_preflight_chrony_tracking
      changed_when: false
      failed_when: false

    - name: Clock must not be unsynchronised
      ansible.builtin.assert:
        that:
          - cee_preflight_chrony_tracking.rc == 0
          - "'Not synchronised' not in cee_preflight_chrony_tracking.stdout"
        fail_msg: >-
          Clock is not synchronised. The PowerStore array, this CEE host and
          the consumer must agree on time or events are rejected or
          misordered. Fix chrony before continuing.

- name: Warn when chrony is absent
  ansible.builtin.debug:
    msg: >-
      chronyc not found — time synchronisation could not be verified.
      PowerStore, CEE and the consumer must share synchronised time.
  when: not cee_preflight_chronyc.stat.exists

- name: Check whether the CEE port is already in use
  ansible.builtin.wait_for:
    port: "{{ cee_http_port }}"
    host: 127.0.0.1
    state: stopped
    timeout: 3
  register: cee_preflight_port_free
  # Use ignore_errors rather than failed_when: false to preserve the module's real
  # failure status so the downstream 'is failed' check can detect port conflicts
  ignore_errors: true

- name: Report a pre-existing listener on the CEE port
  ansible.builtin.debug:
    msg: >-
      Something is already listening on {{ cee_http_port }}. If this is a
      previous emc_cee instance the playbook will reconfigure it; if it is
      another service, CEE will fail to bind.
  when: cee_preflight_port_free is failed
```

- [ ] **Step 8 : Écrire la branche RHEL de `cee_preflight`**

Créer `ansible/roles/cee_preflight/tasks/RedHat.yml` :

```yaml
---
- name: Assert the platform is genuine RHEL 9
  ansible.builtin.include_tasks: assert_platform_RedHat.yml

- name: Run the Linux preflight checks
  ansible.builtin.include_tasks: preflight_linux.yml
```

- [ ] **Step 9 : Réduire `cee_preflight/tasks/main.yml` au gate et au dispatch**

Remplacer intégralement le contenu du fichier par :

```yaml
---
# Platform dispatch. cee_common has already run every variable, endpoint
# and sub-facility gate, so by the time we get here the configuration is
# known good and the only open question is what kind of host this is.

- name: Gather facts needed for the platform gate
  ansible.builtin.setup:
    gather_subset:
      - distribution

- name: Assert the OS family is supported
  ansible.builtin.include_tasks: assert_os_family.yml

- name: Run the platform-specific preflight
  ansible.builtin.include_tasks: "{{ ansible_os_family }}.yml"
```

- [ ] **Step 10 : Déplacer `cee_install` sous `RedHat.yml`**

```bash
git mv ansible/roles/cee_install/tasks/main.yml \
       ansible/roles/cee_install/tasks/RedHat.yml
```

Le contenu ne change pas : le bloc `ubi.repo`, le glob `emc_cee_RHEL-*.x86_64.rpm` et le long commentaire justifiant l'absence de `disable_gpg_check` sont spécifiques à RHEL et restent là.

Créer `ansible/roles/cee_install/tasks/main.yml` :

```yaml
---
# The OS-family gate lives in cee_preflight, which runs first and aborts
# the play on an unsupported family. By the time this dispatch runs,
# ansible_os_family is known to name a file that exists.

- name: Run the platform-specific installation
  ansible.builtin.include_tasks: "{{ ansible_os_family }}.yml"
```

- [ ] **Step 11 : Déplacer `cee_configure` et `cee_verify` sous `Linux.yml`**

```bash
git mv ansible/roles/cee_configure/tasks/main.yml \
       ansible/roles/cee_configure/tasks/Linux.yml
git mv ansible/roles/cee_verify/tasks/main.yml \
       ansible/roles/cee_verify/tasks/Linux.yml
```

Créer `ansible/roles/cee_configure/tasks/main.yml` :

```yaml
---
# RHEL and SLES share this role entirely. The two rpms ship an identical
# payload — same /opt/CEEPack, same emc_cee_config.xml, same
# emc_cee.service with WorkingDirectory=/opt/CEEPack and User=ceesvc — so
# there is nothing to branch on between them.
#
# Phase 2 turns this into a two-way dispatch: Windows configures through
# HKLM registry keys, not the XML template.

- name: Run the platform-specific configuration
  ansible.builtin.include_tasks: Linux.yml
```

Créer `ansible/roles/cee_verify/tasks/main.yml` :

```yaml
---
# Shared by RHEL and SLES for the same reason as cee_configure. The fatal
# log line this role greps for — "Platform is not supported / qualified.
# CEE will now terminate." — is byte-identical in both builds.
#
# Phase 2 turns this into a two-way dispatch.

- name: Run the platform-specific verification
  ansible.builtin.include_tasks: Linux.yml
```

- [ ] **Step 12 : Rendre le handler conscient de la plateforme**

`cee_install` notifie `Restart emc_cee`, un handler défini dans `cee_configure/handlers/main.yml` qui appelle `systemd_service`. Sur Windows il exploserait. `listen:` permet de garder un seul nom notifié et deux implémentations.

Remplacer `ansible/roles/cee_configure/handlers/main.yml` par :

```yaml
---
# Two handler tasks, one notified name. Tasks in cee_install and
# cee_configure notify "Restart emc_cee" and stay unchanged; `listen`
# routes that notification to whichever implementation matches the host.
#
# A single systemd_service handler would fail on a Windows target, which
# has no systemd — and it would fail inside a handler, after the play has
# already changed the host's configuration.

- name: Restart emc_cee on Linux
  listen: Restart emc_cee
  ansible.builtin.systemd_service:
    name: emc_cee
    state: restarted
    daemon_reload: true
  become: true
  when: ansible_os_family != 'Windows'
```

La branche Windows de ce handler est ajoutée en phase 2 ; le `when` la rend inutile d'ici là.

- [ ] **Step 13 : Lancer toute la suite**

```bash
ansible/tests/run.sh
```

Attendu : `All Ansible tests passed.`, six playbooks exécutés.

- [ ] **Step 14 : Lint et syntax check**

```bash
yamllint ansible/ .github/
(cd ansible && ansible-playbook --syntax-check site.yml)
ansible-lint ansible/
```

Attendu : propre sur les trois.

- [ ] **Step 15 : Commit**

```bash
git add ansible/roles ansible/tests/test_platform_assertions.yml \
        ansible/tests/test_platform_dispatch.yml
git commit -m "refactor(ansible): dispatch the four roles on ansible_os_family

Pure restructuring — behaviour on a RHEL 9 host is unchanged.

Dispatch keys on ansible_os_family while the platform gates keep judging
on ansible_distribution. Rocky and AlmaLinux report os_family RedHat, so
they route to RedHat.yml where the strict distribution check rejects them
by name. The dispatch routes; the gate judges.

The OS-family gate lives in cee_preflight alone: it runs first and aborts
the play, so the later roles cannot be reached with a family that has no
task file.

The restart handler becomes two tasks behind one listen name, so a
Windows branch can be added in phase 2 without touching any notify."
```

---

## Task 3 : Gate plateforme SLES

**Files:**
- Create: `ansible/roles/cee_preflight/tasks/assert_platform_Suse.yml`
- Create: `ansible/roles/cee_preflight/tasks/Suse.yml`
- Test: `ansible/tests/test_platform_assertions.yml`

**Interfaces:**
- Consumes: `preflight_linux.yml` et la convention de dispatch de la Task 2.
- Produces: `assert_platform_Suse.yml`, incluable par les tests avec des faits surchargés.

- [ ] **Step 1 : Écrire les tests SLES**

Ajouter à la fin de `ansible/tests/test_platform_assertions.yml` :

```yaml
- name: openSUSE Leap is rejected
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    ansible_distribution: openSUSE Leap
    ansible_distribution_major_version: "15"
  tasks:
    - name: Expect the platform gate to fail
      block:
        - name: Assert platform
          ansible.builtin.include_tasks: ../roles/cee_preflight/tasks/assert_platform_Suse.yml
        - name: Should be unreachable
          ansible.builtin.fail:
            msg: "Validation did not reject openSUSE Leap."
      rescue:
        - name: Confirm it failed for the distribution reason
          ansible.builtin.assert:
            that:
              - "'/etc/os-release' in (ansible_failed_result.msg | default('') | string)"
            fail_msg: "Failed, but not with the enterprise-SLES message."

- name: SLES 12 is rejected
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    ansible_distribution: SLES
    ansible_distribution_major_version: "12"
  tasks:
    - name: Expect the platform gate to fail
      block:
        - name: Assert platform
          ansible.builtin.include_tasks: ../roles/cee_preflight/tasks/assert_platform_Suse.yml
        - name: Should be unreachable
          ansible.builtin.fail:
            msg: "Validation did not reject SLES major version 12."
      rescue:
        - name: Confirm it failed for the version reason
          ansible.builtin.assert:
            that:
              - "'requires SLES 15' in (ansible_failed_result.msg | default('') | string)"
            fail_msg: "Failed, but not with the major-version message."

- name: SLES 15 passes
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    ansible_distribution: SLES
    ansible_distribution_major_version: "15"
  tasks:
    - name: Assert platform
      ansible.builtin.include_tasks: ../roles/cee_preflight/tasks/assert_platform_Suse.yml
```

- [ ] **Step 2 : Lancer le test pour le voir échouer**

```bash
ansible-playbook ansible/tests/test_platform_assertions.yml
```

Attendu : ÉCHEC avec `Could not find or access '../roles/cee_preflight/tasks/assert_platform_Suse.yml'`.

- [ ] **Step 3 : Écrire le gate SLES**

Créer `ansible/roles/cee_preflight/tasks/assert_platform_Suse.yml` :

```yaml
---
# Platform gate, SUSE branch. Isolated from the dispatch so it can be
# tested with overridden facts on a workstation, exactly like the RedHat
# one.
#
# The SLES build of CEE reads /etc/os-release, /etc/redhat-release and
# /etc/SuSE-release, and accepts both the SLES and the Red Hat product
# strings — its platform check is a superset of the RHEL build's, not a
# different one. It fails with the same message: "Platform is not
# supported / qualified. CEE will now terminate."
#
# openSUSE Leap and Tumbleweed are rejected here for the same reason
# Rocky and AlmaLinux are rejected on the Red Hat side: CEE looks for the
# enterprise product string, and ABI compatibility does not help.

- name: Host must be SUSE Linux Enterprise Server
  ansible.builtin.assert:
    that:
      - ansible_distribution == 'SLES'
    fail_msg: >-
      Detected '{{ ansible_distribution }}'. CEE reads /etc/os-release and
      self-terminates with "Platform is not supported / qualified" unless
      it sees the SLES product string. openSUSE Leap and Tumbleweed fail
      this check despite being closely related to SLES.

- name: Host must be SLES major version 15
  ansible.builtin.assert:
    that:
      - ansible_distribution_major_version == '15'
    fail_msg: >-
      Detected SLES {{ ansible_distribution_major_version }}. This
      deployment requires SLES 15. The vendored rpm links against
      glibc 2.12+ symbols and ships its own boost, openssl, curl and
      jansson under /opt/CEEPack, so the host only has to supply glibc and
      a shell — but SLES 15 is the version this playbook has been written
      and gated for.
```

- [ ] **Step 4 : Lancer le test pour le voir passer**

```bash
ansible-playbook ansible/tests/test_platform_assertions.yml
```

Attendu : les six plays passent.

- [ ] **Step 5 : Mutation-tester les deux nouvelles gardes**

Désactiver la première : remplacer `- ansible_distribution == 'SLES'` par `- true`, relancer.
Attendu : ÉCHEC sur `Validation did not reject openSUSE Leap.` Restaurer.

Désactiver la seconde : remplacer `- ansible_distribution_major_version == '15'` par `- true`, relancer.
Attendu : ÉCHEC sur `Validation did not reject SLES major version 12.` Restaurer, relancer, retrouver le vert.

- [ ] **Step 6 : Écrire la branche SLES de `cee_preflight`**

Créer `ansible/roles/cee_preflight/tasks/Suse.yml` :

```yaml
---
- name: Assert the platform is SUSE Linux Enterprise Server 15
  ansible.builtin.include_tasks: assert_platform_Suse.yml

- name: Run the Linux preflight checks
  ansible.builtin.include_tasks: preflight_linux.yml
```

- [ ] **Step 7 : Suite complète, lint, commit**

```bash
ansible/tests/run.sh
yamllint ansible/ .github/
ansible-lint ansible/
git add ansible/roles/cee_preflight ansible/tests/test_platform_assertions.yml
git commit -m "feat(ansible): gate SLES 15 as a supported platform

The SLES build of CEE reads /etc/os-release, /etc/redhat-release and
/etc/SuSE-release and accepts both the SLES and Red Hat product strings.
openSUSE is rejected for the same reason Rocky is on the Red Hat side:
CEE wants the enterprise product string, ABI compatibility does not help.

Both negative cases mutation-tested."
```

---

## Task 4 : Branche d'installation SLES

**Files:**
- Create: `ansible/roles/cee_install/tasks/Suse.yml`
- Create: `ansible/roles/cee_install/tasks/install_linux_locate.yml`
- Create: `ansible/roles/cee_install/tasks/install_linux_verify.yml`
- Modify: `ansible/roles/cee_install/tasks/RedHat.yml`
- Modify: `ansible/requirements.yml`

**Interfaces:**
- Consumes: la convention de dispatch de la Task 2, le gate de la Task 3.
- Produces: `cee_install/tasks/Suse.yml`, qui laisse le même état sur disque que `RedHat.yml` — `/opt/CEEPack` peuplé, `emc_cee.service` en place, `{{ cee_log_path }}` créé et détenu par `ceesvc`.
- Produces: deux fichiers partagés par les deux branches Linux. Contrat :
  - `install_linux_locate.yml` **consomme** la variable `cee_install_rpm_glob` (nom de fichier avec joker, sans chemin) que l'appelant doit définir avant de l'inclure, et **produit** `cee_install_rpm_local` (chemin côté contrôleur) ainsi que le rpm copié dans `/tmp/` sur la cible.
  - `install_linux_verify.yml` **consomme** `cee_install_rpm_local` et `cee_log_path`. Aucune sortie.

**Note de factorisation** — décidée avant exécution, en écart avec la rédaction initiale de cette tâche.

Les deux branches Linux ne diffèrent réellement que par deux choses : le motif de glob et le module de paquet. Tout le reste — localiser, exiger exactement un rpm, copier, nettoyer le rpm intermédiaire, vérifier le layout, créer le répertoire de log — est identique, parce que les deux rpm livrent un layout identique (fait mesuré, cf. spec).

D'où deux fichiers partagés, sur le même modèle que `preflight_linux.yml` de la Task 2. La duplication n'est pas factorée en Task 2 parce qu'elle n'existe pas encore à ce moment-là : elle l'est ici, quand le second consommateur arrive.

- [ ] **Step 1 : Déclarer `community.general`**

Ajouter à `ansible/requirements.yml`, après l'entrée `ansible.posix` :

```yaml
  # community.general supplies community.general.zypper, used by the SLES
  # branch of cee_install. Like ansible.posix it is not bundled with
  # ansible-core, so its absence breaks --syntax-check and ansible-lint on
  # a clean checkout, not just deployment.
  #
  # Floor is 12.0.0 on purpose: that release removed the community.general
  # yaml stdout callback, and ansible.cfg documents having been bitten by
  # a control node where it was still expected. Requiring >= 12 makes the
  # removal a stated assumption rather than an accident of what happens to
  # be installed.
  - name: community.general
    version: ">=12.0.0"
```

`ansible.windows`, que le spec liste également, n'est **pas** ajoutée ici. Aucun module `win_*` n'existe dans l'arbre avant la phase 2 ; la déclarer maintenant imposerait un téléchargement en CI pour une collection dont rien ne dépend. Elle arrive avec le premier `Windows.yml`.

- [ ] **Step 2 : Vérifier que la collection s'installe**

```bash
ansible-galaxy collection install -r ansible/requirements.yml
ansible-doc -M community.general zypper >/dev/null && echo OK
```

Attendu : `OK`.

- [ ] **Step 3 : Extraire la partie « localiser et copier », partagée**

Créer `ansible/roles/cee_install/tasks/install_linux_locate.yml`, en y déplaçant les quatre premières tâches de `RedHat.yml` (de `Locate the bundled CEE rpm` à `Copy the CEE rpm to the target`), avec le glob paramétré :

```yaml
---
# Locate the vendored rpm on the controller and stage it on the target.
# Shared by the RHEL and SLES branches, which differ only in which rpm
# they are looking for.
#
# Consumes cee_install_rpm_glob — a filename pattern with no path, set by
# the caller immediately before including this file.
# Produces cee_install_rpm_local, and leaves the rpm in /tmp/ on the
# target for the caller's package module to install.
#
# Every supported glob ends in .x86_64.rpm, so the i386 build that Dell
# also ships cannot match and no explicit exclusion is needed.

- name: Locate the bundled CEE rpm
  ansible.builtin.set_fact:
    cee_install_rpm_candidates: >-
      {{ query('ansible.builtin.fileglob',
               playbook_dir + '/../bin/' + cee_install_rpm_glob) }}

- name: Exactly one CEE rpm must be present in bin/
  ansible.builtin.assert:
    that:
      - cee_install_rpm_candidates | length == 1
    fail_msg: >-
      Expected exactly one {{ cee_install_rpm_glob }} in bin/, found
      {{ cee_install_rpm_candidates | length }}. Remove the old rpm before
      adding a new one — the Dockerfile globs the same directory and has
      the same requirement.

- name: Record the rpm path
  ansible.builtin.set_fact:
    cee_install_rpm_local: "{{ cee_install_rpm_candidates[0] }}"

- name: Copy the CEE rpm to the target
  ansible.builtin.copy:
    src: "{{ cee_install_rpm_local }}"
    dest: /tmp/{{ cee_install_rpm_local | basename }}
    owner: root
    group: root
    mode: "0644"
  become: true
```

- [ ] **Step 4 : Extraire la partie post-installation, partagée**

Créer `ansible/roles/cee_install/tasks/install_linux_verify.yml`, en y déplaçant les quatre dernières tâches de `RedHat.yml`, inchangées (de `Remove the staged rpm` à la création du répertoire de log) :

```yaml
---
# Post-install cleanup and layout check, shared by the RHEL and SLES
# branches. Both rpms ship an identical payload — same /opt/CEEPack, same
# unit file — so there is nothing to branch on here.
#
# Consumes cee_install_rpm_local and cee_log_path.
#
# The staged-rpm removal lives here rather than in the locate file because
# it can only run once the package module has consumed the file.

- name: Remove the staged rpm
  ansible.builtin.file:
    path: /tmp/{{ cee_install_rpm_local | basename }}
    state: absent
  become: true

- name: Verify the CEE layout
  ansible.builtin.stat:
    path: "{{ item }}"
  register: cee_install_layout
  loop:
    - /opt/CEEPack/emc_cee.exe
    - /opt/CEEPack/emc_cee_svc
    - /etc/systemd/system/emc_cee.service
  become: true

- name: Every expected CEE path must exist
  ansible.builtin.assert:
    that:
      - item.stat.exists
    fail_msg: >-
      {{ item.item }} is missing after install. The rpm layout changed, or
      the install silently failed. The unit name this playbook manages is
      `emc_cee`; if the rpm now ships a different unit, update
      cee_configure and cee_verify to match.
  loop: "{{ cee_install_layout.results }}"
  loop_control:
    label: "{{ item.item }}"

- name: Ensure the log directory exists and is writable by the service user
  ansible.builtin.file:
    path: "{{ cee_log_path }}"
    state: directory
    owner: ceesvc
    group: ceesvc
    mode: "0750"
  become: true
```

- [ ] **Step 5 : Réduire `RedHat.yml` à ce qui lui est propre**

Après extraction, `ansible/roles/cee_install/tasks/RedHat.yml` conserve **uniquement** le bloc `ubi.repo`, la déclaration du glob, les deux includes et la tâche `dnf`. Le long commentaire justifiant l'absence de `disable_gpg_check` reste attaché à la tâche `dnf`, inchangé — il parle de `--nogpgcheck` et des dépôts UBI, tous deux spécifiques à cette branche.

```yaml
---
- name: Install UBI 9 repositories, disabled by default
  # The repo definitions land on the host permanently but ship
  # `enabled = 0`; the dnf task below switches them on for its own
  # transaction with `enablerepo`. See files/ubi.repo for why.
  ansible.builtin.copy:
    src: ubi.repo
    dest: /etc/yum.repos.d/ubi.repo
    owner: root
    group: root
    mode: "0644"
  become: true

- name: Look for the RHEL build of the rpm
  ansible.builtin.set_fact:
    cee_install_rpm_glob: emc_cee_RHEL-*.x86_64.rpm

- name: Locate and stage the rpm
  ansible.builtin.include_tasks: install_linux_locate.yml

- name: Install CEE
  # <<< the existing disable_gpg_check / enablerepo comment block, moved
  # here verbatim from the pre-refactor file >>>
  ansible.builtin.dnf:
    name: /tmp/{{ cee_install_rpm_local | basename }}
    state: present
    enablerepo:
      - ubi-9-baseos-rpms
      - ubi-9-appstream-rpms
  become: true
  notify: Restart emc_cee

- name: Verify the installed layout
  ansible.builtin.include_tasks: install_linux_verify.yml
```

- [ ] **Step 6 : Écrire la branche SLES**

Créer `ansible/roles/cee_install/tasks/Suse.yml` :

```yaml
---
# SLES branch. Deliberately shorter than RedHat.yml, and the difference is
# not an oversight.
#
# There is no repository setup here. The RHEL branch installs ubi.repo and
# enables it for one transaction because a minimal RHEL host may lack the
# dependencies dnf needs to resolve. The SLES rpm needs nothing of the
# sort: boost 1.88, openssl 3, libcurl 4 and jansson 4 all ship inside
# /opt/CEEPack, so the external dependency surface is glibc, ld-linux and
# a shell — present on any SLES 15 install. Verified by comparing the
# declared requires of both rpms: identical bar /bin/bash against
# /usr/bin/bash.

- name: Look for the SLES build of the rpm
  ansible.builtin.set_fact:
    cee_install_rpm_glob: emc_cee_SLES-*.x86_64.rpm

- name: Locate and stage the rpm
  ansible.builtin.include_tasks: install_linux_locate.yml

- name: Install CEE
  # Deliberately no disable_gpg_check, for the same reason the RHEL branch
  # avoids it: the option is transaction-wide, so it would also suppress
  # verification of anything zypper pulls in alongside the local rpm.
  #
  # The rpm IS signed (RSA/SHA256, fingerprint
  # F85417992FA59E0A84F1E2CCF4A476D807DD4467) but Dell distributes the
  # signing key only through their authenticated support portal, so it
  # cannot be vendored here. zypper will warn about the unknown key and
  # proceed for a local package file; repo-sourced packages keep their
  # normal verification.
  community.general.zypper:
    name: /tmp/{{ cee_install_rpm_local | basename }}
    state: present
  become: true
  notify: Restart emc_cee

- name: Verify the installed layout
  ansible.builtin.include_tasks: install_linux_verify.yml
```

- [ ] **Step 7 : Suite, lint, syntax check**

```bash
ansible/tests/run.sh
yamllint ansible/ .github/
(cd ansible && ansible-playbook --syntax-check site.yml)
ansible-lint ansible/
```

Attendu : propre partout. La branche SLES n'est pas exécutée par les tests localhost — ils n'exercent que les gates — mais `--syntax-check` et `ansible-lint` la parcourent, ce qui attrape un module mal nommé ou un YAML invalide.

Contrôle supplémentaire : la refactorisation de `RedHat.yml` ne doit rien avoir changé pour RHEL. Comparer l'ordre des tâches avant/après :

```bash
git show HEAD:ansible/roles/cee_install/tasks/RedHat.yml | grep '^- name:'
grep -h '^- name:' ansible/roles/cee_install/tasks/RedHat.yml \
                   ansible/roles/cee_install/tasks/install_linux_locate.yml \
                   ansible/roles/cee_install/tasks/install_linux_verify.yml
```

Les mêmes tâches doivent apparaître, dans le même ordre effectif : repos, locate, assert, record, copy, install, remove, stat, assert layout, log dir.

- [ ] **Step 8 : Commit**

```bash
git add ansible/roles/cee_install/tasks ansible/requirements.yml
git commit -m "feat(ansible): install CEE on SLES 15 via zypper

No repository setup, unlike the RHEL branch: the rpm ships boost,
openssl, curl and jansson inside /opt/CEEPack, leaving glibc and a shell
as the only external dependencies. Verified by comparing the declared
requires of both rpms — identical bar /bin/bash vs /usr/bin/bash.

The two branches differ only in the glob and the package module, so
locating, staging, cleanup and the layout check move into shared task
files. Factored here rather than when RedHat.yml was created, because
this is where the second consumer appears.

Every supported glob ends in .x86_64.rpm, so Dell's i386 build cannot
match it and needs no explicit exclusion."
```

---

## Task 5 : Découpe des `group_vars` et de l'inventaire

**Files:**
- Modify: `ansible/group_vars/all.yml.example`
- Create: `ansible/group_vars/cee_linux.yml.example`
- Create: `ansible/group_vars/cee_windows.yml.example`
- Modify: `ansible/inventory/hosts.yml.example`
- Modify: `.gitignore`
- Modify: `.github/workflows/ansible.yml`

**Interfaces:**
- Consumes: rien des tâches précédentes.
- Produces: `cee_log_path` défini par groupe d'OS ; les groupes d'inventaire `cee_linux` et `cee_windows`, enfants de `cee`.

- [ ] **Step 1 : Retirer `cee_log_path` de `all.yml.example`**

Supprimer de `ansible/group_vars/all.yml.example` la ligne :

```yaml
cee_log_path: /opt/CEEPack/logs/
```

et remplacer le commentaire qui la précède (`# Logging and tuning. cee_log_path must end with a trailing slash.`) par :

```yaml
# Tuning. cee_log_path is NOT here: /opt/CEEPack/logs/ is meaningless on
# Windows, so it lives in group_vars/cee_linux.yml and
# group_vars/cee_windows.yml instead.
```

- [ ] **Step 2 : Écrire `cee_linux.yml.example`**

Créer `ansible/group_vars/cee_linux.yml.example` :

```yaml
---
# Copy to cee_linux.yml. Applies to every host in the cee_linux group —
# both RHEL 9 and SLES 15, which share an identical CEE layout.

# Where CEE writes its log. Must end with a trailing slash: the config
# template interpolates it verbatim.
#
# cee_verify treats an empty log directory as a failure, because that was
# exactly the container's silent-failure signature.
cee_log_path: /opt/CEEPack/logs/
```

- [ ] **Step 3 : Écrire `cee_windows.yml.example`**

Créer `ansible/group_vars/cee_windows.yml.example` :

```yaml
---
# Copy to cee_windows.yml. Applies to every host in the cee_windows group.
#
# PHASE 2: the roles do not yet implement the Windows branch. The
# OS-family gate in cee_preflight rejects Windows by name until they do.
# This file exists so the connection settings are documented and CI can
# seed it alongside the others.

# Ansible reaches Windows Server over OpenSSH here, not WinRM. The SSH
# server's DefaultShell must be PowerShell for ansible_shell_type below to
# match; if it is left as cmd, set ansible_shell_type: cmd instead.
#
# Note there is no credential delegation over this transport, unlike
# WinRM with CredSSP. It does not matter for this deployment: the
# installer is copied to the host before it runs, so nothing needs a
# second hop to a network share.
ansible_connection: ssh
ansible_shell_type: powershell

# Where CEE writes its log on Windows. Trailing separator required, same
# as the Linux path.
#
# PHASE 2: confirm this against a real install before trusting it — the
# default log location has not been verified on a Windows host.
cee_log_path: 'C:\Program Files\EMC\CEE\logs\'
```

- [ ] **Step 4 : Ajouter les groupes à l'inventaire d'exemple**

Remplacer le bloc `all:` de `ansible/inventory/hosts.yml.example` par :

```yaml
all:
  children:
    cee:
      children:
        # Two child groups whose only job is to carry per-OS variables:
        # cee_log_path for both, plus the connection settings for Windows.
        # site.yml still runs a single play over the cee group.
        cee_linux:
          hosts:
            cee01.example.com:
              ansible_host: 10.10.10.20
              # An ordinary login, not root. Every task in every role that
              # needs privilege declares `become: true`, so sudo supplies it;
              # this account only needs passwordless sudo (or run the playbook
              # with --ask-become-pass). Direct root SSH is not required and
              # most hardened RHEL 9 builds disable it anyway.
              ansible_user: ceeadmin
              #
              # ansible.cfg keeps host_key_checking on. Accept the host key
              # once before the first unattended run, or ansible waits on a
              # prompt nobody is there to answer:
              #     ssh-keyscan -H 10.10.10.20 >> ~/.ssh/known_hosts

        # PHASE 2 — the roles reject Windows by name until the Windows
        # branch lands. Leave this group empty until then.
        cee_windows:
          hosts: {}
```

Mettre également à jour l'en-tête du fichier, qui affirme aujourd'hui « The CEE host must be genuine RHEL 9 » :

```yaml
# Copy to hosts.yml and edit. hosts.yml is gitignored.
#
# Linux CEE hosts must be genuine RHEL 9 or SLES 15 — the playbook refuses
# to continue otherwise, because CEE self-terminates on rebuilds such as
# Rocky, AlmaLinux and openSUSE.
```

- [ ] **Step 5 : Gitignorer les vrais `group_vars`**

Remplacer dans `.gitignore` :

```
ansible/group_vars/all.yml
```

par :

```
ansible/group_vars/all.yml
ansible/group_vars/cee_linux.yml
ansible/group_vars/cee_windows.yml
```

- [ ] **Step 6 : Seeder les trois fichiers en CI**

Dans `.github/workflows/ansible.yml`, remplacer l'étape `Seed inventory and vars from the committed examples` par :

```yaml
      - name: Seed inventory and vars from the committed examples
        run: |
          cp ansible/inventory/hosts.yml.example ansible/inventory/hosts.yml
          cp ansible/group_vars/all.yml.example ansible/group_vars/all.yml
          cp ansible/group_vars/cee_linux.yml.example ansible/group_vars/cee_linux.yml
          cp ansible/group_vars/cee_windows.yml.example ansible/group_vars/cee_windows.yml
```

- [ ] **Step 7 : Reproduire la CI localement**

```bash
rm -f ansible/inventory/hosts.yml ansible/group_vars/all.yml \
      ansible/group_vars/cee_linux.yml ansible/group_vars/cee_windows.yml
cp ansible/inventory/hosts.yml.example ansible/inventory/hosts.yml
cp ansible/group_vars/all.yml.example ansible/group_vars/all.yml
cp ansible/group_vars/cee_linux.yml.example ansible/group_vars/cee_linux.yml
cp ansible/group_vars/cee_windows.yml.example ansible/group_vars/cee_windows.yml
yamllint ansible/ .github/
(cd ansible && ansible-playbook --syntax-check site.yml)
ansible-lint ansible/
ansible/tests/run.sh
```

Attendu : propre partout.

- [ ] **Step 8 : Vérifier qu'aucun vrai fichier de vars n'est suivi**

```bash
git status --porcelain ansible/group_vars/ ansible/inventory/
```

Attendu : seuls les `.example` apparaissent. Si `cee_linux.yml` ou `cee_windows.yml` remontent, le `.gitignore` du Step 5 est faux — corriger avant de commiter.

- [ ] **Step 9 : Commit**

```bash
git add ansible/group_vars/*.example ansible/inventory/hosts.yml.example \
        .gitignore .github/workflows/ansible.yml
git commit -m "feat(ansible): split cee_log_path into per-OS group_vars

/opt/CEEPack/logs/ is meaningless on Windows, so cee_log_path drops out
of all.yml into cee_linux.yml and cee_windows.yml. Everything else in
all.yml is a CEE configuration value rather than a system path and stays
shared.

The inventory gains cee_linux and cee_windows child groups whose only job
is carrying those variables plus the Windows connection settings —
site.yml still runs one play over the cee group."
```

---

## Task 6 : Artefacts et Git LFS

**Files:**
- Create: `.gitattributes`
- Create: `bin/EMC_CEE_Pack_x64_9_2_0_0.exe` (extrait de l'ISO)
- Delete: `bin/EMC_CEE_Pack_9_2_0_0.iso`, `bin/EMC_CEE_Pack_9_2_2_0.iso`, `bin/EMC_CEE_Pack_x64_9_3_0_0.exe`, `bin/emc_cee_SLES-9.2.0.0.i386.rpm`

**Interfaces:**
- Consumes: rien.
- Produces: `bin/` contenant exactement trois artefacts, tous en 9.2.0.0, dont deux suivis par LFS et un — le rpm RHEL — resté blob ordinaire.

- [ ] **Step 1 : Vérifier que Git LFS est disponible**

```bash
git lfs version
```

Si la commande échoue : `brew install git-lfs`, puis `git lfs install`.

- [ ] **Step 2 : Écrire `.gitattributes`**

Créer `.gitattributes` à la racine :

```
# Vendor artefacts. The Windows installer alone is 91 MB; Git stores every
# revision of a binary blob in full, so these belong in LFS.
#
# This applies to future commits only. bin/emc_cee_RHEL-9.2.0.0.x86_64.rpm
# is already an ordinary blob in history and stays one — at 4 MB it does
# not justify the history rewrite that `git lfs migrate` would require.
bin/*.rpm filter=lfs diff=lfs merge=lfs -text
bin/*.exe filter=lfs diff=lfs merge=lfs -text
```

- [ ] **Step 3 : Extraire l'installeur Windows de l'ISO**

```bash
7z x -obin/ bin/EMC_CEE_Pack_9_2_0_0.iso EMC_CEE_Pack_x64_9_2_0_0.exe
ls -l bin/EMC_CEE_Pack_x64_9_2_0_0.exe
```

Attendu : un fichier de 91 529 240 octets.

Vérifier que c'est bien la version attendue :

```bash
strings -a bin/EMC_CEE_Pack_x64_9_2_0_0.exe | grep -c "9 . 2 . 0 . 0"
```

Attendu : un compte non nul. La chaîne de version est stockée en UTF-16, d'où les espaces entre les caractères.

- [ ] **Step 4 : Retirer les artefacts hors périmètre**

```bash
rm bin/EMC_CEE_Pack_9_2_0_0.iso \
   bin/EMC_CEE_Pack_9_2_2_0.iso \
   bin/EMC_CEE_Pack_x64_9_3_0_0.exe \
   bin/emc_cee_SLES-9.2.0.0.i386.rpm
ls -l bin/
```

Attendu : trois fichiers, tous en 9.2.0.0.

Aucun de ces quatre fichiers n'est suivi par git — ils n'ont jamais été commités — donc `rm` suffit, `git rm` échouerait.

- [ ] **Step 5 : Vérifier que les globs existants tiennent toujours**

```bash
ls bin/emc_cee_RHEL-*.x86_64.rpm | wc -l
ls bin/emc_cee_SLES-*.x86_64.rpm | wc -l
ls bin/*.rpm | wc -l
```

Attendu : `1`, `1`, `2`. Le troisième contrôle vise le `COPY bin/*.rpm` du Dockerfile — il copiera maintenant deux rpm dans l'image au lieu d'un.

- [ ] **Step 6 : Empêcher le rpm SLES d'atterrir dans l'image conteneur**

Le Dockerfile fait `COPY bin/*.rpm /tmp/` puis installe. Avec deux rpm présents, l'image UBI9 recevrait aussi le rpm SLES. Resserrer le glob dans `Dockerfile`, ligne 10 :

```dockerfile
COPY bin/emc_cee_RHEL-*.x86_64.rpm /tmp/
```

Le conteneur est un bac à sable RHEL/UBI9 et n'est pas étendu à SLES ; ce resserrement conserve son comportement actuel.

- [ ] **Step 7 : Vérifier que le conteneur construit toujours**

```bash
docker build -t cee-worker-lfs-check .
```

Attendu : build réussi. En cas d'indisponibilité de Docker, noter que l'étape est sautée plutôt que de la déclarer passée.

- [ ] **Step 8 : Suivre le nouvel artefact en LFS et commiter**

```bash
git lfs install
git add .gitattributes
git add bin/EMC_CEE_Pack_x64_9_2_0_0.exe bin/emc_cee_SLES-9.2.0.0.x86_64.rpm
git lfs ls-files
```

Attendu : `git lfs ls-files` liste les deux nouveaux fichiers. Il **ne doit pas** lister `emc_cee_RHEL-9.2.0.0.x86_64.rpm`, qui reste un blob ordinaire.

```bash
git add Dockerfile
git commit -m "chore: vendor the SLES rpm and Windows installer, via Git LFS

bin/ now holds exactly three artefacts, all 9.2.0.0, so the repo's
CEE-tracking version scheme needs no exception.

Dropped: both ISOs (343 MB of packaging around one 91 MB file we need),
the loose 9.3.0.0 installer (a separate release that would have broken
version alignment), and the 32-bit builds.

The Windows installer was extracted from EMC_CEE_Pack_9_2_0_0.iso, which
contains only Windows installers — no rpms.

New binaries go through LFS. The existing RHEL rpm stays an ordinary blob;
at 4 MB it does not justify rewriting history.

The Dockerfile glob is narrowed to the RHEL rpm so the SLES one does not
land in the UBI9 image."
```

---

## Task 7 : Documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/ansible-deployment.md`
- Modify: `docs/acceptance-tests.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: l'état du dépôt après les tâches 1 à 6.
- Produces: rien de consommé par du code.

- [ ] **Step 1 : Relire l'état réel avant d'écrire**

```bash
ls ansible/roles/*/tasks/
ls bin/
cat ansible/site.yml
```

La documentation de ce dépôt décrit des comportements précis et vérifiés. Écrire ces sections à partir de l'arbre réel, pas de mémoire.

- [ ] **Step 2 : Mettre `CLAUDE.md` à jour**

Sections à corriger, chacune affirmant aujourd'hui du RHEL-seul :

- « What this repo is » — cible RHEL 9 **et** SLES 15 ; Windows en phase 2, non implémenté
- « Architecture » — le tableau des rôles passe de quatre à cinq lignes, `cee_common` en tête, avec la mention que ses trois gates sont du Jinja pur et servent toutes les plateformes
- Ajouter la règle de dispatch : `ansible_os_family` route, `ansible_distribution` juge, et pourquoi (Rocky/Alma arrivent dans `RedHat.yml` et y sont rejetés nommément)
- « Constraints that bite » — ajouter que les rpm RHEL et SLES livrent un produit identique, donc `cee_configure` et `cee_verify` sont partagés ; ajouter que SLES n'a pas d'équivalent du bloc `ubi.repo` et pourquoi
- La ligne sur le rpm unique dans `bin/` — il y a maintenant deux rpm et un exe, chaque glob visant sa propre plateforme, et le Dockerfile vise explicitement le rpm RHEL
- « Commands » — mentionner les trois collections requises, pas seulement `ansible.posix`

- [ ] **Step 3 : Mettre `docs/ansible-deployment.md` à jour**

- Prérequis : RHEL 9 ou SLES 15 ; les trois collections
- Nouvelle section SLES : ce qui diffère de RHEL, soit l'absence de configuration de dépôts et rien d'autre
- Nouvelle section Windows marquée **phase 2, non implémentée**, décrivant les prérequis connus : OpenSSH côté Windows Server, `DefaultShell` en PowerShell, machine jointe au domaine
- Dépannage : ajouter que `ansible_os_family` non supporté est rejeté nommément par `cee_preflight`

- [ ] **Step 4 : Mettre `docs/acceptance-tests.md` à jour**

Ajouter une colonne ou une section plateforme. **Ne pas** affirmer que quoi que ce soit a été validé sur SLES : rien de ce plan n'a tourné contre du matériel réel, sur aucune des trois plateformes. Ce document est explicite sur ce que la CI prouve et ne prouve pas ; l'ajout doit l'être autant.

- [ ] **Step 5 : Mettre `CHANGELOG.md` à jour**

`CHANGELOG.md` est rédigé en anglais — garder cette langue.

Sous `## [Unreleased]`, section `### Added` :

```markdown
- SLES 15 as a supported Ansible target: platform gate, zypper install,
  mutation-tested negative tests.
- `cee_common` role holding the variable, endpoint and sub-facility
  gates, shared by every platform.
- SLES rpm and Windows installer vendored in `bin/`, tracked in Git LFS.
```

Section `### Changed` :

```markdown
- The four roles dispatch on `ansible_os_family`. No behaviour change on
  RHEL 9.
- `cee_log_path` moves out of `group_vars/all.yml` into per-OS files.
- Endpoint and sub-facility validation now runs before `cee_install`
  rather than after.
```

- [ ] **Step 6 : Vérifier et commiter**

```bash
yamllint ansible/ .github/
ansible/tests/run.sh
git add CLAUDE.md docs/ CHANGELOG.md
git commit -m "docs: cover SLES 15 and the multiplatform role structure

Records the dispatch rule — ansible_os_family routes, ansible_distribution
judges — and the measured fact behind the structure: the RHEL and SLES
rpms ship an identical payload, so cee_configure and cee_verify are
shared rather than branched.

acceptance-tests.md gains platform coverage without claiming anything has
run against real hardware. Nothing has, on any of the three."
```

---

## Task 8 : Relevé sur `winvm` — porte d'entrée de la phase 2

Cette tâche ne produit pas de code. Elle produit les quatre valeurs sans lesquelles la branche Windows ne peut pas être écrite honnêtement.

**Bloquée sur** : un Windows Server de test joint au domaine, OpenSSH activé. Machine éteinte au moment de la rédaction du plan.

**Files:**
- Create: `docs/superpowers/specs/2026-08-10-cee-windows-releve.md`

**Interfaces:**
- Consumes: `bin/EMC_CEE_Pack_x64_9_2_0_0.exe` de la Task 6.
- Produces: les quatre valeurs consommées par le plan de phase 2 — arborescence de registre, drapeaux silencieux, `product_id`, chemin de log.

- [ ] **Step 1 : Vérifier la connectivité Ansible**

```bash
ansible -i ansible/inventory/hosts.yml cee_windows -m ansible.windows.win_ping
```

Attendu : `pong`. En cas d'échec, vérifier côté serveur que `sshd` tourne, et que `DefaultShell` correspond bien à `ansible_shell_type` déclaré dans `group_vars/cee_windows.yml`.

- [ ] **Step 2 : Déterminer la variante InstallShield**

L'installeur est un « Setup Launcher Unicode » Flexera InstallShield 27.0.122. Deux familles de drapeaux existent et une seule s'applique.

Sur la VM, en PowerShell :

```powershell
.\EMC_CEE_Pack_x64_9_2_0_0.exe /s /v"/qn"
$LASTEXITCODE
```

Si l'installation démarre sans interface, c'est un projet InstallScript-MSI et ces drapeaux sont les bons.

Si rien ne se produit ou qu'une interface s'ouvre, c'est de l'InstallScript pur : enregistrer un fichier réponse, puis rejouer avec.

```powershell
.\EMC_CEE_Pack_x64_9_2_0_0.exe /r /f1"C:\temp\cee.iss"
.\EMC_CEE_Pack_x64_9_2_0_0.exe /s /f1"C:\temp\cee.iss" /f2"C:\temp\cee.log"
```

Consigner la variante retenue et la ligne de commande exacte.

- [ ] **Step 3 : Relever le `product_id`**

```powershell
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
              'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' |
  ForEach-Object { Get-ItemProperty $_.PSPath } |
  Where-Object { $_.DisplayName -like '*Common Event Enabler*' } |
  Select-Object DisplayName, DisplayVersion, PSChildName, UninstallString |
  Format-List
```

`PSChildName` donne le ProductCode, à passer en `product_id` de `win_package`. Consigner la valeur exacte, accolades comprises.

- [ ] **Step 4 : Relever l'arborescence de registre CEPA**

```powershell
Get-ChildItem -Recurse 'HKLM:\SOFTWARE\EMC' -ErrorAction SilentlyContinue |
  Select-Object -ExpandProperty Name
```

Puis, pour chaque clé contenant `CEE` ou `CEPP`, relever les valeurs :

```powershell
Get-ChildItem -Recurse 'HKLM:\SOFTWARE\EMC' -ErrorAction SilentlyContinue |
  ForEach-Object {
    $p = $_.PSPath
    Get-ItemProperty $p | Select-Object @{n='Key';e={$p}}, *
  } | Format-List
```

Consigner en particulier les valeurs correspondant à chaque variable du schéma partagé : `HttpPort`, l'équivalent de `ServerEnabled`, l'AccessList, les endpoints, les sub-facilities, le chemin de log, `CacheSize`, le nombre de threads, les niveaux debug et verbose.

Si `HKLM:\SOFTWARE\EMC` n'existe pas, chercher plus large :

```powershell
Get-ChildItem 'HKLM:\SOFTWARE' | Where-Object { $_.Name -match 'EMC|Dell|CEE' }
```

- [ ] **Step 5 : Relever le nom du service et le chemin de log**

```powershell
Get-Service | Where-Object { $_.DisplayName -like '*Event Enabler*' -or $_.Name -like '*cee*' } |
  Select-Object Name, DisplayName, Status, StartType | Format-List

Get-CimInstance Win32_Service |
  Where-Object { $_.Name -like '*cee*' } |
  Select-Object Name, PathName, StartName | Format-List
```

`PathName` donne le répertoire d'installation. Le chemin de log par défaut s'y trouve généralement ; le confirmer :

```powershell
Get-ChildItem -Recurse 'C:\Program Files\EMC' -Filter *.log -ErrorAction SilentlyContinue |
  Select-Object FullName, Length, LastWriteTime
```

- [ ] **Step 6 : Confirmer la chaîne fatale**

`cee_verify` détecte l'auto-terminaison en cherchant `Platform is not supported` dans le log. La chaîne complète est vérifiée dans les binaires Linux ; confirmer qu'elle est identique côté Windows :

```powershell
Select-String -Path 'C:\Program Files\EMC\CEE\logs\*.log' -Pattern 'Platform is not supported'
```

Sur un Windows Server légitime, la chaîne doit être **absente**. Consigner ce qui a été observé.

- [ ] **Step 7 : Consigner le relevé**

Écrire `docs/superpowers/specs/2026-08-10-cee-windows-releve.md` avec, pour chacun des six points ci-dessus, la commande exécutée et sa sortie réelle. Ne rien y écrire qui n'ait été observé sur la machine.

- [ ] **Step 8 : Commit**

```bash
git add docs/superpowers/specs/2026-08-10-cee-windows-releve.md
git commit -m "docs: record the Windows CEE facts harvested from the test VM

Registry tree, silent-install variant, ProductCode and default log path,
each with the command that produced it. These four values were the only
thing blocking the Windows branch, and none of them could be guessed:
an invented registry path yields a service that starts, listens, logs,
passes every check and forwards nothing."
```

---

# Phase 2 — bloquée sur `winvm`

Les tâches d'implémentation Windows ne sont **pas** écrites dans ce plan, et c'est délibéré.

Écrire aujourd'hui `win_regedit` sur une arborescence de registre inventée, ou `win_package` avec un `product_id` deviné, produirait exactement le mode de défaillance que ce dépôt existe pour empêcher : un service qui démarre, écoute son port, écrit un log, passe les quatre contrôles de `cee_verify` et ne transmet jamais rien.

Une fois la Task 8 terminée et son relevé commité, écrire un second plan — `docs/superpowers/plans/YYYY-MM-DD-cee-windows.md` — couvrant :

1. `cee_preflight/tasks/Windows.yml` et `assert_platform_Windows.yml` — Windows Server accepté, édition client rejetée ; horloge par `w32tm /query /status` ; sonde de port par `ansible.windows.win_wait_for`
2. `assert_os_family.yml` — `Windows` ajouté à la liste blanche, et le test de la Task 2 étendu en conséquence
3. `cee_install/tasks/Windows.yml` — `win_copy` puis `win_package` avec `product_id` et `arguments` relevés
4. `cee_configure/tasks/Windows.yml` — `win_regedit` sur l'arborescence relevée, `win_firewall_rule`, `win_service` ; le chemin où `cee_manage_firewall` vaut faux doit être aussi bruyant que sur Linux, parce que le pare-feu Windows ne filtre pas davantage le loopback que firewalld
5. `cee_verify/tasks/Windows.yml` — les mêmes quatre contrôles : service démarré, port en écoute, log écrit, chaîne fatale absente
6. `cee_configure/handlers/main.yml` — seconde tâche en `listen: Restart emc_cee`, `win_service` sous `when: ansible_os_family == 'Windows'`
7. Le dispatch à deux voies dans `cee_configure` et `cee_verify` :
   `{{ 'Windows.yml' if ansible_os_family == 'Windows' else 'Linux.yml' }}`
8. Tests de gate plateforme Windows, mutation-testés comme les autres
