# Fedora Setup

Script de post-installation et de maintenance pour **Fedora Workstation**.

Conçu à l'origine pour un **Lenovo ThinkPad P15s Gen 1** (GPU hybride
Intel UHD + NVIDIA Quadro P520), il **détecte automatiquement le matériel**
et s'adapte donc à n'importe quel PC (NVIDIA, AMD, Intel, ou hybride).

## Ce que fait le script

1. **Configuration DNF** : téléchargements parallèles, miroir le plus rapide,
   désactivation des statistiques (n'écrase jamais une valeur déjà présente).
2. **Dépôts** : RPM Fusion free/nonfree (+ tainted), openh264 Cisco, Flathub.
3. **Mises à jour** : paquets RPM, Flatpaks et firmwares (fwupd).
4. **Pilotes graphiques** (détection via `lspci`, cumulable pour les hybrides) :
   - **NVIDIA** : `akmod-nvidia` (recompilé à chaque noyau), CUDA/NVENC, VAAPI ;
   - **Intel** : `intel-media-driver` (décodage vidéo matériel) ;
   - **AMD** : bascule vers les drivers Mesa VAAPI/VDPAU « freeworld ».
5. **Codecs multimédia** : ffmpeg complet, groupes multimedia RPM Fusion.
6. **Paquets personnalisés** : installation/suppression de RPM et de Flatpaks
   d'après deux fichiers de listes indépendants.
7. **Extensions GNOME Shell** : installation/suppression par UUID d'après
   `gnome-extensions.list`, via `gnome-extensions-cli`.
8. Propose un **redémarrage** si nécessaire (`dnf needs-restarting`).

Le script est **idempotent** : il peut être relancé sans risque, il ne refait
que ce qui est nécessaire.

En complément, des options dédiées (voir plus bas) ne sont **jamais** exécutées
automatiquement, uniquement sur demande explicite :

| Option | Rôle |
|---|---|
| `--bashrc` | Installe un `~/.bashrc` personnalisé |
| `--docker` | Installe et configure Docker CE |
| `--clean` | Récupère de l'espace disque (cache, journal, vieux noyaux) |
| `--memory` | Adapte les réglages mémoire du noyau au swap zram |
| `--boot` | Analyse le démarrage et propose d'en retirer le superflu |
| `--laptop` | Optimise l'autonomie sur un portable |
| `--security` | Vérifie et renforce les protections de base |
| `--devtools` | Installe conteneurs de dev, virtualisation et polices |

Enfin, deux options transverses s'appliquent au flux principal :
`--dry-run` (tout simuler sans rien modifier) et `--snapshot`
(instantané Btrfs avant modification).

## Installation en tant que commande système

Pour pouvoir appeler `fedora-setup` depuis **n'importe quel dossier** (au lieu
de `./fedora-setup.sh` depuis le dépôt), installez-le une fois :

```bash
sudo ./fedora-setup.sh --install
```

