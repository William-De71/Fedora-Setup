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
#                 - Installe Docker CE sur demande (--docker)
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

# /var/log n'est accessible en écriture qu'à root. Le script s'exécute
# normalement via sudo, mais --dry-run est utilisable sans privilèges (pour
# auditer ce qui serait fait) : dans ce cas le journal va dans /tmp.
if [[ $(id -u) -eq 0 ]]; then
    LOG_FILE="/var/log/fedora-setup_$(date '+%Y%m%d-%H%M%S').log"
else
    LOG_FILE="${TMPDIR:-/tmp}/fedora-setup_$(date '+%Y%m%d-%H%M%S').log"
fi
readonly SCRIPT_PATH SCRIPT_DIR SCRIPT_NAME LOG_FILE

# Version du script (affichée par -v/--version et au démarrage)
readonly VERSION="0.6.0"

# Fichiers de listes par défaut (surchargables via -r / -f / -d / -e).
# Ces fichiers *.list ne sont jamais versionnés (voir .gitignore) : ils sont
# générés une fois depuis les *.list.example fournis par le dépôt (voir
# ensure_lists_from_examples), puis personnalisés librement sans risque
# qu'une mise à jour (--update) ne les modifie ou ne les écrase.
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
DRY_RUN=0          # Simulation : affiche les commandes sans les exécuter
DO_SNAPSHOT=0      # Instantané Btrfs avant modification (--snapshot)

# Action autonome demandée (--clean, --memory…) : nom de la fonction à
# appeler après le parsing, au lieu du traitement principal. Vide = flux
# normal de post-installation.
ACTION=""

# Mis à 1 par une action autonome après laquelle un redémarrage peut être
# nécessaire (--update-system) : main() propose alors de redémarrer.
OFFER_REBOOT=0

