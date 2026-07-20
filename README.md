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

En complément, une option dédiée `--bashrc` (voir plus bas) permet d'installer
un `~/.bashrc` personnalisé — elle n'est **jamais** exécutée automatiquement,
uniquement sur demande explicite.

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
| `-v`, `--version` | Afficher la version du script |
| `--install` | Installer la commande système `fedora-setup` (voir plus haut) |
| `--update` | Mettre à jour l'installation système (nécessite un remote git) |
| `--uninstall` | Désinstaller la commande et `/opt/fedora-setup` |
| `--bashrc` | Installer `~/.bashrc` depuis `bashrc.example` (voir plus bas) |
| `-h`, `--help` | Afficher l'aide |

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