Cette commande :
- clone le dépôt dans **`/opt/fedora-setup`** si un remote `origin` est
  configuré sur le dépôt source (ce qui permet ensuite d'utiliser `--update`) ;
  sinon, elle copie simplement le projet (script + listes + README) ;
- crée le lien **`/usr/local/bin/fedora-setup`** (ce dossier est dans le `PATH`).

Ensuite, depuis n'importe où :

```bash
sudo fedora-setup            # exécution complète
fedora-setup --help          # aide
fedora-setup --version       # version installée
```

> Les listes à personnaliser se trouvent alors dans `/opt/fedora-setup/rpm.list`,
> `/opt/fedora-setup/flatpak.list` et `/opt/fedora-setup/gnome-extensions.list`.
>
> ⚠️ **`--install` régénère toujours ces listes** depuis les gabarits
> `*.list.example` du dépôt (remise à zéro volontaire de vos
> personnalisations). Voir [Listes réelles vs gabarits](#listes-réelles-vs-gabarits)
> ci-dessous pour comprendre pourquoi et comment `--update` s'en distingue.

### Listes réelles vs gabarits

Le dépôt ne versionne **que des gabarits** : `rpm.list.example`,
`flatpak.list.example`, `repos.list.example`, `gnome-extensions.list.example`.
Les fichiers réels (`rpm.list`, `flatpak.list`, `repos.list`,
`gnome-extensions.list`) ne sont **jamais commités** (voir `.gitignore`) :

- Ils sont **créés une fois**, depuis les gabarits, la première fois que le
  script tourne (ou lors d'un `--install`) — puis laissés intacts.
- Vous les **personnalisez librement** (ajout/suppression de paquets,
  extensions, dépôts…) sans risque qu'une mise à jour ne les modifie.
- **`--update`** (voir ci-dessous) ne touche que le script et les gabarits :
  comme les listes réelles ne sont pas suivies par git, il ne les touche
  **jamais**.
- **`--install`**, en revanche, **régénère toujours** les listes réelles
  depuis les gabarits — c'est le moyen explicite de repartir d'une
  configuration propre si besoin.

### Mettre à jour l'installation système

Si l'installation a été faite depuis un dépôt avec un remote `origin`
configuré (clone git), une mise à jour est possible sans tout réinstaller :

```bash
sudo fedora-setup --update
```

`--update` installe toujours la **dernière release taggée** (`vX.Y.Z`),
jamais un commit intermédiaire de la branche : il récupère les tags
(`git fetch --tags`) et bascule sur le plus récent. S'il n'existe encore
aucun tag sur le dépôt, il se rabat sur un `git pull` classique.

Dans tous les cas, `--update` ne modifie que le script et les gabarits
`*.list.example` — vos listes personnalisées (`rpm.list`, `flatpak.list`, …)
ne sont jamais touchées.

Sans remote configuré au moment de `--install`, `--update` n'est pas
disponible (le script vous le signale) : relancez `--install` depuis un
clone à jour dans ce cas.

### Publier une nouvelle version (`release.sh`)

Pour les mainteneurs du dépôt : `release.sh` automatise la publication d'une
nouvelle version de `fedora-setup.sh`.

```bash
./release.sh patch   # x.y.Z -> x.y.(Z+1) — corrections
./release.sh minor    # x.Y.z -> x.(Y+1).0 — nouvelles fonctionnalités
./release.sh major    # X.y.z -> (X+1).0.0 — changements non rétro-compatibles
```

Le script incrémente `VERSION` dans `fedora-setup.sh`, commite, crée le tag
`vX.Y.Z` et pousse le tout vers `origin` (après confirmation). Le push du tag
déclenche automatiquement le workflow GitHub Actions
(`.github/workflows/release.yml`), qui crée la Release GitHub correspondante
avec des notes générées automatiquement à partir des commits.

Pour tout retirer :

```bash
sudo fedora-setup --uninstall   # supprime le lien et /opt/fedora-setup
```

## Utilisation

Depuis le dépôt :

```bash
sudo ./fedora-setup.sh
```

Ou, une fois installé (voir ci-dessus) :

```bash
sudo fedora-setup
```

### Options

| Option | Description |
|---|---|
| `-r FICHIER` | Liste RPM à utiliser (défaut : `rpm.list` à côté du script) |
| `-f FICHIER` | Liste Flatpak à utiliser (défaut : `flatpak.list`) |
| `-d FICHIER` | Liste de dépôts tiers à utiliser (défaut : `repos.list`) |
| `-e FICHIER` | Liste d'extensions GNOME à utiliser (défaut : `gnome-extensions.list`) |
| `--no-update` | Sauter les mises à jour RPM/Flatpak |
| `--no-firmware` | Sauter les mises à jour firmware |
| `--no-gpu` | Sauter l'installation des pilotes graphiques |
| `--no-repos` | Ne pas ajouter les dépôts tiers de `repos.list` |
| `--no-lists` | Ne pas traiter les fichiers `rpm.list`/`flatpak.list` |
| `--no-gnome-ext` | Ne pas traiter `gnome-extensions.list` |
| `-y`, `--yes` | Répondre « oui » à toutes les questions (non interactif) |
| `-q`, `--quiet` | Affichage compact (OK/ERREUR), détails dans le log uniquement |
| `-n`, `--dry-run` | **Simulation** : affiche les commandes sans rien exécuter (voir plus bas) |
| `--snapshot` | Instantané Btrfs de `/` avant toute modification (voir plus bas) |
| `-v`, `--version` | Afficher la version du script |
| `--install` | Installer la commande système `fedora-setup` (voir plus haut) |
| `--update` | Mettre à jour l'installation système (nécessite un remote git) |
| `--uninstall` | Désinstaller la commande et `/opt/fedora-setup` |
| `--bashrc` | Installer `~/.bashrc` depuis `bashrc.example` (voir plus bas) |
| `--docker` | Installer et configurer Docker CE (voir plus bas) |
| `--clean` | Nettoyage : cache DNF, journal, vieux noyaux, TRIM (voir plus bas) |
| `--memory` | Régler la mémoire du noyau pour le swap zram (voir plus bas) |
| `--boot` | Analyser et accélérer le démarrage (voir plus bas) |
| `--laptop` | Autonomie : TLP/PPD, thermald, powertop (voir plus bas) |
| `--security` | Vérifier SELinux, pare-feu, MAJ auto, DNS (voir plus bas) |
| `--devtools` | distrobox, virtualisation KVM, polices (voir plus bas) |
| `-h`, `--help` | Afficher l'aide |

> Les six dernières options (`--clean` à `--devtools`) sont **autonomes** :
> chacune fait son travail puis s'arrête, sans lancer le flux de
> post-installation. Elles ne sont **jamais** exécutées automatiquement.

Par défaut, la sortie des commandes est affichée en direct à l'écran (mode
verbeux). Utilisez `-q` pour un affichage compact.

Exemples :

```bash
# Config complète avec des listes spécifiques à une machine
sudo ./fedora-setup.sh -r listes/thinkpad.rpm.list -f listes/thinkpad.flatpak.list

# Simple passe de mise à jour, sans toucher aux paquets ni au GPU
sudo ./fedora-setup.sh --no-gpu --no-lists
```

## Format des fichiers de listes

> Rappel : `rpm.list`, `flatpak.list`, `repos.list` et `gnome-extensions.list`
> sont générés depuis leurs gabarits `*.list.example` respectifs (voir
> [Listes réelles vs gabarits](#listes-réelles-vs-gabarits)) — éditez les
> fichiers réels, pas les gabarits, pour vos personnalisations quotidiennes.

Une entrée par ligne, dans `rpm.list` et `flatpak.list` :

```
add:paquet     # installe le paquet
del:paquet     # supprime le paquet
paquet         # équivalent à add:paquet
# commentaire  # ignoré, lignes vides ignorées
```

Pour les Flatpaks, utiliser l'identifiant complet de l'application
(ex. `org.gnome.Boxes`), à trouver sur <https://flathub.org> ou via
`flatpak search <nom>`.

## Dépôts tiers (`repos.list`)

Certaines applications (Vivaldi, VS Code, Sublime Text, VirtualBox…) ne sont
pas dans les dépôts Fedora : il faut d'abord **ajouter leur dépôt** et sa clé
GPG. C'est le rôle du fichier `repos.list`, une ligne par dépôt :

```
nom | url_de_la_cle_gpg | url_du_fichier.repo
```

Exemple :

```
vivaldi | https://repo.vivaldi.com/archive/linux_signing_key.pub | https://repo.vivaldi.com/archive/vivaldi-fedora.repo
```

À l'exécution, le script **demande pour chaque dépôt** s'il faut l'ajouter
(répondre `y`/`N`). Utilisez `--yes` pour tout accepter sans question, ou
`--no-repos` pour ignorer complètement cette étape.

Une fois le dépôt ajouté, installez ses paquets comme les autres, via
`rpm.list` — par exemple `add:vivaldi-stable`, `add:code`, `add:sublime-text`,
`add:VirtualBox-7.1`. Ces lignes sont déjà présentes (commentées) dans
`rpm.list` : décommentez celles qui correspondent aux dépôts que vous acceptez.

Pour retrouver l'URL et la clé d'un dépôt déjà présent sur votre machine :

```bash
grep -E 'baseurl|gpgkey|^\[' /etc/yum.repos.d/*.repo
```

## Extensions GNOME Shell (`gnome-extensions.list`)

Une entrée par ligne, même syntaxe `add:`/`del:` que `rpm.list`/`flatpak.list`,
avec l'UUID de l'extension (visible dans l'URL de sa page sur
<https://extensions.gnome.org>) :

```
add:dash-to-panel@jderose9.github.com   # installe et active
del:dash-to-panel@jderose9.github.com   # désinstalle
```

Le script installe automatiquement l'outil
[`gnome-extensions-cli`](https://github.com/essembeh/gnome-extensions-cli)
(commande `gext`, via `pipx`) puis l'utilise pour installer/activer ou
désinstaller chaque entrée.

> **Particularité** : les extensions GNOME Shell sont un concept
> **par-utilisateur** (répertoire `~/.local/share/gnome-shell/extensions` et
> réglages dans le profil de session), contrairement au reste du script qui
> opère en root. `fedora-setup` détecte donc l'utilisateur réel derrière le
> `sudo` (variable `$SUDO_USER`) et exécute `gext` en son nom, avec son bus
> D-Bus de session — aucune action manuelle requise, mais le script doit être
> lancé via `sudo` (pas en root direct) pour que `$SUDO_USER` soit défini.

## Bashrc personnalisé (`--bashrc`)

Le dépôt fournit un gabarit `bashrc.example` (prompt coloré avec branche git,
config `nvm`, `PATH` personnalisé…). Contrairement au reste du script, il
**n'est jamais installé automatiquement** : il faut le demander explicitement.

```bash
sudo fedora-setup --bashrc
```

Cette commande :
- installe `bashrc.example` en tant que **`~/.bashrc`** de l'utilisateur réel
  (`$SUDO_USER`, pas root — mêmes principes que pour les extensions GNOME) ;
- **sauvegarde l'ancien fichier** en `~/.bashrc.bak` s'il existe et diffère du
  gabarit, avant de l'écraser.

Comme pour les listes de paquets, seul `bashrc.example` est versionné dans le
dépôt : votre `~/.bashrc` réel n'est pas suivi par git et peut être modifié
librement ensuite — `--update` (mise à jour du script) n'y touche jamais.

## Docker (`--docker`)

Installe **Docker CE depuis le dépôt officiel** de Docker
(`download.docker.com`) plutôt que le paquet `moby-engine` des dépôts Fedora :
c'est la version documentée par Docker, et la seule à fournir `buildx` et
`compose` v2 sous forme de plugins.

```bash
sudo fedora-setup --docker
```

Cette commande, dans l'ordre :

1. ajoute le dépôt `docker-ce` dans `/etc/yum.repos.d/docker-ce.repo` (ignoré
   s'il est déjà présent) ;
2. **supprime les paquets Fedora en conflit** s'ils sont installés
   (`moby-engine`, `docker`, `docker-common`, `containerd`…) : ils fournissent
   les mêmes binaires et bloqueraient l'installation ;
3. installe `docker-ce`, `docker-ce-cli`, `containerd.io`,
   `docker-buildx-plugin` et `docker-compose-plugin` ;
4. ajoute l'utilisateur réel (`$SUDO_USER`, pas root — même principe que pour
   les extensions GNOME) au **groupe `docker`** ;
5. démarre le service et valide l'installation avec
   `docker run --rm hello-world`.

> ⚠️ **Appartenir au groupe `docker` équivaut à un accès root** : le démon
> tourne en root et n'importe quel conteneur peut monter le système de fichiers
> hôte. C'est le compromis standard pour utiliser `docker` sans `sudo` ; si
> vous ne le souhaitez pas, retirez l'utilisateur du groupe avec
> `sudo gpasswd -d $USER docker`.
>
> Le changement de groupe ne prend effet qu'après une **déconnexion /
> reconnexion** de la session.

Le service est démarré pour la session courante mais **n'est pas activé au
démarrage**, ce choix vous restant :

```bash
sudo systemctl enable --now docker   # démarrage automatique au boot
```

Comme `--bashrc`, cette étape ne fait **pas** partie du flux principal : un
`sudo fedora-setup` classique n'installe jamais Docker.

## Simulation (`--dry-run`)

Le script enchaîne des centaines de commandes, dont beaucoup modifient le
système en profondeur. `--dry-run` affiche **exactement ce qui serait exécuté**,
sans rien exécuter :

```bash
./fedora-setup.sh --dry-run              # flux complet, simulé
./fedora-setup.sh --clean --dry-run      # une option précise, simulée
```

Chaque commande apparaît précédée de `$`, et un récapitulatif final indique
combien auraient été lancées :

```
    Suppression des paquets orphelins : simulé
        $ dnf autoremove -y

==> Récapitulatif
    Mode simulation : 7 commande(s) affichée(s), aucune exécutée.
```

> **Utilisable sans `sudo`.** C'est volontaire : l'intérêt de `--dry-run` est
> justement d'**auditer le script avant de lui confier les droits root**. Dans
> ce cas le journal est écrit dans `/tmp` au lieu de `/var/log`. Certains états
> restent illisibles sans privilèges, mais la liste des commandes est complète.

L'ordre des options n'a aucune importance : `--clean --dry-run` et
`--dry-run --clean` sont équivalents.

## Instantané Btrfs (`--snapshot`)

Si la racine est en **Btrfs** (le cas par défaut sur Fedora Workstation),
`--snapshot` prend un instantané en lecture seule de `/` **avant toute
modification** :

```bash
sudo fedora-setup --snapshot          # instantané, puis exécution normale
```

L'opération est quasi instantanée et n'occupe initialement aucun espace (copie
sur écriture), ce qui en fait un filet de sécurité peu coûteux avant une grosse
mise à jour ou un changement de pilote graphique. L'instantané est rangé dans
`/.snapshots/root_YYYYMMDD-HHMMSS`.

```bash
sudo btrfs subvolume list /                       # lister
sudo btrfs subvolume delete /.snapshots/root_...  # supprimer
```

> ⚠️ **Un instantané n'est pas une sauvegarde** : il vit sur le même disque et
> disparaît avec lui. Il protège d'une mise à jour ratée, pas d'une panne
> matérielle.
>
> Sur un système de fichiers autre que Btrfs (ext4, xfs), l'option est sans
> effet et le signale.

## Nettoyage et maintenance (`--clean`)

Récupère de l'espace disque et **borne ce qui grossit sans limite** sur une
installation utilisée au quotidien :

```bash
sudo fedora-setup --clean
```

1. **Paquets orphelins** (`dnf autoremove`) et **cache DNF** (souvent ~1 Go) ;
2. **Journal systemd** : réduit immédiatement, puis **plafonné à 200 Mo** de
   façon permanente (par défaut il peut occuper jusqu'à 10 % de `/var`, soit
   plusieurs gigaoctets) ;
3. **Anciens noyaux** au-delà de la limite ;
4. **Runtimes Flatpak** devenus inutiles ;
5. **Journaux du script lui-même** : les 10 plus récents sont conservés (ils
   n'avaient jusqu'ici aucune rotation et s'accumulaient indéfiniment) ;
6. **TRIM** du SSD, en vérifiant que `fstrim.timer` est bien actif.

L'espace récupéré est affiché à la fin. Le flux principal configure par ailleurs
`installonly_limit=2` dans `/etc/dnf/dnf.conf`, pour que Fedora ne conserve que
2 noyaux au lieu de 3.

## Réactivité mémoire (`--memory`)

Fedora active **zram** par défaut (swap compressé en RAM), mais conserve les
valeurs `sysctl` pensées pour un swap **sur disque**. Or les deux n'ont rien à
voir : swapper vers zram coûte un cycle CPU de compression, pas une
entrée-sortie disque. Résultat, le noyau évite un swap devenu bon marché et
préfère jeter du cache de pages — ce qui **dégrade** la réactivité.

```bash
sudo fedora-setup --memory
```

Écrit un drop-in `/etc/sysctl.d/99-fedora-setup-memory.conf` :

| Réglage | Valeur | Défaut | Pourquoi |
|---|---|---|---|
| `vm.swappiness` | `180` | `60` | Valeur recommandée avec zram |
| `vm.vfs_cache_pressure` | `50` | `100` | Garde inodes et dentries plus longtemps |
| `vm.dirty_bytes` | 256 Mo | 20 % RAM | Évite les à-coups sur grosses copies |
| `vm.page-cluster` | `0` | `3` | zram se lit page par page |

Vérifie aussi que **`systemd-oomd`** est actif : sans lui, une saturation
mémoire fige le bureau de longues minutes au lieu de ne perdre qu'une
application.

> Si zram est absent, le script **prévient et demande confirmation** : un
> `swappiness` élevé solliciterait alors fortement le disque.

## Optimisation du démarrage (`--boot`)

Analyse le temps de démarrage et propose, **une désactivation à la fois** :

```bash
sudo fedora-setup --boot
```

- **`NetworkManager-wait-online`** : retarde l'ouverture de session jusqu'à ce
  que le réseau réponde — utile sur un serveur, inutile sur un poste de bureau.
  Le script affiche le **coût mesuré** sur votre machine avant de demander ;
- **`cups`** : proposé **uniquement si aucune imprimante n'est configurée** ;
- **`bluetooth`** : proposé **uniquement si aucun contrôleur n'est détecté** ;
- **Délai du menu GRUB** : réduit à 1 seconde (pas 0 — à 0 le menu devient
  inatteignable, ce qui complique le démarrage sur un noyau antérieur en cas de
  problème). L'ancien fichier est sauvegardé en `/etc/default/grub.bak`.

> Les services sont **désactivés, pas masqués** : un simple
> `sudo systemctl enable <service>` suffit à revenir en arrière.
>
> Les garde-fous ci-dessus évitent de casser une configuration qui marche : sur
> une machine avec imprimante et Bluetooth, ces deux services ne sont jamais
> proposés.

## Portable et autonomie (`--laptop`)

Réservé aux machines **sur batterie** (détectée automatiquement ; sur un poste
fixe le script demande confirmation, ces réglages échangeant des performances
contre de l'autonomie).

```bash
sudo fedora-setup --laptop
```

**Gestionnaire d'énergie** — TLP et `power-profiles-daemon` pilotent les mêmes
réglages du noyau et **se contredisent s'ils tournent ensemble**. Le script
explique le compromis et n'en installe **qu'un seul** :

| | `power-profiles-daemon` | TLP |
|---|---|---|
| Intégration GNOME | Sélecteur de profil dans le menu système | Remplace ce sélecteur |
| Réglages | Prudents, non configurables | Agressifs, très configurables |

Si TLP est choisi alors que PPD est présent, ce dernier est **masqué** pour
éviter le conflit.

**thermald** (processeurs Intel) : gestion thermique fine ; sans lui, le noyau
ne réagit qu'aux seuils matériels, plus tardifs et plus brutaux.

**powertop** : propose une unité systemd appliquant `--auto-tune` à chaque
démarrage.

> ⚠️ L'auto-tune de powertop active l'économie d'énergie sur les **ports USB** :
> certaines souris, claviers ou webcams peuvent se déconnecter par moments.
> C'est pourquoi l'option est proposée en dernier, clairement signalée, et
> réversible (`sudo systemctl disable --now powertop-autotune`).

## Sécurité et réseau (`--security`)

**Constate puis propose** — rien n'est durci de force, un pare-feu trop strict
ou un résolveur DNS mal choisi cassant la connectivité de façon difficile à
diagnostiquer.

```bash
sudo fedora-setup --security
```

- **SELinux** : signale l'état (`Enforcing` / `Permissive` / `Disabled`). Le
  script ne tente **jamais** de le réactiver depuis `Disabled` : cela impose un
  réétiquetage complet du disque, à faire en connaissance de cause ;
- **Pare-feu** : vérifie que `firewalld` tourne et affiche la zone active. Si
  c'est `FedoraWorkstation`, signale qu'elle laisse ouverts les **ports UDP
  1025-65535** (partage et découverte réseau) — un compromis discutable sur un
  Wi-Fi public ;
- **Mises à jour automatiques** : configurées en **téléchargement + notification
  uniquement**, jamais en installation silencieuse (qui peut redémarrer des
  services en pleine session) ;
- **DNS-over-TLS** : propose de chiffrer les requêtes DNS via Quad9, en mode
  `opportunistic` (le mode strict rend la résolution impossible derrière un
  portail captif ou un réseau bloquant le port 853).

> **Garde-fou DNS** : si votre résolveur actuel est une **adresse privée**
> (`10.x`, `192.168.x`, `172.16-31.x`), c'est un DNS local — box ou réseau
> d'entreprise — qui résout des noms internes. Le remplacer casserait cet
> accès : l'étape est alors **ignorée automatiquement**.

## Outils de développement (`--devtools`)

Chaque outil est proposé séparément (ils sont volumineux et n'ont d'intérêt que
selon l'usage réel) :

```bash
sudo fedora-setup --devtools
```

- **distrobox** : conteneurs de développement jetables, avec accès au dossier
  personnel. Fedora fournit déjà `toolbox`, qui fait de même mais **uniquement
  avec des images Fedora**, là où distrobox accepte n'importe quelle
  distribution (Ubuntu, Arch, Debian…). Les deux peuvent cohabiter ;
- **Virtualisation KVM** : `qemu-kvm`, `libvirt`, `virt-manager`. Le script
  vérifie d'abord le support **VT-x / AMD-V** (sans lui, les machines virtuelles
  seraient émulées et très lentes) et ajoute l'utilisateur au groupe `libvirt`,
  faute de quoi `virt-manager` réclame le mot de passe root à chaque lancement ;
- **Polices** : Liberation (équivalents libres d'Arial/Times/Courier), Noto
  (emoji et CJK), Fira Code et JetBrains Mono (programmation).

> Seules des polices **librement redistribuables** sont installées : les polices
> Microsoft exigeraient un téléchargement externe et l'acceptation d'une licence.

## Journal

Chaque exécution écrit un journal détaillé dans
`/var/log/fedora-setup_YYYYMMDD-HHMMSS.log`. Pour suivre en direct :

```bash
tail -f /var/log/fedora-setup_*.log
```

## Notes NVIDIA

- Le module noyau est compilé en arrière-plan par `akmods` :
  **attendre ~5 minutes avant de redémarrer** après la première installation.
  Vérifier avec `modinfo -F version nvidia`.
- Si **Secure Boot** est activé, le module doit être signé :
  voir <https://rpmfusion.org/Howto/Secure%20Boot>.

## Crédits

Inspiré de [fedora-config](https://github.com/aaaaadrien/fedora-config)
(aaaaadrien) et de [Fedora-GLF](https://github.com/Gaming-Linux-FR/Fedora-GLF)
(Gaming Linux FR).
