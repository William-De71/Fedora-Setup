#!/usr/bin/env bash
#===============================================================================
#
#  FICHIER      : fedora-setup.sh
#
#  USAGE        : sudo ./fedora-setup.sh [options]
#
#  DESCRIPTION  : Script de post-installation / maintenance pour Fedora.
#                 - Optimise la configuration DNF
#                 - Configure les dépôts RPM Fusion et Flathub
#                 - Met à jour le système (RPM, Flatpak, firmwares)
#                 - Détecte le(s) GPU et installe les pilotes adaptés
#                   (NVIDIA, AMD, Intel — y compris hybride type Optimus)
#                 - Installe/supprime des paquets RPM et Flatpak d'après
#                   des fichiers de listes externes (rpm.list / flatpak.list)
#
#  LISTES       : une entrée par ligne, syntaxe :
#                     add:paquet   -> installe le paquet
#                     del:paquet   -> supprime le paquet
#                     paquet       -> équivalent à add:paquet
#                     # commentaire / ligne vide -> ignoré
#
#  AUTEUR       : William
#  CRÉÉ LE      : 2026-07-20
#  LICENCE      : MIT
#
#  Inspiré de :
#    - https://github.com/aaaaadrien/fedora-config
#    - https://github.com/Gaming-Linux-FR/Fedora-GLF
#===============================================================================

# -u : erreur si variable non définie ; pipefail : un pipe échoue si un
# de ses maillons échoue. Pas de -e : beaucoup de commandes DNF ont des
# codes retour "informatifs" (ex: check-update renvoie 100), on gère
# les erreurs au cas par cas via run().
set -u -o pipefail

#===============================================================================
# VARIABLES GLOBALES
#===============================================================================

# realpath résout les liens symboliques : appelé via /usr/local/bin/fedora-setup
# (un lien créé par --install), SCRIPT_DIR pointe bien vers /opt/fedora-setup,
# là où se trouvent réellement les listes rpm.list / flatpak.list.
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"
LOG_FILE="/var/log/fedora-setup_$(date '+%Y%m%d-%H%M%S').log"
readonly SCRIPT_PATH SCRIPT_DIR SCRIPT_NAME LOG_FILE

# Version du script (affichée par -v/--version et au démarrage)
readonly VERSION="0.2.0"

# Fichiers de listes par défaut (surchargables via -r / -f / -d / -e).
# Ces fichiers *.list ne sont jamais versionnés (voir .gitignore) : ils sont
# générés une fois depuis les *.list.example fournis par le dépôt (voir
# ensure_lists_from_examples), puis personnalisés librement sans risque
# qu'un `git pull` (--update) ne les modifie ou ne les écrase.
RPM_LIST="${SCRIPT_DIR}/rpm.list"
FLATPAK_LIST="${SCRIPT_DIR}/flatpak.list"
REPOS_LIST="${SCRIPT_DIR}/repos.list"
GNOME_EXT_LIST="${SCRIPT_DIR}/gnome-extensions.list"

# Emplacements utilisés par --install / --uninstall :
#   - les fichiers du projet sont copiés dans INSTALL_DIR
#   - un lien symbolique dans BIN_DIR rend la commande accessible partout
readonly INSTALL_DIR="/opt/fedora-setup"
readonly BIN_DIR="/usr/local/bin"
readonly CMD_NAME="fedora-setup"

# Drapeaux d'options (modifiés par parse_args)
DO_UPDATE=1        # Mise à jour RPM + Flatpak
DO_FIRMWARE=1      # Mise à jour firmwares (fwupd)
DO_GPU=1           # Installation pilotes graphiques
DO_REPOS=1         # Ajout des dépôts tiers de repos.list (interactif)
DO_LISTS=1         # Traitement des listes rpm.list / flatpak.list
DO_GNOME_EXT=1     # Traitement de la liste gnome-extensions.list
VERBOSE=1          # Affiche la sortie des commandes au lieu du seul log
ASSUME_YES=0       # Répondre « oui » automatiquement (--yes) : aucune question

# Renseigné par gpu_detect() : chaîne lspci des contrôleurs graphiques
GPU_INFO=""

# Couleurs (désactivées si la sortie n'est pas un terminal)
if [[ -t 1 ]]; then
    readonly C_RED="\033[31m"    C_GREEN="\033[32m"  C_YELLOW="\033[33m"
    readonly C_BLUE="\033[36m"   C_BOLD="\033[1m"    C_RESET="\033[0m"
else
    readonly C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_BOLD="" C_RESET=""
fi

#===============================================================================
# FONCTIONS UTILITAIRES
#===============================================================================

# Affiche un titre de section numéroté
section() {
    echo -e "\n${C_BOLD}${C_BLUE}==> $*${C_RESET}"
    log "SECTION: $*"
}

