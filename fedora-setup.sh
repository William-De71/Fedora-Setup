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

# Fichiers de listes par défaut (surchargables via -r / -f / -d)
RPM_LIST="${SCRIPT_DIR}/rpm.list"
FLATPAK_LIST="${SCRIPT_DIR}/flatpak.list"
REPOS_LIST="${SCRIPT_DIR}/repos.list"

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
  --no-update     Ne pas faire les mises à jour RPM/Flatpak
  --no-firmware   Ne pas mettre à jour les firmwares (fwupd)
  --no-gpu        Ne pas installer les pilotes graphiques
  --no-repos      Ne pas ajouter les dépôts tiers de repos.list
  --no-lists      Ne pas traiter les fichiers de listes
  -y, --yes       Répondre « oui » à toutes les questions (non interactif)
  -q, --quiet     Affichage compact (OK/ERREUR), détails uniquement dans le log
  -h, --help      Afficher cette aide

Installation système (rend la commande « ${CMD_NAME} » appelable partout) :
  --install       Copier le projet dans ${INSTALL_DIR} et créer
                  le lien ${BIN_DIR}/${CMD_NAME}
  --uninstall     Supprimer la commande et ${INSTALL_DIR}

Format de rpm.list / flatpak.list (une entrée par ligne) :
  add:paquet      installe le paquet
  del:paquet      supprime le paquet
  paquet          équivalent à add:paquet
  # ...           commentaire (ignoré), lignes vides ignorées

Format de repos.list (dépôts tiers, une ligne par dépôt) :
  nom | url_cle_gpg | url_du_.repo
  Le script demande pour chaque dépôt s'il faut l'ajouter (--yes = tout oui).
  Installez ensuite ses paquets via rpm.list (ex. add:vivaldi-stable).

Une fois installé, lancez simplement :  sudo ${CMD_NAME}
EOF
}

#===============================================================================
# VÉRIFICATIONS PRÉALABLES
#===============================================================================

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
# INSTALLATION / DÉSINSTALLATION SYSTÈME
#
# --install copie le projet dans /opt/fedora-setup et crée un lien symbolique
# /usr/local/bin/fedora-setup, de sorte que la commande « fedora-setup » soit
# appelable depuis n'importe quel dossier (/usr/local/bin est dans le PATH).
# Les listes rpm.list / flatpak.list se trouvent alors dans /opt/fedora-setup
# et peuvent y être éditées durablement.
#===============================================================================

install_command() {
    if [[ $(id -u) -ne 0 ]]; then
        error "L'installation nécessite les droits root : sudo ./${SCRIPT_NAME} --install"
        exit 1
    fi

    echo -e "${C_BOLD}Installation de la commande « ${CMD_NAME} »${C_RESET}"

    # Copie du projet complet (script + listes + README) vers INSTALL_DIR
    install -d "$INSTALL_DIR"
    install -m 755 "${SCRIPT_DIR}/${SCRIPT_NAME}" "${INSTALL_DIR}/${SCRIPT_NAME}"
    for f in rpm.list flatpak.list repos.list README.md; do
        # On n'écrase pas une liste déjà personnalisée lors d'une réinstallation
        if [[ -f "${SCRIPT_DIR}/$f" && ! -f "${INSTALL_DIR}/$f" ]]; then
            install -m 644 "${SCRIPT_DIR}/$f" "${INSTALL_DIR}/$f"
        fi
    done

    # Lien symbolique dans le PATH -> commande accessible partout
    ln -sf "${INSTALL_DIR}/${SCRIPT_NAME}" "${BIN_DIR}/${CMD_NAME}"

    echo -e "    Fichiers installés dans : ${C_BLUE}${INSTALL_DIR}${C_RESET}"
    echo -e "    Commande disponible     : ${C_GREEN}${CMD_NAME}${C_RESET} (${BIN_DIR}/${CMD_NAME})"
    echo -e "    Listes à personnaliser  : ${INSTALL_DIR}/rpm.list , ${INSTALL_DIR}/flatpak.list"
    echo -e "\n    Lancez maintenant : ${C_YELLOW}sudo ${CMD_NAME}${C_RESET}"
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
            --no-update)   DO_UPDATE=0; shift ;;
            --no-firmware) DO_FIRMWARE=0; shift ;;
            --no-gpu)      DO_GPU=0; shift ;;
            --no-repos)    DO_REPOS=0; shift ;;
            --no-lists)    DO_LISTS=0; shift ;;
            -y|--yes)      ASSUME_YES=1; shift ;;
            -q|--quiet)    VERBOSE=0; shift ;;
            --install)     install_command; exit 0 ;;
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

    echo -e "${C_BOLD}=== Fedora Setup — post-installation & maintenance ===${C_RESET}"
    checks

    configure_dnf
    setup_repos

    [[ $DO_REPOS -eq 1 ]]    && install_repos
    [[ $DO_UPDATE -eq 1 ]]   && update_system
    [[ $DO_FIRMWARE -eq 1 ]] && update_firmwares
    [[ $DO_GPU -eq 1 ]]      && setup_gpu

    setup_multimedia

    [[ $DO_LISTS -eq 1 ]]    && install_lists

    ask_reboot
}

main "$@"
