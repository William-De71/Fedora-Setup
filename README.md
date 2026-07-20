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
7. Propose un **redémarrage** si nécessaire (`dnf needs-restarting`).

Le script est **idempotent** : il peut être relancé sans risque, il ne refait
que ce qui est nécessaire.

## Installation en tant que commande système

Pour pouvoir appeler `fedora-setup` depuis **n'importe quel dossier** (au lieu
de `./fedora-setup.sh` depuis le dépôt), installez-le une fois :

```bash
sudo ./fedora-setup.sh --install
```

Cette commande :
- copie le projet dans **`/opt/fedora-setup`** (script + listes + README) ;
- crée le lien **`/usr/local/bin/fedora-setup`** (ce dossier est dans le `PATH`).

Ensuite, depuis n'importe où :

```bash
sudo fedora-setup            # exécution complète
fedora-setup --help          # aide
```

> Les listes à personnaliser se trouvent alors dans `/opt/fedora-setup/rpm.list`
> et `/opt/fedora-setup/flatpak.list`. Une réinstallation (`--install`) met à
> jour le script mais **ne réécrase pas** des listes déjà personnalisées.

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
| `--no-update` | Sauter les mises à jour RPM/Flatpak |
| `--no-firmware` | Sauter les mises à jour firmware |
| `--no-gpu` | Sauter l'installation des pilotes graphiques |
| `--no-lists` | Ne pas traiter les fichiers de listes |
| `-q`, `--quiet` | Affichage compact (OK/ERREUR), détails dans le log uniquement |
| `--install` | Installer la commande système `fedora-setup` (voir plus haut) |
| `--uninstall` | Désinstaller la commande et `/opt/fedora-setup` |
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