# Écrit un message horodaté dans le fichier de log
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# Message d'information affiché ET loggé
info() {
    echo -e "    $*"
    log "INFO: $*"
}

# Message d'erreur sur stderr ET loggé
error() {
    echo -e "${C_RED}ERREUR :${C_RESET} $*" >&2
    log "ERROR: $*"
}

# Exécute une commande en la loggant, puis affiche OK / ERREUR.
#   $1 : libellé lisible de l'action
#   $@ : la commande et ses arguments
# Retourne le code de la commande (permet un traitement en aval si besoin).
run() {
    local label="$1"; shift
    local rc

    echo -ne "    ${label} : "
    log "CMD: $*"

    if [[ $VERBOSE -eq 1 ]]; then
        # Mode verbeux : sortie visible à l'écran et dans le log
        echo ""
        "$@" 2>&1 | tee -a "$LOG_FILE"
        rc=${PIPESTATUS[0]}
    else
        "$@" >> "$LOG_FILE" 2>&1
        rc=$?
    fi

    if [[ $rc -eq 0 ]]; then
        echo -e "${C_GREEN}OK${C_RESET}"
    else
        echo -e "${C_RED}ERREUR${C_RESET} (voir $LOG_FILE)"
    fi
    return "$rc"
}

# Pose une question oui/non (non par défaut).
#   $1 : la question
# Renvoie 0 pour « oui », 1 pour « non ». Avec --yes (ASSUME_YES=1),
# répond automatiquement « oui » sans rien demander.
ask_yes_no() {
    local question="$1" answer
    if [[ $ASSUME_YES -eq 1 ]]; then
        return 0
    fi
    echo -ne "    ${question} [y/N] : "
    read -r answer
    [[ "${answer,,}" == "y" ]]
}

# Vrai si le paquet RPM est installé
pkg_installed() {
    rpm -q "$1" &> /dev/null
}

# Vrai si le flatpak est installé
flatpak_installed() {
    flatpak info "$1" &> /dev/null
}

# Vrai si une commande existe dans le PATH
has_cmd() {
    command -v "$1" &> /dev/null
}

