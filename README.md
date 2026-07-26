# Fedora Setup

Script de post-installation et de maintenance pour **Fedora Workstation**.

Conçu à l'origine pour un **Lenovo ThinkPad P15s Gen 1** (GPU hybride
Intel UHD + NVIDIA Quadro P520), il **détecte automatiquement le matériel**
et s'adapte donc à n'importe quel PC (NVIDIA, AMD, Intel, ou hybride).

📖 **[Documentation complète](https://william-de71.github.io/Fedora-Setup/)** —
référence des options, guides d'usage et dépannage.

## Démarrage rapide

```bash
git clone https://github.com/William-De71/Fedora-Setup.git
cd Fedora-Setup

./fedora-setup.sh --dry-run    # simulation : ne modifie rien, pas de sudo requis
sudo ./fedora-setup.sh         # exécution réelle
```

> `--dry-run` affiche exactement ce que le script ferait, sans rien exécuter, et
> fonctionne **sans `sudo`** : de quoi l'auditer avant de lui confier les droits
> root.

## Ce que fait le script

Lancé sans option, il déroule un flux complet de post-installation :

1. **Configuration DNF** : téléchargements parallèles, miroir le plus rapide,
   2 noyaux conservés (n'écrase jamais une valeur déjà présente).
2. **Dépôts** : RPM Fusion free/nonfree (+ tainted), openh264 Cisco, Flathub,
   et dépôts tiers optionnels via `repos.list`.
3. **Mises à jour** : paquets RPM, Flatpaks et firmwares (fwupd).
4. **Pilotes graphiques** (détection `lspci`, cumulable pour les hybrides) :
   NVIDIA (`akmod-nvidia`, CUDA, VAAPI), Intel (`intel-media-driver`),
   AMD (Mesa freeworld).
5. **Codecs multimédia** : ffmpeg complet, groupes multimedia RPM Fusion.
6. **Paquets personnalisés** : RPM et Flatpaks d'après vos propres listes.
7. **Extensions GNOME Shell** : par UUID, via `gnome-extensions-cli`.
8. Propose un **redémarrage** si nécessaire.

Le script est **idempotent** : il peut être relancé sans risque, il ne refait
que ce qui est nécessaire.

## Options autonomes

Ces options font leur travail puis s'arrêtent. Elles ne sont **jamais**
exécutées automatiquement — un `sudo fedora-setup` classique n'en déclenche
aucune.

| Option | Rôle |
|---|---|
| [`--clean`](https://william-de71.github.io/Fedora-Setup/options.html#clean) | Cache DNF, journal systemd, vieux noyaux, TRIM |
| [`--memory`](https://william-de71.github.io/Fedora-Setup/options.html#memory) | Adapte les réglages du noyau au swap zram |
| [`--boot`](https://william-de71.github.io/Fedora-Setup/options.html#boot) | Mesure le démarrage et propose d'en retirer le superflu |
| [`--laptop`](https://william-de71.github.io/Fedora-Setup/options.html#laptop) | Autonomie : TLP ou power-profiles-daemon, thermald, powertop |
| [`--security`](https://william-de71.github.io/Fedora-Setup/options.html#security) | SELinux, pare-feu, mises à jour auto, DNS chiffré |
| [`--devtools`](https://william-de71.github.io/Fedora-Setup/options.html#devtools) | distrobox, virtualisation KVM, polices libres |
| [`--docker`](https://william-de71.github.io/Fedora-Setup/options.html#docker) | Docker CE depuis le dépôt officiel |
| [`--bashrc`](https://william-de71.github.io/Fedora-Setup/options.html#bashrc) | Installe un `~/.bashrc` personnalisé |

Deux options transverses s'appliquent au flux principal :
[`--dry-run`](https://william-de71.github.io/Fedora-Setup/options.html#dry-run)
(tout simuler) et
[`--snapshot`](https://william-de71.github.io/Fedora-Setup/options.html#snapshot)
(instantané Btrfs avant modification).

La [référence complète](https://william-de71.github.io/Fedora-Setup/options.html)
détaille les 27 options, ce que chacune écrit sur le disque et comment revenir
en arrière.

## Installation en tant que commande système

```bash
sudo ./fedora-setup.sh --install
```

Le projet est installé dans `/opt/fedora-setup` et lié dans le `PATH`. Ensuite,
depuis n'importe où :

```bash
sudo fedora-setup            # exécution complète
fedora-setup --help          # aide
sudo fedora-setup --update   # dernière release publiée
sudo fedora-setup --uninstall
```

> ⚠️ `--install` **régénère toujours** vos listes de paquets depuis les gabarits
> `*.list.example` (remise à zéro volontaire). `--update`, lui, n'y touche
> jamais.

## Listes de paquets

Le dépôt ne versionne que des gabarits `*.list.example`. Les fichiers réels
(`rpm.list`, `flatpak.list`, `repos.list`, `gnome-extensions.list`) sont créés
une fois à partir d'eux, puis vous appartiennent : aucune mise à jour ne les
modifie.

```
add:paquet     # installe
del:paquet     # supprime
paquet         # équivalent à add:
# commentaire  # ignoré, lignes vides ignorées
```

Voir le [guide des listes](https://william-de71.github.io/Fedora-Setup/guides.html#listes)
pour les dépôts tiers et les extensions GNOME.

## Principes

- **Constater avant de modifier** — `cups` n'est proposé à la désactivation que
  si aucune imprimante n'est configurée ; le DNS chiffré est ignoré si votre
  résolveur est local ; TLP et power-profiles-daemon ne sont jamais installés
  ensemble.
- **Réversible par défaut** — services désactivés et non masqués, fichiers de
  configuration sauvegardés en `.bak`, commande d'annulation affichée.
- **Rien d'implicite** — les options autonomes ne s'exécutent que si on les
  nomme.
- **Traçable** — journal horodaté dans `/var/log/fedora-setup_*.log` et
  récapitulatif final listant nommément les actions en échec.

## Notes NVIDIA

- Le module noyau est compilé en arrière-plan par `akmods` :
  **attendre ~5 minutes avant de redémarrer** après la première installation.
  Vérifier avec `modinfo -F version nvidia`.
- Si **Secure Boot** est activé, le module doit être signé :
  voir <https://rpmfusion.org/Howto/Secure%20Boot>.

Plus de cas dans le
[guide de dépannage](https://william-de71.github.io/Fedora-Setup/troubleshooting.html).

## Publier une nouvelle version

Pour les mainteneurs : `release.sh` automatise la publication.

```bash
./release.sh patch   # x.y.Z -> x.y.(Z+1) — corrections
./release.sh minor   # x.Y.z -> x.(Y+1).0 — nouvelles fonctionnalités
./release.sh major   # X.y.z -> (X+1).0.0 — changements non rétro-compatibles
```

Le script incrémente `VERSION`, commite, crée le tag `vX.Y.Z` et pousse le tout
(après confirmation). Le push du tag déclenche le workflow GitHub Actions qui
crée la Release correspondante.

## Licence et crédits

MIT. Inspiré de [fedora-config](https://github.com/aaaaadrien/fedora-config)
(aaaaadrien) et de [Fedora-GLF](https://github.com/Gaming-Linux-FR/Fedora-GLF)
(Gaming Linux FR).