# Compteurs alimentés par run(), utilisés par le récapitulatif final.
COUNT_OK=0
COUNT_FAIL=0
COUNT_SKIPPED=0
FAILED_ACTIONS=()

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
#
# En mode simulation (--dry-run), la commande est affichée et journalisée
# mais jamais exécutée, et le résultat est compté comme « simulé ».
run() {
    local label="$1"; shift
    local rc

    if [[ $DRY_RUN -eq 1 ]]; then
        echo -e "    ${label} : ${C_BLUE}simulé${C_RESET}"
        echo -e "        ${C_BOLD}\$${C_RESET} $*"
        log "DRY-RUN: $*"
        COUNT_SKIPPED=$((COUNT_SKIPPED + 1))
        return 0
    fi

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
        COUNT_OK=$((COUNT_OK + 1))
    else
        echo -e "${C_RED}ERREUR${C_RESET} (voir $LOG_FILE)"
        COUNT_FAIL=$((COUNT_FAIL + 1))
        # Mémorisé pour le récapitulatif final : sans cela, une erreur
        # survenue en début de traitement disparaît sous des centaines de
        # lignes de sortie dnf.
        FAILED_ACTIONS+=("$label")
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

# Préambule commun aux options autonomes (--clean, --memory, --boot…) :
# vérifie les droits, la distribution et prépare le journal.
#   $1 : nom de l'option (pour le message d'erreur)
#   $2 : titre affiché en en-tête
#
# En simulation, l'absence de droits root n'est pas bloquante : aucune
# commande n'étant exécutée, on veut pouvoir auditer l'option sans sudo.
require_root_for() {
    local opt="$1" title="$2"

    if [[ $(id -u) -ne 0 && $DRY_RUN -eq 0 ]]; then
        error "Cette opération nécessite les droits root : sudo ${CMD_NAME} ${opt}"
        exit 1
    fi

    if [[ ! -e /etc/fedora-release ]]; then
        error "Ce script est prévu pour Fedora uniquement."
        exit 1
    fi

    touch "$LOG_FILE" || { error "Impossible de créer le log $LOG_FILE"; exit 1; }

    echo -e "${C_BOLD}=== Fedora Setup v${VERSION} — ${title} ===${C_RESET}"
    if [[ $DRY_RUN -eq 1 ]]; then
        echo -e "${C_BLUE}Mode simulation : aucune modification ne sera appliquée.${C_RESET}"
    fi
    info "Journal  : ${C_YELLOW}tail -f $LOG_FILE${C_RESET}"
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
  -n, --dry-run   Simulation : affiche les commandes sans rien exécuter.
                  Utilisable sans sudo, pour auditer ce que ferait le script.
  --snapshot      Créer un instantané Btrfs de / avant toute modification
                  (filet de sécurité en cas de mise à jour ratée ; sans
                  effet si la racine n'est pas en Btrfs)
  -v, --version   Afficher la version du script
  -h, --help      Afficher cette aide

Installation système (rend la commande « ${CMD_NAME} » appelable partout) :
  --install       Copier le projet dans ${INSTALL_DIR} et créer
                  le lien ${BIN_DIR}/${CMD_NAME}
                  (clone git de la dernière release vX.Y.Z si un remote
                  « origin » est configuré, ce qui permet ensuite
                  d'utiliser --update).
                  Régénère aussi les listes réelles (rpm.list,
                  flatpak.list, repos.list, gnome-extensions.list)
                  depuis les gabarits *.list.example du dépôt : c'est
                  une remise à zéro volontaire de vos personnalisations.
  --update        Mettre à jour vers la dernière release taggée (vX.Y.Z)
                  dans ${INSTALL_DIR} (nécessite un remote git configuré).
                  Sans tag disponible, se rabat sur un git pull classique.
                  Ne touche JAMAIS aux listes réelles, seulement au script
                  et aux gabarits *.list.example.
  --uninstall     Supprimer la commande et ${INSTALL_DIR}
  --bashrc        Installer ~/.bashrc (utilisateur \$SUDO_USER) depuis
                  bashrc.example, en sauvegardant l'ancien en ~/.bashrc.bak
                  si présent et différent. N'est jamais exécuté
                  automatiquement, uniquement sur demande explicite.
  --docker        Installer et configurer Docker CE depuis le dépôt officiel
                  (moteur, CLI, containerd, plugins buildx et compose),
                  ajouter \$SUDO_USER au groupe docker et valider avec
                  l'image hello-world. N'est jamais exécuté automatiquement.

Mise à jour courante :
  --update-system Mettre à jour le système et rien d'autre : paquets RPM,
                  Flatpaks et firmwares (sauf avec --no-firmware), puis
                  redémarrage proposé si nécessaire. Ne reconfigure ni les
                  dépôts, ni les pilotes, ni les listes, et ne change pas
                  de version de Fedora (voir --upgrade). À ne pas confondre
                  avec --update, qui met à jour le script lui-même.

Nettoyage & maintenance :
  --clean         Récupérer de l'espace disque : paquets orphelins, cache
                  DNF, journal systemd (plafonné à ${JOURNAL_MAX_SIZE}),
                  anciens noyaux, runtimes Flatpak inutilisés, anciens
                  journaux du script (${SETUP_LOG_KEEP} conservés) et TRIM
                  du SSD. Affiche l'espace récupéré. N'est jamais exécuté
                  automatiquement.

Réactivité du système :
  --memory        Adapter les réglages mémoire du noyau au swap zram de
                  Fedora : vm.swappiness=180 (au lieu de 60, pensé pour un
                  swap sur disque), cache de métadonnées conservé plus
                  longtemps, écritures en attente bornées pour éviter les
                  à-coups d'E/S. Vérifie aussi systemd-oomd. Écrit dans
                  ${SYSCTL_CONF}. N'est jamais exécuté automatiquement.

Optimisation du démarrage :
  --boot          Analyser le temps de démarrage et proposer, une par une,
                  les désactivations utiles : NetworkManager-wait-online
                  (plusieurs secondes perdues sur un poste de bureau), cups
                  si aucune imprimante n'est configurée, bluetooth si aucun
                  contrôleur n'est présent, et réduction du délai du menu
                  GRUB. Les services sont désactivés, pas masqués : un
                  « systemctl enable » suffit à revenir en arrière.
                  N'est jamais exécuté automatiquement.

Portable / autonomie :
  --laptop        Optimiser l'autonomie : choix du gestionnaire d'énergie
                  (TLP ou power-profiles-daemon — jamais les deux, ils se
                  contredisent), thermald sur processeur Intel, et réglages
                  powertop optionnels. Détecte la batterie et demande
                  confirmation sur un poste fixe. N'est jamais exécuté
                  automatiquement.

Sécurité & réseau :
  --security      Vérifier et renforcer les protections de base : état de
                  SELinux, pare-feu firewalld et zone appliquée, mises à
                  jour de sécurité automatiques (téléchargement et
                  notification, jamais d'installation silencieuse) et
                  DNS-over-TLS. Constate et propose, ne durcit jamais sans
                  confirmation. N'est jamais exécuté automatiquement.

Outils de développement :
  --devtools      Proposer, un par un : distrobox (conteneurs de
                  développement jetables, toutes distributions), la
                  virtualisation KVM/libvirt/virt-manager (vérifie le
                  support VT-x/AMD-V et ajoute l'utilisateur au groupe
                  libvirt) et des polices libres (Liberation, Noto,
                  Fira Code, JetBrains Mono).
                  N'est jamais exécuté automatiquement.

Montée de version :
  --upgrade       Passer à la version suivante de Fedora (N -> N+1) dès
                  qu'elle est publiée en stable (jamais une bêta), selon la
                  procédure officielle dnf system-upgrade : mise à jour
                  complète du système, instantané Btrfs proposé,
                  téléchargement, puis installation au redémarrage
                  (demandé, jamais imposé). Signale les dépôts tiers, le
                  pilote NVIDIA et le fonctionnement sur batterie avant de
                  commencer. N'est jamais exécuté automatiquement.

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
            if [[ $DRY_RUN -eq 1 ]]; then
                info "${C_BLUE}simulé${C_RESET} : créerait $(basename "$dest") depuis $(basename "$example")"
                continue
            fi
            install -m 644 "$example" "$dest"
            info "Créé $(basename "$dest") depuis $(basename "$example")"
        fi
    done
}

checks() {
    # Le script doit être lancé en root (via sudo) : dnf, fwupd et les
    # installations flatpak --system l'exigent. En simulation, aucune de ces
    # commandes n'est exécutée : on autorise donc l'exécution sans sudo,
    # précisément pour permettre d'auditer le script avant de lui confier
    # les droits root.
    if [[ $(id -u) -ne 0 ]]; then
        if [[ $DRY_RUN -eq 0 ]]; then
            error "Ce script doit être lancé avec les droits root : sudo ./${SCRIPT_NAME}"
            exit 1
        fi
        info "${C_YELLOW}Simulation sans droits root : certains états (paquets${C_RESET}"
        info "${C_YELLOW}installés, services) restent lisibles, mais l'exécution${C_RESET}"
        info "${C_YELLOW}réelle nécessitera sudo.${C_RESET}"
    fi

    # On ne cible que Fedora (le script utilise dnf, rpmfusion, etc.)
    if [[ ! -e /etc/fedora-release ]]; then
        error "Ce script est prévu pour Fedora uniquement."
        exit 1
    fi

    ensure_lists_from_examples

    # Connexion réseau indispensable (dépôts, téléchargements). Certains
    # réseaux (entreprise, hôtel) filtrent l'ICMP : un ping sans réponse n'est
    # pas une preuve d'absence de réseau, d'où le second essai en HTTPS.
    if ! ping -c 1 -W 3 fedoraproject.org &> /dev/null \
        && ! curl -fsS --max-time 5 -o /dev/null https://fedoraproject.org &> /dev/null; then
        error "Pas de connexion réseau. Vérifiez votre connexion et relancez."
        exit 1
    fi

    # Les fichiers de listes doivent exister si on doit les traiter.
    # En simulation, leur création a seulement été annoncée : exiger leur
    # présence ferait échouer un dry-run lancé sur une copie fraîche du dépôt.
    if [[ $DO_LISTS -eq 1 && $DRY_RUN -eq 0 ]]; then
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
    dnf_conf_set "installonly_limit" "2"         # 2 noyaux conservés au lieu de 3
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

    # Flathub : dépôt Flatpak principal. Flatpak est livré avec Workstation,
    # mais absent d'une installation minimale (Server, Everything, conteneur).
    if ! has_cmd flatpak; then
        run "Installation de Flatpak" dnf install -y flatpak
    fi
    if ! flatpak remotes 2>/dev/null | grep -q flathub; then
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

    local list_file
    list_file="$(resolve_list "$REPOS_LIST")"
    if [[ -z "$list_file" ]]; then
        info "Aucun fichier $REPOS_LIST : étape ignorée."
        return
    fi
    if [[ "$list_file" != "$REPOS_LIST" ]]; then
        info "${C_BLUE}simulé${C_RESET} : lecture de $(basename "$list_file")"
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
    done < "$list_file"
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

# Mise à jour seule (--update-system) : le flux principal reconfigure aussi
# les dépôts, les pilotes et les listes, ce qui est superflu pour la mise à
# jour courante. Ne change jamais de version de Fedora (voir --upgrade).
update_only() {
    require_root_for "--update-system" "mise à jour du système"

    [[ $DO_SNAPSHOT -eq 1 ]] && { section "Instantané Btrfs"; create_snapshot; }

    update_system
    [[ $DO_FIRMWARE -eq 1 ]] && update_firmwares

    OFFER_REBOOT=1
}

#===============================================================================
# PILOTES GRAPHIQUES (détection automatique — s'adapte à chaque PC)
#===============================================================================

# Recense les contrôleurs graphiques présents (VGA, 3D, Display).
# Sur un portable hybride (ex: ThinkPad P15s = Intel + NVIDIA), plusieurs
# GPU sont détectés et chaque branche ci-dessous s'applique indépendamment.
#
# On filtre sur la classe PCI complète : un simple « 3d » correspondrait
# aussi à une adresse de bus (ex. « 3d:00.0 » d'un SSD NVMe Intel) et
# déclencherait à tort l'installation de pilotes graphiques.
gpu_detect() {
    # lspci (pciutils) manque sur une installation minimale
    if ! has_cmd lspci; then
        run "Installation de pciutils (lspci)" dnf install -y pciutils
    fi
    GPU_INFO=$(lspci 2>/dev/null | grep -E "VGA compatible controller|3D controller|Display controller")
    if [[ -z "$GPU_INFO" ]]; then
        info "Aucun contrôleur graphique détecté (machine virtuelle, conteneur ?)."
        return 0
    fi
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

# Chemin de liste réellement lisible. En simulation, un fichier *.list peut
# n'avoir été que « créé » symboliquement : on se rabat alors sur son
# gabarit pour montrer malgré tout ce qui serait fait. Affiche le chemin
# retenu, ou rien si aucun n'existe.
#   $1 : chemin du fichier de liste
resolve_list() {
    local file="$1"
    if [[ -f "$file" ]]; then
        echo "$file"
    elif [[ $DRY_RUN -eq 1 && -f "${file}.example" ]]; then
        echo "${file}.example"
    fi
}

# Lit un fichier de liste et exécute install/remove pour chaque entrée.
#   $1 : chemin du fichier
#   $2 : type ("rpm" ou "flatpak")
process_list() {
    local file="$1" type="$2"
    local line action pkg

    local resolved
    resolved="$(resolve_list "$file")"
    if [[ -z "$resolved" ]]; then
        info "Fichier introuvable : $file — étape ignorée."
        return 0
    fi
    if [[ "$resolved" != "$file" ]]; then
        info "${C_BLUE}simulé${C_RESET} : lecture de $(basename "$resolved")"
        file="$resolved"
    fi

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
#
# sudo remplace le PATH par secure_path (/usr/sbin:/usr/bin…), qui ne
# contient pas ~/.local/bin où pipx installe gext : le PATH est donc
# reconstruit explicitement via env, sans quoi gext reste introuvable.
run_as_gnome_user() {
    local user uid home
    user="$(gnome_user)" || return 1
    uid="$(id -u "$user")"
    home="$(getent passwd "$user" | cut -d: -f6)"
    sudo -u "$user" env \
        HOME="$home" \
        PATH="${home}/.local/bin:/usr/local/bin:/usr/bin:/bin" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
        XDG_RUNTIME_DIR="/run/user/${uid}" \
        "$@"
}

# Vrai si la commande gext est disponible pour l'utilisateur cible
# (« command » est une primitive du shell : sudo ne peut pas l'exécuter seule).
gext_installed() {
    run_as_gnome_user sh -c 'command -v gext' &> /dev/null
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
            # --filesystem est une option globale de gext : elle doit précéder
            # la sous-commande (« gext install --filesystem » est refusé).
            run "Installation extension GNOME $uuid" \
                run_as_gnome_user gext --filesystem install "$uuid"
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

    local list_file
    list_file="$(resolve_list "$GNOME_EXT_LIST")"
    if [[ -z "$list_file" ]]; then
        info "Aucun fichier $GNOME_EXT_LIST : étape ignorée."
        return
    fi
    if [[ "$list_file" != "$GNOME_EXT_LIST" ]]; then
        info "${C_BLUE}simulé${C_RESET} : lecture de $(basename "$list_file")"
    fi

    # stderr laissé visible : c'est l'erreur à laquelle renvoie le message.
    if ! gnome_user > /dev/null; then
        info "Étape ignorée (voir erreur ci-dessus)."
        return
    fi

    setup_gnome_extensions_cli
    process_gnome_extensions "$list_file"
}

#===============================================================================
# NETTOYAGE & MAINTENANCE (--clean)
#
# Récupère de l'espace disque et borne ce qui grossit sans limite sur une
# installation Fedora utilisée au quotidien :
#   - paquets orphelins (dnf autoremove) et cache DNF (souvent ~1 Go)
#   - journal systemd (par défaut plafonné à 10 % de /var, soit plusieurs Go)
#   - anciens noyaux au-delà de installonly_limit
#   - runtimes Flatpak inutilisés
#   - propres journaux du script, qui n'avaient aucune rotation
#   - TRIM du SSD
#
# N'est jamais exécuté automatiquement : uniquement via l'option --clean.
#===============================================================================

# Taille maximale conservée pour le journal systemd (persistant).
readonly JOURNAL_MAX_SIZE="200M"
readonly JOURNALD_CONF="/etc/systemd/journald.conf.d/99-fedora-setup.conf"

# Nombre de journaux du script à conserver (les plus récents).
readonly SETUP_LOG_KEEP=10

# Paquets orphelins + cache DNF. « dnf clean packages » ne supprime que les
# .rpm téléchargés, pas les métadonnées : le prochain dnf reste rapide.
clean_dnf() {
    run "Suppression des paquets orphelins" dnf autoremove -y
    run "Purge du cache des paquets DNF" dnf clean packages
}

# Borne durablement le journal systemd. On écrit dans un drop-in plutôt que
# dans journald.conf pour ne pas entrer en conflit avec le paquet systemd.
clean_journal() {
    local before
    before="$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.,]+[KMG]' | tail -1)"
    info "Journal systemd avant nettoyage : ${before:-inconnu}"

    run "Réduction du journal à ${JOURNAL_MAX_SIZE}" \
        journalctl --vacuum-size="$JOURNAL_MAX_SIZE"

    if [[ ! -f "$JOURNALD_CONF" ]]; then
        # La création du dossier passe par run() : en simulation, rien ne
        # doit être écrit sur le disque.
        run "Plafonnement permanent du journal (SystemMaxUse=${JOURNAL_MAX_SIZE})" \
            bash -c "install -d '$(dirname "$JOURNALD_CONF")' && printf '[Journal]\nSystemMaxUse=%s\n' '$JOURNAL_MAX_SIZE' > '$JOURNALD_CONF'"
    else
        info "Plafond du journal déjà configuré ($JOURNALD_CONF)"
    fi
}

# Supprime les noyaux excédentaires. dnf respecte installonly_limit lors des
# mises à jour, mais les noyaux déjà accumulés avant ne sont pas retirés
# rétroactivement : « dnf remove --oldinstallonly » s'en charge.
clean_kernels() {
    local installed
    installed=$(rpm -q kernel-core | wc -l)
    info "Noyaux installés : ${installed}"

    if [[ "$installed" -le 2 ]]; then
        info "Rien à purger (limite de 2 noyaux déjà respectée)"
        return 0
    fi

    run "Suppression des anciens noyaux" \
        dnf remove -y --oldinstallonly --setopt=installonly_limit=2
}

# Runtimes Flatpak devenus inutiles (souvent plusieurs centaines de Mo).
clean_flatpak() {
    if ! has_cmd flatpak; then
        info "Flatpak non installé : étape ignorée."
        return 0
    fi
    run "Suppression des runtimes Flatpak inutilisés" \
        flatpak uninstall --unused --noninteractive -y
}

# Rotation des journaux du script lui-même : un fichier est créé à chaque
# exécution dans /var/log et rien ne les supprimait jusqu'ici.
clean_setup_logs() {
    local logs count
    # Le log de l'exécution courante est exclu : il est encore en écriture.
    # tail -n +N démarre à la ligne N incluse : pour conserver les
    # SETUP_LOG_KEEP plus récents, la purge commence donc à N+1.
    mapfile -t logs < <(find /var/log -maxdepth 1 -name 'fedora-setup_*.log' \
        ! -samefile "$LOG_FILE" -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | tail -n "+$((SETUP_LOG_KEEP + 1))" | cut -d' ' -f2-)

    count=${#logs[@]}
    if [[ $count -eq 0 ]]; then
        info "Journaux du script : rien à purger (max ${SETUP_LOG_KEEP} conservés)"
        return 0
    fi

    run "Suppression de ${count} ancien(s) journal(aux) du script" \
        rm -f "${logs[@]}"
}

# TRIM : indispensable pour préserver les performances d'un SSD dans la durée.
# fstrim.timer le fait déjà chaque semaine ; on vérifie qu'il est actif.
clean_trim() {
    if ! systemctl is-enabled --quiet fstrim.timer 2>/dev/null; then
        run "Activation du TRIM hebdomadaire (fstrim.timer)" \
            systemctl enable --now fstrim.timer
    else
        info "TRIM hebdomadaire déjà actif (fstrim.timer)"
    fi

    run "TRIM immédiat de tous les systèmes de fichiers" fstrim -av
}

clean_system() {
    require_root_for "--clean" "nettoyage & maintenance"

    local free_before free_after
    free_before=$(df --output=avail -BM / | tail -1 | tr -d ' M')

    section "Paquets et cache DNF"
    clean_dnf

    section "Journal systemd"
    clean_journal

    section "Anciens noyaux"
    clean_kernels

    section "Runtimes Flatpak"
    clean_flatpak

    section "Journaux de ${CMD_NAME}"
    clean_setup_logs

    section "TRIM du SSD"
    clean_trim

    section "Bilan"
    free_after=$(df --output=avail -BM / | tail -1 | tr -d ' M')
    info "Espace libre sur / : ${free_before} Mo -> ${C_GREEN}${free_after} Mo${C_RESET}"
    info "Récupéré : ${C_GREEN}$(( free_after - free_before )) Mo${C_RESET}"
}

#===============================================================================
# RÉACTIVITÉ MÉMOIRE (--memory)
#
# Fedora active zram par défaut (swap compressé en RAM), mais conserve les
# valeurs sysctl pensées pour un swap sur disque. Or les deux n'ont rien à
# voir : swapper vers zram coûte un cycle CPU de compression, pas une
# entrée-sortie disque. Avec les réglages par défaut, le noyau évite un swap
# devenu bon marché et préfère jeter du cache de pages, ce qui dégrade la
# réactivité au lieu de l'améliorer.
#
# Réglages appliqués (drop-in sysctl, jamais /etc/sysctl.conf) :
#   vm.swappiness=180        valeur recommandée avec zram (défaut 60, max 200)
#   vm.vfs_cache_pressure=50 conserve plus longtemps les métadonnées de
#                            fichiers (inodes/dentries) : navigation plus vive
#   vm.dirty_bytes           borne les écritures en attente pour éviter les
#   vm.dirty_background_bytes  à-coups d'E/S lors des grosses copies
#   vm.page-cluster=0        zram lit page par page : la lecture anticipée
#                            par grappes de 8 pages n'apporte rien ici
#
# N'est jamais exécuté automatiquement : uniquement via l'option --memory.
#===============================================================================

readonly SYSCTL_CONF="/etc/sysctl.d/99-fedora-setup-memory.conf"

# Vrai si un périphérique zram est actif comme swap.
zram_active() {
    swapon --show=NAME --noheadings 2>/dev/null | grep -q '^/dev/zram'
}

# Écrit le drop-in sysctl et l'applique immédiatement (sans redémarrage).
memory_apply_sysctl() {
    if [[ -f "$SYSCTL_CONF" ]]; then
        info "Réglages déjà présents ($SYSCTL_CONF)"
        info "Supprimez ce fichier pour les régénérer."
        return 0
    fi

    # dirty_bytes remplace dirty_ratio (exprimé en % de la RAM) : sur une
    # machine bien dotée, 20 % de RAM en écritures sales représente plusieurs
    # gigaoctets vidés d'un coup sur le disque, d'où des gels perceptibles.
    run "Écriture des réglages mémoire ($SYSCTL_CONF)" \
        bash -c "cat > '$SYSCTL_CONF' <<'SYSCTL'
# Généré par fedora-setup --memory
# Réactivité mémoire adaptée à un swap zram (compressé, en RAM).

# Swapper vers zram est peu coûteux : on le privilégie au lieu de sacrifier
# le cache de pages (60 = valeur pensée pour un swap sur disque).
vm.swappiness=180

# Garder plus longtemps inodes et dentries en cache.
vm.vfs_cache_pressure=50

# Borner les écritures en attente : évite les à-coups sur grosses copies.
vm.dirty_bytes=268435456
vm.dirty_background_bytes=67108864

# zram se lit page par page : pas de lecture anticipée par grappes.
vm.page-cluster=0
SYSCTL"

    run "Application immédiate des réglages" sysctl -q -p "$SYSCTL_CONF"
}

# systemd-oomd tue proprement le processus fautif avant que la machine ne se
# fige. Sans lui, une saturation mémoire rend le bureau inutilisable pendant
# de longues minutes (thrashing) au lieu de perdre une seule application.
memory_check_oomd() {
    if systemctl is-active --quiet systemd-oomd; then
        info "systemd-oomd actif (protection contre les gels mémoire)"
        return 0
    fi

    info "${C_YELLOW}systemd-oomd est inactif : en cas de saturation mémoire,${C_RESET}"
    info "${C_YELLOW}le bureau peut se figer durablement.${C_RESET}"

    if ask_yes_no "Activer systemd-oomd ?"; then
        run "Activation de systemd-oomd" systemctl enable --now systemd-oomd
    else
        info "systemd-oomd laissé inactif."
    fi
}

optimize_memory() {
    require_root_for "--memory" "réactivité mémoire"

    section "État actuel"
    local ram_total swappiness_now
    ram_total="$(free -h | awk '/^Mem:/ {print $2}')"
    swappiness_now="$(cat /proc/sys/vm/swappiness)"
    info "RAM totale       : ${ram_total}"
    info "vm.swappiness    : ${swappiness_now}"

    if zram_active; then
        local zram_size
        zram_size="$(swapon --show=NAME,SIZE --noheadings | awk '/zram/ {print $2}')"
        info "Swap zram        : ${C_GREEN}actif${C_RESET} (${zram_size})"
    else
        info "Swap zram        : ${C_YELLOW}inactif${C_RESET}"
        info "${C_YELLOW}Les réglages ci-dessous visent un swap zram. Sans zram,${C_RESET}"
        info "${C_YELLOW}un swappiness élevé solliciterait fortement le disque.${C_RESET}"
        if ! ask_yes_no "Appliquer quand même les réglages ?"; then
            info "Optimisation mémoire annulée."
            return 0
        fi
    fi

    section "Réglages du noyau"
    memory_apply_sysctl

    section "Protection contre les saturations mémoire"
    memory_check_oomd

    section "Bilan"
    info "vm.swappiness    : ${swappiness_now} -> ${C_GREEN}$(cat /proc/sys/vm/swappiness)${C_RESET}"
    info "Réglages persistants dans ${SYSCTL_CONF}"
}

#===============================================================================
#===============================================================================
# DÉMARRAGE (--boot)
#
# Analyse le temps de démarrage et propose de désactiver les services qui le
# ralentissent sans contrepartie. Chaque désactivation est demandée
# individuellement et n'est proposée que si le matériel ou l'usage réel le
# permet : une imprimante configurée empêche de proposer cups, une puce
# Bluetooth présente empêche de proposer bluetooth. On ne masque jamais un
# service dont dépend l'usage courant de la machine.
#
# Les services sont « disabled », pas « masked » : un simple
# « systemctl enable » suffit à revenir en arrière.
#
# N'est jamais exécuté automatiquement : uniquement via l'option --boot.
#===============================================================================

# Propose de désactiver un service, en expliquant ce qu'on y gagne et perd.
#   $1 : nom de l'unité
#   $2 : ce que la désactivation implique (affiché à l'utilisateur)
boot_offer_disable() {
    local unit="$1" consequence="$2"

    if ! systemctl is-enabled --quiet "$unit" 2>/dev/null; then
        info "${unit} : déjà désactivé"
        return 0
    fi

    info "${C_YELLOW}${unit}${C_RESET} — ${consequence}"
    if ask_yes_no "Désactiver ${unit} ?"; then
        run "Désactivation de ${unit}" systemctl disable "$unit"
        info "Réactivation possible : ${C_YELLOW}sudo systemctl enable ${unit}${C_RESET}"
    else
        info "${unit} conservé."
    fi
}

# NetworkManager-wait-online retarde graphical.target jusqu'à ce que le
# réseau soit joignable. Utile sur un serveur dont les services montent des
# partages réseau au démarrage, inutile sur un poste de bureau où les
# applications gèrent elles-mêmes l'absence de réseau.
boot_network_wait() {
    local delay
    delay="$(systemd-analyze blame 2>/dev/null \
        | awk '/NetworkManager-wait-online/ {print $1; exit}')"

    if [[ -z "$delay" ]]; then
        info "NetworkManager-wait-online : non mesuré (déjà désactivé ?)"
        return 0
    fi

    boot_offer_disable "NetworkManager-wait-online.service" \
        "retarde le démarrage de ${C_BOLD}${delay}${C_RESET} en attendant le réseau ; inutile sur un poste de bureau"
}

# cups n'est proposé à la désactivation que si AUCUNE imprimante n'est
# configurée : sur une machine qui imprime, le désactiver casse l'impression.
boot_cups() {
    if ! pkg_installed cups; then
        return 0
    fi

    local printers
    printers="$(lpstat -p 2>/dev/null | grep -c '^printer' || true)"

    if [[ "${printers:-0}" -gt 0 ]]; then
        info "cups : ${printers} imprimante(s) configurée(s) — conservé"
        return 0
    fi

    boot_offer_disable "cups.service" \
        "service d'impression, aucune imprimante configurée sur cette machine"
}

# bluetooth n'est proposé que si la machine n'a aucun contrôleur Bluetooth.
boot_bluetooth() {
    if ! pkg_installed bluez; then
        return 0
    fi

    # rfkill liste les contrôleurs réellement présents (intégrés ou USB).
    if rfkill list bluetooth 2>/dev/null | grep -q .; then
        info "bluetooth : contrôleur présent — conservé"
        return 0
    fi

    boot_offer_disable "bluetooth.service" \
        "aucun contrôleur Bluetooth détecté sur cette machine"
}

# Le menu GRUB attend par défaut avant de démarrer. Sur une machine à système
# unique, ce délai est du temps perdu à chaque allumage. On descend à 1 s
# plutôt que 0 : à 0 le menu devient inatteignable, ce qui complique
# sérieusement le démarrage sur un noyau antérieur en cas de problème.
boot_grub_timeout() {
    local grub_default="/etc/default/grub"
    local current

    if [[ ! -f "$grub_default" ]]; then
        info "Fichier $grub_default introuvable : étape ignorée."
        return 0
    fi

    current="$(grep -oP '^GRUB_TIMEOUT=\K.*' "$grub_default" 2>/dev/null || echo "?")"
    info "Délai actuel du menu GRUB : ${current}s"

    if [[ "$current" == "1" || "$current" == "0" ]]; then
        info "Délai déjà minimal — inchangé"
        return 0
    fi

    if ! ask_yes_no "Réduire le délai du menu GRUB à 1 seconde ?"; then
        info "Délai GRUB inchangé."
        return 0
    fi

    run "Sauvegarde de ${grub_default}.bak" cp -p "$grub_default" "${grub_default}.bak"
    run "Passage de GRUB_TIMEOUT à 1" \
        sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/' "$grub_default"

    # grub2-mkconfig régénère la configuration effective à partir du fichier
    # ci-dessus. Depuis Fedora 34, grub.cfg est dans /boot/grub2 même en UEFI
    # (/boot/efi/EFI/fedora/grub.cfg n'est plus qu'un fichier de redirection).
    local grub_cfg="/boot/grub2/grub.cfg"
    if [[ ! -f "$grub_cfg" ]]; then
        info "${C_YELLOW}grub.cfg introuvable ($grub_cfg) : régénération ignorée.${C_RESET}"
        info "${C_YELLOW}GRUB_TIMEOUT est modifié, appliquez-le manuellement si besoin.${C_RESET}"
        return 0
    fi

    run "Régénération de la configuration GRUB" grub2-mkconfig -o "$grub_cfg"
}

optimize_boot() {
    require_root_for "--boot" "optimisation du démarrage"

    section "Temps de démarrage actuel"
    local total
    total="$(systemd-analyze 2>/dev/null | head -1)"
    info "${total:-mesure indisponible}"

    section "Services les plus lents"
    # Les unités .device et .mount reflètent la détection matérielle, pas des
    # services désactivables : on ne montre que ce sur quoi on peut agir.
    local slow
    slow="$(systemd-analyze blame 2>/dev/null \
        | grep -E '\.service$' | grep -v 'akmods' | head -8)"
    if [[ -n "$slow" ]]; then
        while IFS= read -r line; do
            info "  ${line}"
        done <<< "$slow"
    else
        info "Mesure indisponible."
    fi

    section "Services ralentissant le démarrage"
    boot_network_wait
    boot_cups
    boot_bluetooth

    section "Menu de démarrage (GRUB)"
    boot_grub_timeout

    section "Bilan"
    info "Les gains seront visibles au ${C_BOLD}prochain démarrage${C_RESET}."
    info "Comparer ensuite avec : ${C_YELLOW}systemd-analyze${C_RESET}"
}

#===============================================================================
#===============================================================================
# PORTABLE / BATTERIE (--laptop)
#
# Optimisations d'autonomie réservées aux machines sur batterie. Sur un poste
# fixe elles n'apportent rien et peuvent brider les performances : le script
# détecte donc la présence d'une batterie et refuse de s'exécuter sans elle
# (sauf confirmation explicite).
#
# TLP vs power-profiles-daemon : les deux pilotent les mêmes réglages du
# noyau et se contredisent s'ils tournent ensemble. Fedora installe PPD par
# défaut (intégré au sélecteur de profil de GNOME) ; TLP est plus agressif et
# plus configurable, mais son installation impose de neutraliser PPD. Le
# script explique le compromis et laisse le choix, sans jamais installer les
# deux.
#
# N'est jamais exécuté automatiquement : uniquement via l'option --laptop.
#===============================================================================

# Vrai si la machine possède une batterie (donc : portable).
has_battery() {
    local bat
    for bat in /sys/class/power_supply/BAT*; do
        [[ -e "$bat" ]] && return 0
    done
    return 1
}

# Vrai si le processeur est un Intel (thermald ne concerne qu'eux).
cpu_is_intel() {
    grep -qi 'GenuineIntel' /proc/cpuinfo
}

# Installe TLP en neutralisant power-profiles-daemon, ou conserve PPD.
# Les deux services pilotent les mêmes registres : les faire cohabiter
# produit des réglages incohérents et des retours en arrière permanents.
#
# Depuis Fedora 41, le sélecteur de profil de GNOME est fourni par tuned-ppd
# (tuned + une couche compatible power-profiles-daemon) et non plus par
# power-profiles-daemon. Le paquet tlp déclare un conflit avec tuned : son
# installation exige alors --allowerasing, qui retire tuned et tuned-ppd.
laptop_power_manager() {
    local ppd_pkg="" tlp_installed=1
    if pkg_installed tuned-ppd; then
        ppd_pkg="tuned-ppd"
    elif pkg_installed power-profiles-daemon; then
        ppd_pkg="power-profiles-daemon"
    fi
    pkg_installed tlp || tlp_installed=0

    if [[ $tlp_installed -eq 1 ]]; then
        info "TLP est déjà installé"
        # tuned-ppd ne peut pas cohabiter avec TLP (conflit de paquets) :
        # seul power-profiles-daemon peut subsister à côté.
        if [[ "$ppd_pkg" == "power-profiles-daemon" ]]; then
            info "${C_YELLOW}power-profiles-daemon est également présent :${C_RESET}"
            info "${C_YELLOW}les deux se contredisent, il faut en neutraliser un.${C_RESET}"
            if ask_yes_no "Masquer power-profiles-daemon au profit de TLP ?"; then
                run "Masquage de power-profiles-daemon" \
                    systemctl mask --now power-profiles-daemon
            fi
        fi
        run "Activation de TLP" systemctl enable --now tlp
        return 0
    fi

    info "Gestionnaire d'énergie :"
    info "  ${C_BOLD}power-profiles-daemon${C_RESET} — intégré à GNOME (sélecteur de"
    info "     profil dans le menu système), réglages prudents, aucun paramétrage."
    info "  ${C_BOLD}TLP${C_RESET} — plus agressif sur l'autonomie, largement configurable,"
    info "     mais remplace le sélecteur de profil de GNOME."

    if [[ -n "$ppd_pkg" ]]; then
        info "Actuellement : ${C_GREEN}${ppd_pkg}${C_RESET}"
    else
        info "Actuellement : ${C_YELLOW}aucun gestionnaire installé${C_RESET}"
    fi

    if ! ask_yes_no "Installer TLP à la place ?"; then
        if [[ -z "$ppd_pkg" ]]; then
            # Paquet fourni par Fedora pour le sélecteur de profil de GNOME
            local default_ppd="power-profiles-daemon"
            local default_units=(power-profiles-daemon)
            if [[ $(rpm -E %fedora) -ge 41 ]]; then
                default_ppd="tuned-ppd"
                default_units=(tuned tuned-ppd)
            fi
            if ask_yes_no "Installer ${default_ppd} ?"; then
                run "Installation de ${default_ppd}" \
                    dnf install -y "$default_ppd"
                run "Activation de ${default_ppd}" \
                    systemctl enable --now "${default_units[@]}"
            fi
        else
            info "${ppd_pkg} conservé."
        fi
        return 0
    fi

    # tlp-rdw gère la radio (Wi-Fi/Bluetooth) selon la connexion filaire.
    if [[ "$ppd_pkg" == "tuned-ppd" ]]; then
        info "${C_YELLOW}TLP est incompatible avec tuned : tuned et tuned-ppd seront retirés.${C_RESET}"
        run "Installation de TLP (remplace tuned)" \
            dnf install -y --allowerasing tlp tlp-rdw
    else
        run "Installation de TLP" dnf install -y tlp tlp-rdw
    fi

    if [[ "$ppd_pkg" == "power-profiles-daemon" ]]; then
        run "Masquage de power-profiles-daemon (conflit avec TLP)" \
            systemctl mask --now power-profiles-daemon
    fi

    run "Activation de TLP" systemctl enable --now tlp
    info "Configuration : ${C_YELLOW}/etc/tlp.conf${C_RESET} — état : ${C_YELLOW}sudo tlp-stat -s${C_RESET}"
}

# thermald pilote la gestion thermique des processeurs Intel. Sans lui, le
# noyau ne réagit qu'aux seuils matériels, plus brutaux (throttling tardif).
laptop_thermald() {
    if ! cpu_is_intel; then
        info "Processeur non-Intel : thermald sans objet."
        return 0
    fi

    if ! pkg_installed thermald; then
        if ! ask_yes_no "Installer thermald (gestion thermique Intel) ?"; then
            info "thermald ignoré."
            return 0
        fi
        run "Installation de thermald" dnf install -y thermald
    fi

    if systemctl is-active --quiet thermald; then
        info "thermald actif"
    else
        run "Activation de thermald" systemctl enable --now thermald
    fi
}

# powertop --auto-tune applique les réglages d'économie recommandés. Ils sont
# perdus au redémarrage : on propose une unité systemd pour les réappliquer.
# Attention : l'auto-tune active l'économie d'énergie sur les ports USB, ce
# qui peut faire « décrocher » certains périphériques (souris, claviers,
# webcams). D'où le caractère explicitement optionnel et réversible.
readonly POWERTOP_UNIT="/etc/systemd/system/powertop-autotune.service"

laptop_powertop() {
    if ! pkg_installed powertop; then
        if ! ask_yes_no "Installer powertop (analyse et réglages d'économie) ?"; then
            info "powertop ignoré."
            return 0
        fi
        run "Installation de powertop" dnf install -y powertop
    fi

    if [[ -f "$POWERTOP_UNIT" ]]; then
        info "Unité powertop-autotune déjà en place"
        return 0
    fi

    info "${C_YELLOW}L'auto-tune active l'économie d'énergie sur les ports USB :${C_RESET}"
    info "${C_YELLOW}certaines souris ou webcams peuvent se déconnecter par moments.${C_RESET}"

    if ! ask_yes_no "Appliquer powertop --auto-tune à chaque démarrage ?"; then
        info "Auto-tune non configuré (powertop reste utilisable manuellement)."
        return 0
    fi

    # Chemin résolu depuis le paquet plutôt que codé en dur : systemd exige un
    # ExecStart absolu et refuse de démarrer l'unité si le chemin est faux.
    local powertop_bin
    powertop_bin="$(command -v powertop || rpm -ql powertop | grep -m1 'bin/powertop$')"
    if [[ -z "$powertop_bin" ]]; then
        error "Binaire powertop introuvable : unité non créée."
        return 1
    fi

    run "Création de l'unité powertop-autotune" \
        bash -c "cat > '$POWERTOP_UNIT' <<UNIT
[Unit]
Description=Réglages d'économie d'énergie powertop (fedora-setup)
After=multi-user.target

[Service]
Type=oneshot
ExecStart=${powertop_bin} --auto-tune
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT"

    run "Activation de powertop-autotune" \
        systemctl enable --now powertop-autotune.service
    info "Pour annuler : ${C_YELLOW}sudo systemctl disable --now powertop-autotune${C_RESET}"
    info "puis supprimer ${POWERTOP_UNIT}"
}

optimize_laptop() {
    require_root_for "--laptop" "portable & autonomie"

    section "Détection du matériel"
    if has_battery; then
        local bat_state
        bat_state="$(cat /sys/class/power_supply/BAT*/capacity 2>/dev/null | head -1)"
        info "Batterie détectée (charge : ${bat_state:-?} %)"
    else
        info "${C_YELLOW}Aucune batterie détectée : cette machine semble être un poste fixe.${C_RESET}"
        info "${C_YELLOW}Ces réglages visent l'autonomie et peuvent brider les performances.${C_RESET}"
        if ! ask_yes_no "Continuer quand même ?"; then
            info "Optimisation portable annulée."
            return 0
        fi
    fi
    info "Processeur : $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)"

    section "Gestionnaire d'énergie"
    laptop_power_manager

    section "Gestion thermique"
    laptop_thermald

    section "Réglages d'économie (powertop)"
    laptop_powertop

    section "Bilan"
    info "Autonomie estimée et détail des réglages : ${C_YELLOW}sudo powertop${C_RESET}"
    if pkg_installed tlp; then
        info "État de TLP : ${C_YELLOW}sudo tlp-stat -s${C_RESET}"
    fi
}

#===============================================================================
#===============================================================================
# SÉCURITÉ / RÉSEAU (--security)
#
# Vérifie et renforce les protections de base d'une installation Fedora.
# L'esprit de cette section est de constater puis proposer : rien n'est
# durci de force, car un pare-feu trop strict ou un résolveur DNS mal choisi
# casse la connectivité de façon difficile à diagnostiquer.
#
# Les mises à jour automatiques sont volontairement configurées en mode
# « téléchargement + notification » et non en installation automatique :
# installer des paquets sans surveillance sur un poste de travail peut
# interrompre une session (services redémarrés, modules noyau remplacés).
#
# N'est jamais exécuté automatiquement : uniquement via l'option --security.
#===============================================================================

# SELinux est une protection majeure de Fedora, souvent désactivée à tort en
# suivant des tutoriels. On se contente de signaler : le réactiver à chaud
# sur un système ayant tourné en permissive exige un réétiquetage complet.
security_selinux() {
    if ! has_cmd getenforce; then
        info "SELinux : outils absents, état indéterminé."
        return 0
    fi

    local state
    state="$(getenforce 2>/dev/null)"

    case "$state" in
        Enforcing)
            info "SELinux : ${C_GREEN}Enforcing${C_RESET} (protection active)"
            ;;
        Permissive)
            info "SELinux : ${C_YELLOW}Permissive${C_RESET} — les violations sont"
            info "journalisées mais autorisées."
            info "Pour réactiver : ${C_YELLOW}sudo setenforce 1${C_RESET} puis passer"
            info "SELINUX=enforcing dans /etc/selinux/config"
            ;;
        Disabled)
            info "SELinux : ${C_RED}Disabled${C_RESET}"
            info "${C_YELLOW}Le réactiver impose un réétiquetage complet du disque${C_RESET}"
            info "${C_YELLOW}(sudo fixfiles -F onboot puis redémarrage) : à faire${C_RESET}"
            info "${C_YELLOW}en connaissance de cause, hors de ce script.${C_RESET}"
            ;;
        *)
            info "SELinux : état indéterminé (${state:-?})"
            ;;
    esac
}

# firewalld est actif par défaut sur Fedora ; on vérifie qu'il l'est bien et
# on affiche la zone appliquée, sans la modifier : la zone conditionne les
# services joignables et un changement peut couper un partage en cours.
security_firewall() {
    if ! pkg_installed firewalld; then
        info "firewalld n'est pas installé."
        if ask_yes_no "Installer et activer firewalld ?"; then
            run "Installation de firewalld" dnf install -y firewalld
            run "Activation de firewalld" systemctl enable --now firewalld
        fi
        return 0
    fi

    if ! systemctl is-active --quiet firewalld; then
        info "${C_YELLOW}firewalld est installé mais inactif.${C_RESET}"
        if ask_yes_no "Activer firewalld ?"; then
            run "Activation de firewalld" systemctl enable --now firewalld
        fi
        return 0
    fi

    local zone
    zone="$(firewall-cmd --get-default-zone 2>/dev/null)"
    info "firewalld : ${C_GREEN}actif${C_RESET} (zone « ${zone:-?} »)"

    # FedoraWorkstation ouvre par défaut les ports hauts 1025-65535 en UDP
    # pour faciliter le partage et la découverte réseau. C'est un compromis
    # d'ergonomie discutable sur un réseau non maîtrisé (Wi-Fi public).
    if [[ "$zone" == "FedoraWorkstation" ]]; then
        info "${C_YELLOW}Cette zone laisse ouverts les ports UDP 1025-65535${C_RESET}"
        info "${C_YELLOW}(partage de fichiers, découverte réseau). Sur un réseau${C_RESET}"
        info "${C_YELLOW}public, la zone « public » est nettement plus stricte.${C_RESET}"
        info "Services ouverts : ${C_YELLOW}firewall-cmd --list-all${C_RESET}"
        info "Pour durcir : ${C_YELLOW}sudo firewall-cmd --set-default-zone=public${C_RESET}"
    fi
}

# Mises à jour automatiques en mode « télécharger et prévenir ». Le paquet
# diffère selon la génération de DNF : dnf5-plugin-automatic sur dnf5,
# dnf-automatic sur dnf4.
security_auto_updates() {
    # Le nom du paquet, du minuteur et du fichier de configuration diffèrent
    # selon la génération de DNF. Le paquet dnf5 fournit les deux minuteurs
    # (dnf-automatic.timer et dnf5-automatic.timer) : c'est dnf5-automatic
    # qu'il faut activer, et sa configuration effective est dans
    # /etc/dnf/dnf5-plugins/automatic.conf, pas /etc/dnf/automatic.conf.
    local pkg="dnf-automatic" timer="dnf-automatic.timer"
    local conf="/etc/dnf/automatic.conf"

    if dnf --version 2>/dev/null | grep -q '^dnf5'; then
        pkg="dnf5-plugin-automatic"
        timer="dnf5-automatic.timer"
        conf="/etc/dnf/dnf5-plugins/automatic.conf"
    fi

    if systemctl is-enabled --quiet dnf-automatic.timer 2>/dev/null \
        || systemctl is-enabled --quiet dnf5-automatic.timer 2>/dev/null; then
        info "Mises à jour automatiques déjà configurées"
        return 0
    fi

    info "Les mises à jour de sécurité peuvent être téléchargées"
    info "automatiquement, avec notification (sans installation silencieuse)."

    if ! ask_yes_no "Activer les mises à jour automatiques (téléchargement seul) ?"; then
        info "Mises à jour automatiques non activées."
        return 0
    fi

    if ! pkg_installed "$pkg"; then
        if ! run "Installation de ${pkg}" dnf install -y "$pkg"; then
            error "Installation de ${pkg} impossible : étape abandonnée."
            return 1
        fi
    fi

    # download_updates=yes / apply_updates=no : on récupère les paquets pour
    # que l'installation manuelle soit immédiate, sans rien appliquer seul.
    if [[ -f "$conf" ]]; then
        run "Sauvegarde de ${conf}.bak" cp -p "$conf" "${conf}.bak"
        run "Configuration : téléchargement sans installation" \
            sed -i -e 's/^upgrade_type\s*=.*/upgrade_type = security/' \
                   -e 's/^download_updates\s*=.*/download_updates = yes/' \
                   -e 's/^apply_updates\s*=.*/apply_updates = no/' "$conf"
    else
        # Avec dnf5, le fichier de /etc n'est pas livré par le paquet (simple
        # surcharge facultative de /usr/share/dnf5/dnf5-plugins/automatic.conf) :
        # on le crée avec les seules valeurs à imposer, le reste étant hérité.
        run "Configuration : téléchargement sans installation (${conf})" \
            bash -c "install -d '$(dirname "$conf")' && cat > '$conf' <<'AUTOMATIC'
# Généré par fedora-setup --security
[commands]
upgrade_type = security
download_updates = yes
apply_updates = no
AUTOMATIC"
    fi

    run "Activation du minuteur ${timer}" systemctl enable --now "$timer"
    info "Mises à jour en attente visibles avec : ${C_YELLOW}dnf check-update${C_RESET}"
}

# DNS chiffré (DNS-over-TLS). Volontairement prudent : si le résolveur
# courant est une adresse privée, il s'agit d'un DNS local (box, réseau
# d'entreprise) qui résout des noms internes. Le remplacer par un résolveur
# public casserait l'accès aux ressources locales.
security_dns() {
    if ! systemctl is-active --quiet systemd-resolved; then
        info "systemd-resolved inactif : configuration DNS laissée telle quelle."
        return 0
    fi

    local current dot_state
    current="$(resolvectl status 2>/dev/null | awk '/Current DNS Server/ {print $NF; exit}')"
    # resolvectl préfixe le protocole d'un + (actif) ou d'un - (inactif) :
    # « +DNSOverTLS » / « -DNSOverTLS », sans valeur après un signe égal.
    dot_state="$(resolvectl status 2>/dev/null | grep -o '[+-]DNSOverTLS' | head -1)"

    info "Résolveur DNS actuel : ${current:-inconnu}"

    if [[ "$dot_state" == "+DNSOverTLS" ]]; then
        info "DNS-over-TLS : ${C_GREEN}déjà actif${C_RESET}"
        return 0
    fi

    # Adresses privées : résolveur local, on n'y touche pas. Outre la
    # RFC 1918, on couvre la boucle locale, l'espace partagé 100.64.0.0/10
    # (VPN de type Tailscale) et les adresses IPv6 locales (fc00::/7, fe80::).
    if [[ "${current,,}" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|127\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|f[cd][0-9a-f]{2}:|fe80:) ]]; then
        info "${C_YELLOW}Ce résolveur est local (adresse privée) : il résout${C_RESET}"
        info "${C_YELLOW}probablement des noms internes à votre réseau.${C_RESET}"
        info "${C_YELLOW}Le remplacer par un résolveur public casserait cet accès :${C_RESET}"
        info "${C_YELLOW}étape ignorée par précaution.${C_RESET}"
        return 0
    fi

    info "Le DNS non chiffré est lisible par tout intermédiaire réseau."
    info "DNS-over-TLS chiffre ces requêtes (résolveur : Quad9, 9.9.9.9)."

    if ! ask_yes_no "Activer DNS-over-TLS via Quad9 ?"; then
        info "Configuration DNS inchangée."
        return 0
    fi

    local conf_dir="/etc/systemd/resolved.conf.d"
    local conf="${conf_dir}/99-fedora-setup-dot.conf"

    # opportunistic plutôt que yes : en mode strict, un portail captif ou un
    # réseau bloquant le port 853 rend toute résolution impossible.
    run "Configuration de DNS-over-TLS" \
        bash -c "install -d '$conf_dir' && cat > '$conf' <<'RESOLVED'
# Généré par fedora-setup --security
[Resolve]
DNS=9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net
DNSOverTLS=opportunistic
RESOLVED"

    run "Redémarrage de systemd-resolved" systemctl restart systemd-resolved
    info "Vérifier avec : ${C_YELLOW}resolvectl status${C_RESET}"
    info "Pour annuler : supprimer ${conf} et redémarrer systemd-resolved"
}

secure_system() {
    require_root_for "--security" "sécurité & réseau"

    section "SELinux"
    security_selinux

    section "Pare-feu"
    security_firewall

    section "Mises à jour automatiques"
    security_auto_updates

    section "Confidentialité DNS"
    security_dns

    section "Bilan"
    info "Aucun réglage n'a été durci sans confirmation."
    info "État du pare-feu : ${C_YELLOW}sudo firewall-cmd --list-all${C_RESET}"
}

#===============================================================================
#===============================================================================
# OUTILS DE DÉVELOPPEMENT (--devtools)
#
# Environnements de développement isolés et polices de caractères. Tout est
# proposé individuellement : ces outils sont volumineux (la virtualisation
# dépasse le gigaoctet) et n'ont d'intérêt que selon l'usage réel.
#
# Distrobox et Toolbox répondent au même besoin — un conteneur jetable où
# installer des dépendances sans polluer le système — mais Toolbox est fourni
# par Fedora et limité aux images Fedora, là où Distrobox accepte n'importe
# quelle distribution (Ubuntu, Arch, Debian…). Les deux peuvent coexister
# sans conflit, contrairement à TLP et power-profiles-daemon.
#
# N'est jamais exécuté automatiquement : uniquement via l'option --devtools.
#===============================================================================

# Conteneurs de développement jetables, intégrés au système hôte
# (le dossier personnel et l'affichage graphique restent accessibles).
devtools_containers() {
    if pkg_installed distrobox; then
        info "distrobox déjà installé"
    else
        info "${C_BOLD}Distrobox${C_RESET} — conteneurs de développement basés sur"
        info "n'importe quelle distribution, avec accès au dossier personnel."
        if pkg_installed toolbox; then
            info "(toolbox est déjà présent : il fait de même, mais uniquement"
            info "avec des images Fedora. Les deux peuvent cohabiter.)"
        fi

        if ask_yes_no "Installer distrobox ?"; then
            # podman est le moteur de conteneurs utilisé par distrobox ;
            # il est déjà présent sur une Workstation, mais pas garanti.
            run "Installation de distrobox" dnf install -y distrobox podman
            info "Créer un conteneur : ${C_YELLOW}distrobox create --name dev --image fedora:latest${C_RESET}"
            info "Y entrer : ${C_YELLOW}distrobox enter dev${C_RESET}"
        else
            info "distrobox ignoré."
        fi
    fi
}

# Virtualisation KVM/QEMU via libvirt. Nécessite un processeur compatible :
# sans VT-x/AMD-V, libvirt se rabat sur une émulation logicielle très lente,
# ce qui rend l'installation inutile en pratique.
devtools_virtualization() {
    local virt_flags
    virt_flags="$(grep -Ec 'vmx|svm' /proc/cpuinfo || true)"

    if [[ "${virt_flags:-0}" -eq 0 ]]; then
        info "${C_YELLOW}Aucune extension de virtualisation (VT-x / AMD-V) détectée.${C_RESET}"
        info "${C_YELLOW}Vérifiez qu'elle est activée dans le BIOS/UEFI. Sans elle,${C_RESET}"
        info "${C_YELLOW}les machines virtuelles seraient émulées et très lentes.${C_RESET}"
        if ! ask_yes_no "Installer quand même la virtualisation ?"; then
            info "Virtualisation ignorée."
            return 0
        fi
    else
        info "Extensions de virtualisation : ${C_GREEN}disponibles${C_RESET}"
    fi

    if pkg_installed libvirt && pkg_installed virt-manager; then
        info "Virtualisation déjà installée"
    else
        info "${C_BOLD}KVM / libvirt${C_RESET} — machines virtuelles natives (~1 Go)."
        if ! ask_yes_no "Installer la virtualisation (KVM, libvirt, virt-manager) ?"; then
            info "Virtualisation ignorée."
            return 0
        fi
        # Le groupe « virtualization » ne rend obligatoire que virt-install :
        # il ne tire ni virt-manager ni qemu-kvm. Les paquets sont donc
        # nommés explicitement pour obtenir un environnement réellement
        # utilisable (moteur, démon, interface graphique, réseau NAT).
        run "Installation de KVM / libvirt / virt-manager" \
            dnf install -y qemu-kvm libvirt libvirt-daemon-config-network \
                virt-install virt-manager
    fi

    run "Activation de libvirtd" systemctl enable --now libvirtd

    # Sans appartenance au groupe libvirt, virt-manager réclame le mot de
    # passe root à chaque lancement.
    local user
    if user="$(gnome_user)"; then
        if id -nG "$user" | grep -qw libvirt; then
            info "L'utilisateur « $user » est déjà dans le groupe libvirt"
        else
            run "Ajout de « $user » au groupe libvirt" usermod -aG libvirt "$user"
            info "${C_YELLOW}Déconnectez-vous / reconnectez-vous pour que ce groupe${C_RESET}"
            info "${C_YELLOW}prenne effet.${C_RESET}"
        fi
    fi
}

# Polices de caractères : rendu des pages web et des documents Office.
# Les polices Microsoft ne sont pas redistribuables par Fedora et doivent
# être récupérées séparément ; on se limite ici aux alternatives libres
# métriquement compatibles, sans dépendance externe ni acceptation d'EULA.
devtools_fonts() {
    info "Polices proposées :"
    info "  - ${C_BOLD}Liberation${C_RESET} : équivalents libres d'Arial, Times, Courier"
    info "  - ${C_BOLD}Google Noto${C_RESET} : couverture Unicode étendue (emoji, CJK)"
    info "  - ${C_BOLD}Fira Code / JetBrains Mono${C_RESET} : polices de programmation"

    if ! ask_yes_no "Installer ces polices ?"; then
        info "Polices ignorées."
        return 0
    fi

    run "Installation des polices Liberation" \
        dnf install -y liberation-fonts-all
    run "Installation des polices Noto (emoji et CJK)" \
        dnf install -y google-noto-emoji-fonts google-noto-sans-cjk-fonts
    run "Installation des polices de programmation" \
        dnf install -y fira-code-fonts jetbrains-mono-fonts

    run "Reconstruction du cache de polices" fc-cache -f
}

install_devtools() {
    require_root_for "--devtools" "outils de développement"

    section "Conteneurs de développement"
    devtools_containers

    section "Virtualisation"
    devtools_virtualization

    section "Polices de caractères"
    devtools_fonts

    section "Bilan"
    info "Chaque outil non installé peut l'être plus tard en relançant"
    info "${C_YELLOW}sudo ${CMD_NAME} --devtools${C_RESET}"
}

#===============================================================================
#===============================================================================
# BASHRC (installation explicite, hors du flux principal)
#
# Installe ~/.bashrc de l'utilisateur cible ($SUDO_USER) depuis le gabarit
# bashrc.example du dépôt, en sauvegardant l'ancien fichier en ~/.bashrc.bak
# s'il diffère. N'est jamais exécuté automatiquement : uniquement via
# l'option --bashrc, appelée explicitement.
#===============================================================================

install_bashrc() {
    require_root_for "--bashrc" "installation de ~/.bashrc"

    local bashrc_example="${SCRIPT_DIR}/bashrc.example"

    if [[ ! -f "$bashrc_example" ]]; then
        error "Gabarit introuvable : $bashrc_example"
        exit 1
    fi

    local user home_dir dest
    user="$(gnome_user)" || exit 1
    home_dir="$(getent passwd "$user" | cut -d: -f6)"
    dest="${home_dir}/.bashrc"

    section "Installation de ~/.bashrc pour ${user}"

    if [[ -f "$dest" ]] && ! cmp -s "$bashrc_example" "$dest"; then
        run "Sauvegarde de l'ancien .bashrc (${dest}.bak)" \
            cp -p "$dest" "${dest}.bak"
    fi

    run "Installation de ${dest}" \
        install -m 644 -o "$user" -g "$user" "$bashrc_example" "$dest"
}

#===============================================================================
# DOCKER (installation explicite, hors du flux principal)
#
# Fedora fournit « moby-engine » dans ses dépôts, mais la version officielle
# Docker CE (dépôt download.docker.com) est celle que documente Docker et la
# seule à fournir buildx et compose v2 en plugins. C'est donc elle qu'on
# installe ici, après avoir retiré les paquets Fedora concurrents qui entrent
# en conflit sur les mêmes fichiers.
#
# N'est jamais exécuté automatiquement : uniquement via l'option --docker,
# comme --bashrc.
#===============================================================================

readonly DOCKER_REPO_URL="https://download.docker.com/linux/fedora/docker-ce.repo"
readonly DOCKER_REPO_FILE="/etc/yum.repos.d/docker-ce.repo"

# Paquets Fedora en conflit avec Docker CE : ils fournissent les mêmes
# binaires (/usr/bin/docker, containerd) et bloqueraient l'installation.
readonly DOCKER_CONFLICTS=(docker docker-client docker-client-latest \
    docker-common docker-latest docker-latest-logrotate docker-logrotate \
    docker-selinux docker-engine-selinux docker-engine moby-engine)

# Paquets Docker CE à installer (moteur + CLI + runtime + plugins officiels)
readonly DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin)

# Ajoute le dépôt officiel Docker CE (idempotent : ne retélécharge pas le
# .repo s'il est déjà en place).
docker_setup_repo() {
    if [[ -f "$DOCKER_REPO_FILE" ]]; then
        info "Dépôt Docker CE déjà présent ($DOCKER_REPO_FILE)"
        return 0
    fi
    run "Ajout du dépôt Docker CE" \
        curl -fsSL -o "$DOCKER_REPO_FILE" "$DOCKER_REPO_URL"
}

# Retire les paquets Fedora qui entrent en conflit avec Docker CE.
docker_remove_conflicts() {
    local p conflicts=()
    for p in "${DOCKER_CONFLICTS[@]}"; do
        pkg_installed "$p" && conflicts+=("$p")
    done

    if [[ ${#conflicts[@]} -eq 0 ]]; then
        return 0
    fi

    info "Paquets en conflit détectés : ${conflicts[*]}"
    run "Suppression des paquets en conflit" dnf remove -y "${conflicts[@]}"
}

# Ajoute l'utilisateur réel ($SUDO_USER) au groupe docker, ce qui permet
# d'utiliser docker sans sudo. Le groupe est créé par le paquet docker-ce.
docker_add_user_to_group() {
    local user
    user="$(gnome_user)" || {
        info "Utilisateur cible inconnu : ajout au groupe docker ignoré."
        return 0
    }

    if id -nG "$user" | grep -qw docker; then
        info "L'utilisateur « $user » est déjà dans le groupe docker"
        return 0
    fi

    run "Ajout de « $user » au groupe docker" usermod -aG docker "$user"

    info "${C_YELLOW}Attention : appartenir au groupe docker équivaut à un accès root${C_RESET}"
    info "${C_YELLOW}(le démon tourne en root et peut monter n'importe quel volume).${C_RESET}"
    info "${C_YELLOW}Déconnectez-vous / reconnectez-vous pour que ce groupe prenne effet.${C_RESET}"
}

# Vérifie l'installation avec l'image de test officielle. Le démon doit
# tourner : on le démarre pour la session courante (sans l'activer au boot,
# ce choix restant à l'utilisateur via « systemctl enable docker »).
docker_verify() {
    if ! systemctl is-active --quiet docker; then
        run "Démarrage du service docker" systemctl start docker
    fi

    if ! run "Test docker run hello-world" docker run --rm hello-world; then
        error "Le test hello-world a échoué (voir $LOG_FILE)."
    elif [[ $DRY_RUN -eq 0 ]]; then
        info "${C_GREEN}Docker fonctionne correctement.${C_RESET}"
    fi
}

install_docker() {
    require_root_for "--docker" "installation de Docker"

    section "Docker CE"
    docker_setup_repo
    docker_remove_conflicts
    run "Installation de Docker CE" dnf install -y "${DOCKER_PACKAGES[@]}"
    docker_add_user_to_group
    docker_verify

    info "Le service n'est pas activé au démarrage. Pour le faire :"
    info "  ${C_YELLOW}sudo systemctl enable --now docker${C_RESET}"
}

#===============================================================================
# MONTÉE DE VERSION FEDORA (--upgrade)
#
# Suit la procédure officielle « dnf system-upgrade » : mise à jour complète
# de la version courante, téléchargement des paquets de la version suivante,
# puis installation hors ligne au redémarrage. On ne monte que d'une version
# à la fois (N -> N+1) : Fedora tolère un saut de deux versions, mais c'est
# le chemin le plus testé, et le seul où les dépôts tiers ont eu le temps de
# suivre.
#
# La version cible n'est proposée qu'une fois publiée en stable : une bêta
# (« 45 Beta » dans releases.json) n'est jamais retenue.
#===============================================================================

readonly FEDORA_RELEASES_URL="https://fedoraproject.org/releases.json"

# Dépôts maintenus par Fedora et RPM Fusion : prêts le jour de la sortie.
# Tous les autres sont des dépôts tiers, souvent en retard de quelques jours.
readonly UPGRADE_CORE_REPOS_RE='^(fedora|updates|rpmfusion-)'

# Numéro de la plus récente version stable de Fedora (vide si inconnu).
# Les entrées bêta (« 45 Beta ») sont écartées par l'expression régulière.
latest_fedora_release() {
    curl -fsS --max-time 10 "$FEDORA_RELEASES_URL" 2>/dev/null \
        | grep -oE '"version": ?"[0-9]+"' | grep -oE '[0-9]+' | sort -n | tail -n1
}

# Identifiants des dépôts tiers activés, un par ligne.
upgrade_third_party_repos() {
    dnf repolist --enabled 2>/dev/null | awk 'NR > 1 { print $1 }' \
        | grep -Ev "$UPGRADE_CORE_REPOS_RE" || true
}

# Vrai si la machine fonctionne sur batterie (aucun secteur branché).
on_battery() {
    local ps
    has_battery || return 1
    for ps in /sys/class/power_supply/*; do
        if [[ "$(cat "$ps/type" 2>/dev/null)" == "Mains" \
            && "$(cat "$ps/online" 2>/dev/null)" == "1" ]]; then
            return 1
        fi
    done
    return 0
}

# Constate tout ce qui peut faire échouer ou ralentir la montée de version,
# avant d'y toucher. Renvoie 1 si l'utilisateur préfère s'arrêter.
upgrade_preflight() {
    local repos
    repos="$(upgrade_third_party_repos)"
    if [[ -n "$repos" ]]; then
        info "Dépôts tiers activés (peuvent ne pas encore publier pour la"
        info "nouvelle version ; le script proposera de les ignorer si besoin) :"
        local r
        while IFS= read -r r; do
            info "  - ${r}"
        done <<< "$repos"
    fi

    if pkg_installed akmod-nvidia; then
        info "${C_YELLOW}Pilote NVIDIA : le module est recompilé au premier démarrage.${C_RESET}"
        info "${C_YELLOW}Si l'écran reste noir ou en basse résolution, patientez${C_RESET}"
        info "${C_YELLOW}quelques minutes puis redémarrez.${C_RESET}"
    fi

    if has_cmd gnome-shell; then
        info "Extensions GNOME : celles qui ne déclarent pas encore la nouvelle"
        info "version de GNOME Shell seront désactivées jusqu'à leur mise à jour."
    fi

    if on_battery; then
        info "${C_YELLOW}La machine est sur batterie. L'installation dure souvent${C_RESET}"
        info "${C_YELLOW}plus de 30 minutes : une coupure en plein milieu peut${C_RESET}"
        info "${C_YELLOW}laisser le système inutilisable. Branchez le secteur.${C_RESET}"
        if ! ask_yes_no "Continuer quand même sur batterie ?"; then
            return 1
        fi
    fi
    return 0
}

# Télécharge les paquets de la version cible. En cas d'échec, propose une
# seconde tentative en ignorant les dépôts tiers, puis en autorisant la
# suppression des paquets bloquants — jamais d'office avec --yes : retirer
# des paquets sans que personne ne lise la liste serait trop brutal.
#   $1 : version cible
upgrade_download() {
    local target="$1"
    local -a extra=()

    if run "Téléchargement des paquets de Fedora ${target}" \
        dnf system-upgrade download -y --releasever="$target"; then
        return 0
    fi

    if [[ $ASSUME_YES -eq 1 ]]; then
        error "Téléchargement impossible : consultez ${LOG_FILE}"
        error "puis relancez sans --yes pour choisir comment contourner le blocage."
        return 1
    fi

    info "${C_YELLOW}Le téléchargement a échoué. Causes habituelles : un dépôt tiers${C_RESET}"
    info "${C_YELLOW}qui ne publie pas encore pour Fedora ${target}, ou un paquet sans${C_RESET}"
    info "${C_YELLOW}équivalent dans la nouvelle version (détail dans le journal).${C_RESET}"

    local repos r
    repos="$(upgrade_third_party_repos)"
    if [[ -n "$repos" ]] \
        && ask_yes_no "Réessayer en ignorant les dépôts tiers (le temps du téléchargement seulement) ?"; then
        while IFS= read -r r; do
            extra+=("--disablerepo=${r}")
        done <<< "$repos"
    fi
    if ask_yes_no "Autoriser la suppression des paquets qui bloquent la mise à niveau (--allowerasing) ?"; then
        extra+=(--allowerasing)
    fi
    if [[ ${#extra[@]} -eq 0 ]]; then
        return 1
    fi

    run "Nouvelle tentative de téléchargement" \
        dnf system-upgrade download -y --releasever="$target" "${extra[@]}"
}

upgrade_fedora() {
    require_root_for "--upgrade" "montée de version Fedora"

    section "Version disponible"
    local current latest target
    current="$(rpm -E %fedora)"
    latest="$(latest_fedora_release)"

    if [[ -z "$latest" ]]; then
        error "Impossible de déterminer la dernière version de Fedora"
        error "(${FEDORA_RELEASES_URL} injoignable ?). Vérifiez la connexion."
        exit 1
    fi

    info "Version installée       : ${C_BOLD}Fedora ${current}${C_RESET}"
    info "Dernière version stable : ${C_BOLD}Fedora ${latest}${C_RESET}"

    if [[ "$latest" -le "$current" ]]; then
        info "${C_GREEN}Le système est déjà sur la dernière version stable.${C_RESET}"
        return 0
    fi

    target=$((current + 1))
    if [[ "$latest" -gt "$target" ]]; then
        info "Montée d'une version à la fois : Fedora ${target} d'abord, puis"
        info "relancez ${C_YELLOW}sudo ${CMD_NAME} --upgrade${C_RESET} pour atteindre Fedora ${latest}."
    fi

    section "Avant de commencer"
    upgrade_preflight || { info "Montée de version annulée."; return 0; }

    if ! ask_yes_no "Passer de Fedora ${current} à Fedora ${target} ?"; then
        info "Montée de version annulée."
        return 0
    fi

    # La procédure officielle exige un système à jour : des paquets en retard
    # sont la première cause de conflits de dépendances au téléchargement.
    section "Mise à jour de Fedora ${current}"
    if ! run "Mise à jour des paquets RPM" dnf upgrade -y --refresh; then
        error "Mise à jour incomplète : montée de version interrompue."
        return 1
    fi

    # Instantané pris après la mise à jour : c'est l'état « connu bon » le plus
    # récent auquel revenir si la nouvelle version pose problème.
    if root_is_btrfs; then
        section "Instantané Btrfs"
        if [[ $DO_SNAPSHOT -eq 1 ]] || ask_yes_no "Créer un instantané de / avant la montée de version ?"; then
            create_snapshot
        fi
    fi

    section "Téléchargement de Fedora ${target}"
    if ! upgrade_download "$target"; then
        error "Montée de version interrompue : le système reste en Fedora ${current}."
        return 1
    fi

    section "Installation"
    info "L'installation a lieu au redémarrage, hors session graphique."
    info "${C_YELLOW}Ne coupez pas la machine pendant l'opération.${C_RESET}"
    info "Ensuite : ${C_YELLOW}sudo ${CMD_NAME}${C_RESET} (pilotes, codecs, listes) puis"
    info "${C_YELLOW}sudo ${CMD_NAME} --clean${C_RESET} pour retirer l'ancien noyau et le cache."

    # Comme ask_reboot : --yes ne doit pas redémarrer la machine d'office.
    if [[ $ASSUME_YES -eq 1 ]]; then
        info "Pour lancer l'installation : ${C_YELLOW}sudo dnf offline reboot${C_RESET}"
        return 0
    fi
    if ask_yes_no "Redémarrer maintenant pour installer Fedora ${target} ?"; then
        log "Redémarrage pour la montée de version vers Fedora ${target}"
        run "Redémarrage et installation de Fedora ${target}" dnf offline reboot -y
    else
        info "Les paquets restent prêts. Pour lancer l'installation plus tard :"
        info "  ${C_YELLOW}sudo dnf offline reboot${C_RESET}"
    fi
}

#===============================================================================
# INSTANTANÉ BTRFS (--snapshot)
#
# Sur un système de fichiers Btrfs, un instantané se crée en une fraction de
# seconde et n'occupe initialement aucun espace (copie sur écriture) : c'est
# un filet de sécurité peu coûteux avant une mise à jour massive ou un
# changement de pilote graphique.
#
# L'instantané est en lecture seule et rangé dans /.snapshots. Il ne
# remplace pas une sauvegarde : il vit sur le même disque et disparaît avec
# lui. C'est une protection contre une mise à jour ratée, pas contre une
# panne matérielle.
#===============================================================================

readonly SNAPSHOT_DIR="/.snapshots"

# Vrai si la racine est un système de fichiers Btrfs.
root_is_btrfs() {
    [[ "$(findmnt -no FSTYPE / 2>/dev/null)" == "btrfs" ]]
}

# Crée un instantané en lecture seule de la racine, horodaté.
create_snapshot() {
    if ! root_is_btrfs; then
        info "${C_YELLOW}La racine n'est pas en Btrfs : instantané impossible.${C_RESET}"
        info "${C_YELLOW}(Sur ext4/xfs, utilisez plutôt une sauvegarde classique.)${C_RESET}"
        return 0
    fi

    if ! has_cmd btrfs; then
        info "Commande btrfs introuvable : instantané ignoré."
        return 0
    fi

    local name
    name="${SNAPSHOT_DIR}/root_$(date '+%Y%m%d-%H%M%S')"

    if [[ ! -d "$SNAPSHOT_DIR" ]]; then
        run "Création du dossier ${SNAPSHOT_DIR}" \
            btrfs subvolume create "$SNAPSHOT_DIR"
    fi

    if run "Instantané Btrfs de /" btrfs subvolume snapshot -r / "$name"; then
        info "Instantané : ${C_GREEN}${name}${C_RESET}"
        info "Lister : ${C_YELLOW}sudo btrfs subvolume list /${C_RESET}"
        info "Supprimer : ${C_YELLOW}sudo btrfs subvolume delete ${name}${C_RESET}"
        info "${C_YELLOW}Note : un instantané n'est pas une sauvegarde (même disque).${C_RESET}"
    fi
}

#===============================================================================
# RÉCAPITULATIF ET INTERRUPTIONS
#
# Le script enchaîne des centaines de commandes dont la sortie défile : sans
# récapitulatif, une erreur survenue tôt passe inaperçue. summary() est
# appelée aussi bien en fin normale que sur interruption (Ctrl-C), afin que
# l'utilisateur sache toujours ce qui a réellement été fait.
#===============================================================================

summary() {
    section "Récapitulatif"

    if [[ $DRY_RUN -eq 1 ]]; then
        info "Mode simulation : ${C_BLUE}${COUNT_SKIPPED}${C_RESET} commande(s) affichée(s), aucune exécutée."
        info "Relancez sans --dry-run pour appliquer réellement les changements."
        return
    fi

    info "Réussites : ${C_GREEN}${COUNT_OK}${C_RESET}"

    if [[ $COUNT_FAIL -eq 0 ]]; then
        info "Échecs    : ${C_GREEN}0${C_RESET}"
    else
        info "Échecs    : ${C_RED}${COUNT_FAIL}${C_RESET}"
        local action
        for action in "${FAILED_ACTIONS[@]}"; do
            info "  ${C_RED}✗${C_RESET} ${action}"
        done
        info "Détail complet : ${C_YELLOW}${LOG_FILE}${C_RESET}"
    fi
}

# Interruption (Ctrl-C) : on affiche ce qui a été fait avant de quitter,
# plutôt que de laisser l'utilisateur devant un terminal muet.
on_interrupt() {
    echo ""
    error "Interruption demandée (Ctrl-C)."
    log "Script interrompu par l'utilisateur"
    summary
    exit 130
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

    # Avec --yes, aucune question ne doit bloquer une exécution sans
    # surveillance ; redémarrer d'office serait en revanche trop brutal.
    if [[ $ASSUME_YES -eq 1 ]]; then
        info "${C_YELLOW}Un redémarrage est recommandé : pensez à redémarrer.${C_RESET}"
        return
    fi

    local answer
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
# zéro volontaire), alors que --update (checkout de la dernière release
# taggée) ne touche qu'au script et aux gabarits — jamais aux listes
# personnalisées de l'utilisateur.
#
# Si le dépôt source a un remote « origin » configuré, --install clone le
# dépôt (au lieu de copier les fichiers un par un) : cela permet ensuite de
# mettre à jour l'installation via --update (suit les tags vX.Y.Z créés par
# release.sh ; sans tag, se rabat sur git pull). Sans remote, --install
# revient à la copie de fichiers classique et --update n'est pas disponible.
#===============================================================================

# Fichiers du projet installés tels quels (gabarits *.example + README)
INSTALL_FILES=(rpm.list.example flatpak.list.example repos.list.example gnome-extensions.list.example bashrc.example README.md LICENSE)
readonly INSTALL_FILES

# Lit la variable VERSION d'un exemplaire du script (vide s'il est absent).
#   $1 : chemin du script
script_version() {
    grep -m1 '^readonly VERSION=' "$1" 2>/dev/null \
        | sed -E 's/^readonly VERSION="(.*)"$/\1/'
}

# Place le clone de INSTALL_DIR sur la dernière release taggée (vX.Y.Z).
# Seuls les tags au format de release.sh sont retenus : un tag de travail
# (« test », « wip »…) ne doit jamais être déployé. --sort=-v:refname trie
# par version sémantique décroissante (tri natif git, pas de parsing).
# Sans aucun tag, le clone reste sur la branche par défaut.
#   $1 : « pull » pour se rabattre sur git pull en l'absence de tag
checkout_latest_release() {
    local fallback="${1:-}" latest_tag current_tag

    # En simulation, le clone n'existe pas encore : rien à interroger.
    if [[ $DRY_RUN -eq 1 && ! -d "$INSTALL_DIR/.git" ]]; then
        run "Passage à la dernière release" \
            git -C "$INSTALL_DIR" checkout "<dernier tag vX.Y.Z>" --
        return 0
    fi

    # safe.directory : en simulation sans sudo, le clone appartient à root et
    # git refuserait de le lire (« propriétaire douteux »).
    latest_tag="$(git -c safe.directory="$INSTALL_DIR" -C "$INSTALL_DIR" \
        tag --list 'v[0-9]*' --sort=-v:refname 2>/dev/null | head -n1)"

    if [[ -z "$latest_tag" ]]; then
        if [[ "$fallback" == "pull" ]]; then
            info "Aucun tag de release trouvé : mise à jour sur la branche par défaut (git pull)."
            run "Récupération des mises à jour (git pull)" git -C "$INSTALL_DIR" pull --ff-only
        else
            info "Aucun tag de release : installation sur la branche par défaut."
        fi
        return 0
    fi

    current_tag="$(git -c safe.directory="$INSTALL_DIR" -C "$INSTALL_DIR" \
        describe --tags --exact-match 2>/dev/null || true)"
    if [[ "$current_tag" == "$latest_tag" ]]; then
        info "Déjà sur la dernière release (${latest_tag})."
    else
        run "Passage à la release ${latest_tag}" git -C "$INSTALL_DIR" checkout -q "$latest_tag" --
    fi
}

install_command() {
    require_root_for "--install" "installation de la commande"
    section "Installation de la commande « ${CMD_NAME} »"

    local origin_url
    origin_url="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || true)"

    # root n'a en général pas accès à la clé SSH de l'utilisateur : on
    # convertit une URL SSH (git@github.com:user/repo.git) en HTTPS pour que
    # le clone fonctionne sans authentification (dépôt public).
    if [[ "$origin_url" =~ ^git@github\.com:(.+)$ ]]; then
        origin_url="https://github.com/${BASH_REMATCH[1]}"
    fi

    if [[ -n "$origin_url" && ! -d "$INSTALL_DIR/.git" ]]; then
        # Un remote existe et aucune installation git n'est déjà en place :
        # on clone pour pouvoir utiliser --update ensuite.
        if [[ -e "$INSTALL_DIR" ]]; then
            run "Suppression de l'ancienne installation par copie" rm -rf "$INSTALL_DIR"
        fi
        if ! run "Clonage du dépôt dans ${INSTALL_DIR}" git clone -q "$origin_url" "$INSTALL_DIR"; then
            error "Échec du clonage : installation annulée."
            exit 1
        fi
        # Un clone se trouve sur la tête de branche, qui peut contenir du
        # travail non publié : on installe la dernière release, comme --update.
        checkout_latest_release
    elif [[ -n "$origin_url" && -d "$INSTALL_DIR/.git" ]]; then
        info "Installation git déjà en place dans ${INSTALL_DIR} (utilisez --update pour la synchroniser)."
    elif [[ "$SCRIPT_DIR" == "$INSTALL_DIR" ]]; then
        # Lancé depuis l'installation elle-même : copier un fichier sur
        # lui-même échouerait, il n'y a rien à copier.
        info "Script lancé depuis ${INSTALL_DIR} : aucune copie nécessaire."
    else
        # Pas de remote configuré : copie de fichiers classique, --update indisponible.
        run "Création de ${INSTALL_DIR}" install -d "$INSTALL_DIR"
        run "Copie de ${SCRIPT_NAME}" \
            install -m 755 "${SCRIPT_DIR}/${SCRIPT_NAME}" "${INSTALL_DIR}/${SCRIPT_NAME}"
        local f
        for f in "${INSTALL_FILES[@]}"; do
            if [[ -f "${SCRIPT_DIR}/$f" ]]; then
                run "Copie de ${f}" install -m 644 "${SCRIPT_DIR}/$f" "${INSTALL_DIR}/$f"
            fi
        done
        info "Aucun remote git « origin » configuré : installation par copie, --update indisponible."
    fi

    # Le script installé doit être exécutable même après un clone git
    run "Droits d'exécution" chmod 755 "${INSTALL_DIR}/${SCRIPT_NAME}"

    # Remise à zéro volontaire des listes réelles depuis les gabarits *.example
    # (--install écrase toujours ; --update, lui, n'y touche jamais). En
    # simulation, INSTALL_DIR peut ne pas exister : on énumère alors les
    # gabarits du dépôt source, qui sont les mêmes.
    local src_dir="$INSTALL_DIR" example name
    [[ $DRY_RUN -eq 1 && ! -d "$INSTALL_DIR" ]] && src_dir="$SCRIPT_DIR"
    for example in "${src_dir}"/*.list.example; do
        [[ -e "$example" ]] || continue
        name="$(basename "$example")"
        run "Régénération de ${name%.example}" \
            install -m 644 "${INSTALL_DIR}/${name}" "${INSTALL_DIR}/${name%.example}"
    done

    # Lien symbolique dans le PATH -> commande accessible partout
    run "Lien ${BIN_DIR}/${CMD_NAME}" ln -sf "${INSTALL_DIR}/${SCRIPT_NAME}" "${BIN_DIR}/${CMD_NAME}"

    local installed_version
    installed_version="$(script_version "${INSTALL_DIR}/${SCRIPT_NAME}")"

    info "Fichiers installés dans : ${C_BLUE}${INSTALL_DIR}${C_RESET}"
    info "Commande disponible     : ${C_GREEN}${CMD_NAME}${C_RESET} (${BIN_DIR}/${CMD_NAME}), version ${installed_version:-$VERSION}"
    info "Listes à personnaliser  : ${INSTALL_DIR}/rpm.list , ${INSTALL_DIR}/flatpak.list , ${INSTALL_DIR}/gnome-extensions.list"
    info "${C_YELLOW}Note : --install régénère toujours ces listes depuis les *.list.example${C_RESET}"
    info "${C_YELLOW}(remise à zéro) ; --update, lui, ne les touche jamais.${C_RESET}"
    info "Lancez maintenant : ${C_YELLOW}sudo ${CMD_NAME}${C_RESET}"
}

update_command() {
    require_root_for "--update" "mise à jour de la commande"

    if [[ ! -d "$INSTALL_DIR/.git" ]]; then
        error "Installation non-git dans ${INSTALL_DIR} : impossible de mettre à jour."
        error "Relancez --install depuis un clone avec un remote « origin » configuré."
        exit 1
    fi

    section "Mise à jour de la commande « ${CMD_NAME} »"

    local old_version new_version
    old_version="$(script_version "$INSTALL_DIR/${SCRIPT_NAME}")"

    run "Récupération des tags" git -C "$INSTALL_DIR" fetch -q --tags --force

    # --update suit toujours la dernière release taggée (vX.Y.Z), jamais un
    # commit intermédiaire de la branche.
    checkout_latest_release pull

    run "Droits d'exécution" chmod 755 "${INSTALL_DIR}/${SCRIPT_NAME}"
    run "Lien ${BIN_DIR}/${CMD_NAME}" ln -sf "${INSTALL_DIR}/${SCRIPT_NAME}" "${BIN_DIR}/${CMD_NAME}"

    new_version="$(script_version "$INSTALL_DIR/${SCRIPT_NAME}")"
    info "Version : ${C_YELLOW}${old_version}${C_RESET} -> ${C_GREEN}${new_version}${C_RESET}"
}

uninstall_command() {
    require_root_for "--uninstall" "désinstallation de la commande"
    section "Désinstallation de la commande « ${CMD_NAME} »"

    run "Suppression du lien ${BIN_DIR}/${CMD_NAME}" rm -f "${BIN_DIR}/${CMD_NAME}"
    run "Suppression de ${INSTALL_DIR}" rm -rf "$INSTALL_DIR"
    info "(Les journaux dans /var/log/fedora-setup_*.log sont conservés.)"
}

#===============================================================================
# ARGUMENTS
#===============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        # Les options -r/-f/-d/-e attendent un fichier : sans lui, set -u
        # interromprait le script sur un obscur « $2 : variable sans liaison ».
        if [[ "$1" =~ ^-[rfde]$ && $# -lt 2 ]]; then
            error "L'option $1 attend un nom de fichier."
            exit 1
        fi
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
            -n|--dry-run)  DRY_RUN=1; shift ;;
            --snapshot)    DO_SNAPSHOT=1; shift ;;
            -v|--version)  echo "$VERSION"; exit 0 ;;
            # Ces actions sont mémorisées et non exécutées ici : le reste de
            # la ligne de commande doit d'abord être lu, faute de quoi un
            # « --clean --dry-run » lancerait le nettoyage pour de vrai,
            # DRY_RUN n'étant pas encore positionné.
            --install)     ACTION="install_command"; shift ;;
            --update)      ACTION="update_command"; shift ;;
            --uninstall)   ACTION="uninstall_command"; shift ;;
            --bashrc)      ACTION="install_bashrc"; shift ;;
            --docker)      ACTION="install_docker"; shift ;;
            --clean)       ACTION="clean_system"; shift ;;
            --memory)      ACTION="optimize_memory"; shift ;;
            --boot)        ACTION="optimize_boot"; shift ;;
            --laptop)      ACTION="optimize_laptop"; shift ;;
            --security)    ACTION="secure_system"; shift ;;
            --devtools)    ACTION="install_devtools"; shift ;;
            --upgrade)     ACTION="upgrade_fedora"; shift ;;
            --update-system) ACTION="update_only"; shift ;;
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

    # Installé après parse_args : --help et --version doivent pouvoir sortir
    # sans déclencher le récapitulatif.
    trap on_interrupt INT TERM

    # Action autonome (--clean, --memory, --boot…) : elle remplace le flux
    # de post-installation et bénéficie du récapitulatif comme lui.
    if [[ -n "$ACTION" ]]; then
        "$ACTION"
        summary
        [[ $OFFER_REBOOT -eq 1 && $DRY_RUN -eq 0 ]] && ask_reboot
        [[ $COUNT_FAIL -eq 0 ]]
        return
    fi

    echo -e "${C_BOLD}=== Fedora Setup v${VERSION} — post-installation & maintenance ===${C_RESET}"

    if [[ $DRY_RUN -eq 1 ]]; then
        echo -e "${C_BLUE}Mode simulation : aucune modification ne sera appliquée.${C_RESET}"
    fi

    checks

    [[ $DO_SNAPSHOT -eq 1 ]] && { section "Instantané Btrfs"; create_snapshot; }

    configure_dnf
    setup_repos

    [[ $DO_REPOS -eq 1 ]]    && install_repos
    [[ $DO_UPDATE -eq 1 ]]   && update_system
    [[ $DO_FIRMWARE -eq 1 ]] && update_firmwares
    [[ $DO_GPU -eq 1 ]]      && setup_gpu

    setup_multimedia

    [[ $DO_LISTS -eq 1 ]]    && install_lists
    [[ $DO_GNOME_EXT -eq 1 ]] && install_gnome_extensions

    summary

    # En simulation, proposer un redémarrage n'aurait aucun sens.
    [[ $DRY_RUN -eq 0 ]] && ask_reboot

    # Code de sortie non nul si au moins une action a échoué : permet
    # d'enchaîner le script dans une automatisation.
    [[ $COUNT_FAIL -eq 0 ]]
}

main "$@"