usage() {
    cat << EOF
Usage : sudo ./${SCRIPT_NAME} [options]

Post-installation et maintenance de Fedora : mises à jour, dépôts,
pilotes graphiques (détection automatique) et installation de paquets
depuis des fichiers de listes.

Options :
  -r FICHIER      Liste de paquets RPM      (défaut : ${RPM_LIST})
  -f FICHIER      Liste de paquets Flatpak  (défaut : ${FLATPAK_LIST})
  -d FICHIER      Liste de dépôts tiers     (défaut : ${REPOS_LIST})
  -e FICHIER      Liste d'extensions GNOME  (défaut : ${GNOME_EXT_LIST})
  --no-update     Ne pas faire les mises à jour RPM/Flatpak
  --no-firmware   Ne pas mettre à jour les firmwares (fwupd)
  --no-gpu        Ne pas installer les pilotes graphiques
  --no-repos      Ne pas ajouter les dépôts tiers de repos.list
  --no-lists      Ne pas traiter les fichiers de listes rpm.list/flatpak.list
  --no-gnome-ext  Ne pas traiter la liste gnome-extensions.list
  -y, --yes       Répondre « oui » à toutes les questions (non interactif)
  -q, --quiet     Affichage compact (OK/ERREUR), détails uniquement dans le log
  -v, --version   Afficher la version du script
  -h, --help      Afficher cette aide

Installation système (rend la commande « ${CMD_NAME} » appelable partout) :
  --install       Copier le projet dans ${INSTALL_DIR} et créer
                  le lien ${BIN_DIR}/${CMD_NAME}
                  (clone git si un remote « origin » est configuré,
                  ce qui permet ensuite d'utiliser --update).
                  Régénère aussi les listes réelles (rpm.list,
                  flatpak.list, repos.list, gnome-extensions.list)
                  depuis les gabarits *.list.example du dépôt : c'est
                  une remise à zéro volontaire de vos personnalisations.
  --update        Mettre à jour le script (git pull dans ${INSTALL_DIR},
                  nécessite d'avoir été installé avec un remote git
                  configuré). Ne touche JAMAIS aux listes réelles,
                  seulement au script et aux gabarits *.list.example.
  --uninstall     Supprimer la commande et ${INSTALL_DIR}

Listes réelles vs gabarits :
  Le dépôt ne fournit que des gabarits *.list.example (rpm.list.example,
  flatpak.list.example, repos.list.example, gnome-extensions.list.example).
  Les fichiers réels (rpm.list, flatpak.list, ...) sont générés une seule
  fois depuis ces gabarits (jamais écrasés ensuite, sauf par --install
  explicitement) : vous pouvez les personnaliser librement, --update ne
  les modifiera jamais.

Format de rpm.list / flatpak.list (une entrée par ligne) :
  add:paquet      installe le paquet
  del:paquet      supprime le paquet
  paquet          équivalent à add:paquet
  # ...           commentaire (ignoré), lignes vides ignorées

Format de repos.list (dépôts tiers, une ligne par dépôt) :
  nom | url_cle_gpg | url_du_.repo
  Le script demande pour chaque dépôt s'il faut l'ajouter (--yes = tout oui).
  Installez ensuite ses paquets via rpm.list (ex. add:vivaldi-stable).

Format de gnome-extensions.list (une entrée par ligne, syntaxe add:/del:
identique à rpm.list/flatpak.list) : UUID de l'extension GNOME Shell,
ex. add:dash-to-panel@jderose9.github.com. Géré via gnome-extensions-cli
(gext), installé automatiquement pour l'utilisateur courant (via pipx) —
les extensions GNOME sont un concept par-utilisateur, pas root.

Une fois installé, lancez simplement :  sudo ${CMD_NAME}
EOF
}

#===============================================================================
# VÉRIFICATIONS PRÉALABLES
#===============================================================================

# Crée chaque fichier *.list manquant à partir de son *.list.example
# (jamais l'inverse : un *.list déjà présent n'est jamais touché ici).
ensure_lists_from_examples() {
    local dest example
    for dest in "$RPM_LIST" "$FLATPAK_LIST" "$REPOS_LIST" "$GNOME_EXT_LIST"; do
        example="${dest}.example"
        if [[ ! -f "$dest" && -f "$example" ]]; then
            install -m 644 "$example" "$dest"
            info "Créé $(basename "$dest") depuis $(basename "$example")"
        fi
    done
}

checks() {
    # Le script doit être lancé en root (via sudo) : dnf, fwupd et les
    # installations flatpak --system l'exigent.
    if [[ $(id -u) -ne 0 ]]; then
        error "Ce script doit être lancé avec les droits root : sudo ./${SCRIPT_NAME}"
        exit 1
    fi

    # On ne cible que Fedora (le script utilise dnf, rpmfusion, etc.)
    if [[ ! -e /etc/fedora-release ]]; then
        error "Ce script est prévu pour Fedora uniquement."
        exit 1
    fi

    ensure_lists_from_examples

    # Connexion réseau indispensable (dépôts, téléchargements)
    if ! ping -c 1 -W 3 fedoraproject.org &> /dev/null; then
        error "Pas de connexion réseau. Vérifiez votre connexion et relancez."
        exit 1
    fi

    # Les fichiers de listes doivent exister si on doit les traiter
    if [[ $DO_LISTS -eq 1 ]]; then
        for f in "$RPM_LIST" "$FLATPAK_LIST"; do
            if [[ ! -f "$f" ]]; then
                error "Fichier de liste introuvable : $f"
                exit 1
            fi
        done
    fi

    touch "$LOG_FILE" || { error "Impossible de créer le log $LOG_FILE"; exit 1; }
    info "Machine  : $(cat /sys/devices/virtual/dmi/id/sys_vendor 2>/dev/null) $(cat /sys/devices/virtual/dmi/id/product_family 2>/dev/null)"
    info "Version  : $(cat /etc/fedora-release)"
    info "Journal  : ${C_YELLOW}tail -f $LOG_FILE${C_RESET}"
}

#===============================================================================
# CONFIGURATION DNF
#===============================================================================

# Ajoute une option dans /etc/dnf/dnf.conf si elle n'y figure pas déjà
# (on ne modifie jamais une valeur choisie par l'utilisateur).
dnf_conf_set() {
    local key="$1" value="$2"
    if ! grep -q "^${key}=" /etc/dnf/dnf.conf; then
        run "Option DNF ${key}=${value}" \
            bash -c "echo '${key}=${value}' >> /etc/dnf/dnf.conf"
    fi
}

configure_dnf() {
    section "Configuration de DNF"
    dnf_conf_set "max_parallel_downloads" "10"   # téléchargements parallèles
    dnf_conf_set "fastestmirror" "true"          # sélection du miroir le plus rapide
    dnf_conf_set "countme" "false"               # pas de statistiques d'usage
}

#===============================================================================
# DÉPÔTS : RPM FUSION + FLATHUB
#===============================================================================

setup_repos() {
    section "Configuration des dépôts"

    local fver
    fver=$(rpm -E %fedora)

    # RPM Fusion free/nonfree : indispensable pour les pilotes NVIDIA,
    # les codecs complets et les paquets "tainted".
    if ! pkg_installed rpmfusion-free-release; then
        run "Dépôt RPM Fusion Free" \
            dnf install -y "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fver}.noarch.rpm"
    fi
    if ! pkg_installed rpmfusion-nonfree-release; then
        run "Dépôt RPM Fusion Nonfree" \
            dnf install -y "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${fver}.noarch.rpm"
    fi

    # Dépôts tainted : firmwares et paquets à statut de redistribution flou
    # (libdvdcss, firmwares divers…)
    for p in rpmfusion-free-release-tainted rpmfusion-nonfree-release-tainted; do
        if ! pkg_installed "$p"; then
            run "Composant $p" dnf install -y "$p"
        fi
    done

    # Codec openh264 fourni par Cisco (activé mais désactivé par défaut)
    run "Activation dépôt fedora-cisco-openh264" \
        dnf config-manager setopt fedora-cisco-openh264.enabled=1

    # Flathub : dépôt Flatpak principal
    if ! flatpak remotes | grep -q flathub; then
        run "Dépôt Flathub" \
            flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    else
        info "Dépôt Flathub déjà configuré"
    fi
}

#===============================================================================
# DÉPÔTS TIERS (repos.list) — interactif
#
# Pour chaque dépôt décrit dans repos.list, on demande à l'utilisateur s'il
# faut l'ajouter, puis on importe sa clé GPG et on télécharge son fichier .repo
# dans /etc/yum.repos.d/. Les paquets eux-mêmes s'installent ensuite via
# rpm.list (ex. add:vivaldi-stable une fois le dépôt vivaldi ajouté).
#===============================================================================

install_repos() {
    section "Dépôts tiers ($(basename "$REPOS_LIST"))"

    if [[ ! -f "$REPOS_LIST" ]]; then
        info "Aucun fichier $REPOS_LIST : étape ignorée."
        return
    fi

    local line name gpgkey repourl repofile
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Ignore commentaires et lignes vides
        line="${line#"${line%%[![:space:]]*}"}"   # trim gauche
        [[ -z "$line" || "$line" == \#* ]] && continue

        # Découpe « nom | clé_gpg | url_repo » et supprime les espaces autour
        IFS='|' read -r name gpgkey repourl <<< "$line"
        name="$(echo "$name" | xargs)"
        gpgkey="$(echo "$gpgkey" | xargs)"
        repourl="$(echo "$repourl" | xargs)"

        if [[ -z "$name" || -z "$gpgkey" || -z "$repourl" ]]; then
            error "Ligne repos.list mal formée (attendu « nom | clé | url ») : $line"
            continue
        fi

        repofile="/etc/yum.repos.d/${name}.repo"
        if [[ -f "$repofile" ]]; then
            info "Dépôt « $name » déjà présent ($repofile), ignoré."
            continue
        fi

        if ask_yes_no "Ajouter le dépôt « ${C_BLUE}${name}${C_RESET} » ?"; then
            # Import de la clé GPG puis récupération du fichier .repo directement
            # dans /etc/yum.repos.d/ : méthode portable, indépendante de la
            # syntaxe de « dnf config-manager » (différente entre dnf4 et dnf5).
            run "Import clé GPG $name" rpm --import "$gpgkey"
            run "Ajout dépôt $name"    curl -fsSL -o "$repofile" "$repourl"
        else
            info "Dépôt « $name » ignoré."
        fi
    done < "$REPOS_LIST"
}

#===============================================================================
# MISES À JOUR SYSTÈME
#===============================================================================

update_system() {
    section "Mises à jour du système"
    run "Mise à jour des paquets RPM" dnf upgrade -y --refresh
    run "Mise à jour des Flatpaks" flatpak update --noninteractive
}

update_firmwares() {
    section "Mises à jour des firmwares (fwupd)"

    if ! has_cmd fwupdmgr; then
        run "Installation de fwupd" dnf install -y fwupd
    fi

    # fwupdmgr renvoie des codes non nuls "normaux" (2 = rien à faire),
    # on ne considère donc pas ces retours comme des erreurs bloquantes.
    run "Rafraîchissement des métadonnées" fwupdmgr refresh --force
    if fwupdmgr get-updates >> "$LOG_FILE" 2>&1; then
        run "Application des mises à jour firmware" fwupdmgr update -y
    else
        info "Aucune mise à jour firmware disponible"
    fi
}

#===============================================================================
# PILOTES GRAPHIQUES (détection automatique — s'adapte à chaque PC)
#===============================================================================

# Recense les contrôleurs graphiques présents (VGA, 3D, Display).
# Sur un portable hybride (ex: ThinkPad P15s = Intel + NVIDIA), plusieurs
# GPU sont détectés et chaque branche ci-dessous s'applique indépendamment.
gpu_detect() {
    GPU_INFO=$(lspci | grep -Ei "vga|3d|display")
    info "GPU détecté(s) :"
    while IFS= read -r line; do
        info "  - ${line#*: }"
    done <<< "$GPU_INFO"
}

# NVIDIA : pilote propriétaire akmod (recompilé automatiquement à chaque
# nouveau noyau) + support CUDA/NVENC/VAAPI. Nécessite RPM Fusion nonfree.
gpu_nvidia() {
    run "Pilote NVIDIA (akmod-nvidia)" \
        dnf install -y akmod-nvidia
    run "Support CUDA / NVENC (xorg-x11-drv-nvidia-cuda)" \
        dnf install -y xorg-x11-drv-nvidia-cuda
    run "Accélération vidéo NVIDIA (nvidia-vaapi-driver)" \
        dnf install -y nvidia-vaapi-driver libva-utils vdpauinfo

    # Le module noyau est compilé en arrière-plan par akmods : il ne faut
    # pas redémarrer avant la fin de la compilation.
    info "${C_YELLOW}Note : attendre ~5 min (compilation du module) avant de redémarrer.${C_RESET}"
    info "${C_YELLOW}Vérifier avec : modinfo -F version nvidia${C_RESET}"

    # Secure Boot : le module non signé sera refusé au démarrage.
    if has_cmd mokutil && mokutil --sb-state 2>/dev/null | grep -q enabled; then
        info "${C_YELLOW}Secure Boot actif : le module NVIDIA doit être signé,${C_RESET}"
        info "${C_YELLOW}voir https://rpmfusion.org/Howto/Secure%20Boot${C_RESET}"
    fi
}

# Intel : pilote libre inclus dans Mesa ; on ajoute le décodage vidéo
# matériel (VAAPI) via intel-media-driver (Broadwell et +).
gpu_intel() {
    run "Accélération vidéo Intel (intel-media-driver)" \
        dnf install -y intel-media-driver
}

# AMD : pilote libre inclus dans Mesa ; on remplace les drivers VAAPI/VDPAU
# bridés de Fedora par les versions complètes "freeworld" de RPM Fusion.
gpu_amd() {
    run "Codecs Mesa VAAPI freeworld" \
        dnf swap -y mesa-va-drivers mesa-va-drivers-freeworld --allowerasing
    run "Codecs Mesa VDPAU freeworld" \
        dnf swap -y mesa-vdpau-drivers mesa-vdpau-drivers-freeworld --allowerasing
}

setup_gpu() {
    section "Pilotes graphiques"
    gpu_detect

    # ${var,,} : conversion en minuscules pour une comparaison fiable
    local gpu_lc="${GPU_INFO,,}"

    if [[ "$gpu_lc" =~ nvidia ]]; then
        info "-> Configuration NVIDIA"
        gpu_nvidia
    fi
    if [[ "$gpu_lc" =~ intel ]]; then
        info "-> Configuration Intel"
        gpu_intel
    fi
    if [[ "$gpu_lc" =~ (amd|radeon|advanced\ micro) ]]; then
        info "-> Configuration AMD"
        gpu_amd
    fi
}

#===============================================================================
# CODECS MULTIMÉDIA
#===============================================================================

setup_multimedia() {
    section "Codecs multimédia"

    # ffmpeg complet de RPM Fusion à la place de la version bridée de Fedora
    if pkg_installed ffmpeg-free; then
        run "Remplacement ffmpeg-free -> ffmpeg" \
            dnf swap -y ffmpeg-free ffmpeg --allowerasing
    else
        info "ffmpeg complet déjà en place"
    fi

    # Groupes multimédia de RPM Fusion (gstreamer complet, etc.)
    run "Groupe multimedia" \
        dnf group install -y multimedia --setopt=install_weak_deps=False --exclude=PackageKit-gstreamer-plugin
    run "Groupe sound-and-video" \
        dnf group install -y sound-and-video
}

#===============================================================================
# TRAITEMENT DES LISTES DE PAQUETS
#===============================================================================

# Lit un fichier de liste et exécute install/remove pour chaque entrée.
#   $1 : chemin du fichier
#   $2 : type ("rpm" ou "flatpak")
process_list() {
    local file="$1" type="$2"
    local line action pkg

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Nettoyage : espaces autour, commentaires, lignes vides
        line="${line#"${line%%[![:space:]]*}"}"   # trim gauche
        line="${line%"${line##*[![:space:]]}"}"   # trim droite
        [[ -z "$line" || "$line" == \#* ]] && continue

        # Détermine l'action : add:/del:, sinon add implicite
        case "$line" in
            add:*) action="add"; pkg="${line#add:}" ;;
            del:*) action="del"; pkg="${line#del:}" ;;
            *)     action="add"; pkg="$line" ;;
        esac

        if [[ "$type" == "rpm" ]]; then
            if [[ "$action" == "add" ]] && ! pkg_installed "$pkg"; then
                run "Installation RPM $pkg" dnf install -y "$pkg"
            elif [[ "$action" == "del" ]] && pkg_installed "$pkg"; then
                run "Suppression RPM $pkg" dnf remove -y "$pkg"
            fi
        else
            if [[ "$action" == "add" ]] && ! flatpak_installed "$pkg"; then
                run "Installation Flatpak $pkg" \
                    flatpak install flathub --noninteractive -y "$pkg"
            elif [[ "$action" == "del" ]] && flatpak_installed "$pkg"; then
                run "Suppression Flatpak $pkg" \
                    flatpak uninstall --noninteractive -y "$pkg"
            fi
        fi
    done < "$file"
}

install_lists() {
    section "Paquets RPM ($(basename "$RPM_LIST"))"
    process_list "$RPM_LIST" "rpm"

    section "Paquets Flatpak ($(basename "$FLATPAK_LIST"))"
    process_list "$FLATPAK_LIST" "flatpak"

    # Purge des runtimes flatpak devenus inutiles après suppression
    run "Nettoyage des runtimes Flatpak inutilisés" \
        flatpak uninstall --unused --noninteractive -y
}

#===============================================================================
# EXTENSIONS GNOME SHELL (gnome-extensions.list)
#
# Les extensions GNOME Shell sont un concept PAR-UTILISATEUR (répertoire
# ~/.local/share/gnome-shell/extensions et clé dconf enabled-extensions du
# profil utilisateur) : impossible de les gérer en root. Le script, lancé
# globalement via sudo, bascule donc sur l'utilisateur réel ($SUDO_USER) et
# son bus D-Bus de session pour toutes les opérations gext.
#===============================================================================

# Détermine l'utilisateur réel derrière le sudo (celui qui a une session GNOME).
gnome_user() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        echo "$SUDO_USER"
    else
        error "Impossible de déterminer l'utilisateur cible pour les extensions GNOME (lancez via sudo, pas en root direct)."
        return 1
    fi
}

# Exécute une commande en tant que l'utilisateur GNOME cible, avec son bus
# D-Bus de session (nécessaire pour que gext puisse parler à GNOME Shell).
run_as_gnome_user() {
    local user uid
    user="$(gnome_user)" || return 1
    uid="$(id -u "$user")"
    sudo -u "$user" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
        XDG_RUNTIME_DIR="/run/user/${uid}" \
        "$@"
}

# Vrai si la commande gext est disponible pour l'utilisateur cible
gext_installed() {
    run_as_gnome_user command -v gext &> /dev/null
}

# Vrai si l'extension (UUID) est installée (activée ou non) pour l'utilisateur cible
gnome_ext_installed() {
    run_as_gnome_user gext list -a 2>/dev/null | grep -qF "$1"
}

# Installe gnome-extensions-cli (gext) pour l'utilisateur cible via pipx.
# --system-site-packages : réutilise PyGObject déjà présent au niveau système
# au lieu de tenter de le recompiler dans l'environnement virtuel de pipx.
setup_gnome_extensions_cli() {
    if gext_installed; then
        return 0
    fi

    if ! has_cmd pipx; then
        run "Installation de pipx" dnf install -y pipx
    fi

    run "Installation de gnome-extensions-cli (pipx, utilisateur $(gnome_user))" \
        run_as_gnome_user pipx install gnome-extensions-cli --system-site-packages
}

# Lit gnome-extensions.list et installe/désinstalle chaque extension.
#   $1 : chemin du fichier
process_gnome_extensions() {
    local file="$1"
    local line action uuid

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Nettoyage : espaces autour, commentaires, lignes vides
        line="${line#"${line%%[![:space:]]*}"}"   # trim gauche
        line="${line%"${line##*[![:space:]]}"}"   # trim droite
        [[ -z "$line" || "$line" == \#* ]] && continue

        # Détermine l'action : add:/del:, sinon add implicite
        case "$line" in
            add:*) action="add"; uuid="${line#add:}" ;;
            del:*) action="del"; uuid="${line#del:}" ;;
            *)     action="add"; uuid="$line" ;;
        esac

        if [[ "$action" == "add" ]] && ! gnome_ext_installed "$uuid"; then
            run "Installation extension GNOME $uuid" \
                run_as_gnome_user gext install --filesystem "$uuid"
            run "Activation extension GNOME $uuid" \
                run_as_gnome_user gext enable "$uuid"
        elif [[ "$action" == "del" ]] && gnome_ext_installed "$uuid"; then
            run "Suppression extension GNOME $uuid" \
                run_as_gnome_user gext uninstall "$uuid"
        fi
    done < "$file"
}

install_gnome_extensions() {
    section "Extensions GNOME Shell ($(basename "$GNOME_EXT_LIST"))"

    if [[ ! -f "$GNOME_EXT_LIST" ]]; then
        info "Aucun fichier $GNOME_EXT_LIST : étape ignorée."
        return
    fi

    if ! gnome_user &> /dev/null; then
        info "Étape ignorée (voir erreur ci-dessus)."
        return
    fi

    setup_gnome_extensions_cli
    process_gnome_extensions "$GNOME_EXT_LIST"
}

#===============================================================================
# REDÉMARRAGE
#===============================================================================

ask_reboot() {
    section "Fin du script"

    # dnf needs-restarting -r : code 1 si un redémarrage est recommandé
    if dnf needs-restarting -r >> "$LOG_FILE" 2>&1; then
        info "${C_GREEN}Aucun redémarrage nécessaire. Terminé !${C_RESET}"
        return
    fi

    echo -ne "${C_YELLOW}Un redémarrage est recommandé. Redémarrer maintenant ? [y/N] : ${C_RESET}"
    read -r answer
    if [[ "${answer,,}" == "y" ]]; then
        log "Reboot demandé par l'utilisateur"
        systemctl reboot
    else
        info "Pensez à redémarrer plus tard pour appliquer tous les changements."
    fi
}

#===============================================================================
# INSTALLATION / MISE À JOUR / DÉSINSTALLATION SYSTÈME
#
# --install copie le projet dans /opt/fedora-setup et crée un lien symbolique
# /usr/local/bin/fedora-setup, de sorte que la commande « fedora-setup » soit
# appelable depuis n'importe quel dossier (/usr/local/bin est dans le PATH).
#
# Les listes réelles (rpm.list, flatpak.list, repos.list,
# gnome-extensions.list) ne sont JAMAIS versionnées dans le dépôt (voir
# .gitignore) : seuls des gabarits *.list.example le sont. --install
# régénère systématiquement les listes réelles depuis ces gabarits (remise à
# zéro volontaire), alors que --update (git pull) ne touche qu'au script et
# aux gabarits — jamais aux listes personnalisées de l'utilisateur.
#
# Si le dépôt source a un remote « origin » configuré, --install clone le
# dépôt (au lieu de copier les fichiers un par un) : cela permet ensuite de
# mettre à jour l'installation via --update (git pull). Sans remote, --install
# revient à la copie de fichiers classique et --update n'est pas disponible.
#===============================================================================

# Fichiers du projet installés tels quels (gabarits *.example + README)
INSTALL_FILES=(rpm.list.example flatpak.list.example repos.list.example gnome-extensions.list.example README.md)
readonly INSTALL_FILES

install_command() {
    if [[ $(id -u) -ne 0 ]]; then
        error "L'installation nécessite les droits root : sudo ./${SCRIPT_NAME} --install"
        exit 1
    fi

    echo -e "${C_BOLD}Installation de la commande « ${CMD_NAME} »${C_RESET}"

    local origin_url
    origin_url="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || true)"

    if [[ -n "$origin_url" && ! -d "$INSTALL_DIR/.git" ]]; then
        # Un remote existe et aucune installation git n'est déjà en place :
        # on clone pour pouvoir utiliser --update ensuite.
        rm -rf "$INSTALL_DIR"
        run "Clonage du dépôt dans ${INSTALL_DIR}" git clone "$origin_url" "$INSTALL_DIR"
    elif [[ -n "$origin_url" && -d "$INSTALL_DIR/.git" ]]; then
        info "Installation git déjà en place dans ${INSTALL_DIR} (utilisez --update pour la synchroniser)."
    else
        # Pas de remote configuré : copie de fichiers classique, --update indisponible.
        install -d "$INSTALL_DIR"
        install -m 755 "${SCRIPT_DIR}/${SCRIPT_NAME}" "${INSTALL_DIR}/${SCRIPT_NAME}"
        for f in "${INSTALL_FILES[@]}"; do
            if [[ -f "${SCRIPT_DIR}/$f" ]]; then
                install -m 644 "${SCRIPT_DIR}/$f" "${INSTALL_DIR}/$f"
            fi
        done
        info "Aucun remote git « origin » configuré : installation par copie, --update indisponible."
    fi

    # Le script installé doit être exécutable même après un clone git
    chmod 755 "${INSTALL_DIR}/${SCRIPT_NAME}"

    # Remise à zéro volontaire des listes réelles depuis les gabarits *.example
    # (--install écrase toujours ; --update, lui, n'y touche jamais)
    local f dest
    for f in "${INSTALL_DIR}"/*.list.example; do
        [[ -e "$f" ]] || continue
        dest="${f%.example}"
        install -m 644 "$f" "$dest"
    done

    # Lien symbolique dans le PATH -> commande accessible partout
    ln -sf "${INSTALL_DIR}/${SCRIPT_NAME}" "${BIN_DIR}/${CMD_NAME}"

    echo -e "    Fichiers installés dans : ${C_BLUE}${INSTALL_DIR}${C_RESET}"
    echo -e "    Commande disponible     : ${C_GREEN}${CMD_NAME}${C_RESET} (${BIN_DIR}/${CMD_NAME}), version ${VERSION}"
    echo -e "    Listes à personnaliser  : ${INSTALL_DIR}/rpm.list , ${INSTALL_DIR}/flatpak.list , ${INSTALL_DIR}/gnome-extensions.list"
    echo -e "    ${C_YELLOW}Note : --install régénère toujours ces listes depuis les *.list.example${C_RESET}"
    echo -e "    ${C_YELLOW}(remise à zéro) ; --update, lui, ne les touche jamais.${C_RESET}"
    echo -e "\n    Lancez maintenant : ${C_YELLOW}sudo ${CMD_NAME}${C_RESET}"
}

update_command() {
    if [[ $(id -u) -ne 0 ]]; then
        error "La mise à jour nécessite les droits root : sudo ${CMD_NAME} --update"
        exit 1
    fi

    if [[ ! -d "$INSTALL_DIR/.git" ]]; then
        error "Installation non-git dans ${INSTALL_DIR} : impossible de mettre à jour."
        error "Relancez --install depuis un clone avec un remote « origin » configuré."
        exit 1
    fi

    echo -e "${C_BOLD}Mise à jour de la commande « ${CMD_NAME} »${C_RESET}"

    local old_version
    old_version="$(grep -m1 '^readonly VERSION=' "$INSTALL_DIR/${SCRIPT_NAME}" | sed -E 's/^readonly VERSION="(.*)"$/\1/')"

    run "Récupération des mises à jour (git pull)" git -C "$INSTALL_DIR" pull --ff-only
    chmod 755 "${INSTALL_DIR}/${SCRIPT_NAME}"
    ln -sf "${INSTALL_DIR}/${SCRIPT_NAME}" "${BIN_DIR}/${CMD_NAME}"

    local new_version
    new_version="$(grep -m1 '^readonly VERSION=' "$INSTALL_DIR/${SCRIPT_NAME}" | sed -E 's/^readonly VERSION="(.*)"$/\1/')"

    echo -e "    Version : ${C_YELLOW}${old_version}${C_RESET} -> ${C_GREEN}${new_version}${C_RESET}"
}

uninstall_command() {
    if [[ $(id -u) -ne 0 ]]; then
        error "La désinstallation nécessite les droits root : sudo ${CMD_NAME} --uninstall"
        exit 1
    fi

    echo -e "${C_BOLD}Désinstallation de la commande « ${CMD_NAME} »${C_RESET}"
    rm -f "${BIN_DIR}/${CMD_NAME}"
    rm -rf "$INSTALL_DIR"
    echo -e "    ${C_GREEN}Commande et fichiers supprimés.${C_RESET}"
    echo -e "    (Les journaux dans /var/log/fedora-setup_*.log sont conservés.)"
}

#===============================================================================
# ARGUMENTS
#===============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -r)            RPM_LIST="$(realpath "$2")"; shift 2 ;;
            -f)            FLATPAK_LIST="$(realpath "$2")"; shift 2 ;;
            -d)            REPOS_LIST="$(realpath "$2")"; shift 2 ;;
            -e)            GNOME_EXT_LIST="$(realpath "$2")"; shift 2 ;;
            --no-update)   DO_UPDATE=0; shift ;;
            --no-firmware) DO_FIRMWARE=0; shift ;;
            --no-gpu)      DO_GPU=0; shift ;;
            --no-repos)    DO_REPOS=0; shift ;;
            --no-lists)    DO_LISTS=0; shift ;;
            --no-gnome-ext) DO_GNOME_EXT=0; shift ;;
            -y|--yes)      ASSUME_YES=1; shift ;;
            -q|--quiet)    VERBOSE=0; shift ;;
            -v|--version)  echo "$VERSION"; exit 0 ;;
            --install)     install_command; exit 0 ;;
            --update)      update_command; exit 0 ;;
            --uninstall)   uninstall_command; exit 0 ;;
            -h|--help)     usage; exit 0 ;;
            *)             error "Option inconnue : $1"; usage; exit 1 ;;
        esac
    done
}

#===============================================================================
# PROGRAMME PRINCIPAL
#===============================================================================

main() {
    parse_args "$@"

    echo -e "${C_BOLD}=== Fedora Setup v${VERSION} — post-installation & maintenance ===${C_RESET}"
    checks

    configure_dnf
    setup_repos

    [[ $DO_REPOS -eq 1 ]]    && install_repos
    [[ $DO_UPDATE -eq 1 ]]   && update_system
    [[ $DO_FIRMWARE -eq 1 ]] && update_firmwares
    [[ $DO_GPU -eq 1 ]]      && setup_gpu

    setup_multimedia

    [[ $DO_LISTS -eq 1 ]]    && install_lists
    [[ $DO_GNOME_EXT -eq 1 ]] && install_gnome_extensions

    ask_reboot
}

main "$@"
