#!/usr/bin/env bash
#===============================================================================
#
#  FICHIER      : release.sh
#
#  USAGE        : ./release.sh patch|minor|major
#
#  DESCRIPTION  : Publie une nouvelle version de fedora-setup.sh :
#                 - incrémente VERSION (semver) dans fedora-setup.sh
#                 - vérifie le script (bash -n, shellcheck) et la
#                   synchronisation avec origin avant toute modification
#                 - régénère les captures d'écran (docs/img), qui
#                   affichent le numéro de version
#                 - commit, tag vX.Y.Z, push (commit + tag)
#                 Le push du tag déclenche le workflow GitHub Actions
#                 (.github/workflows/release.yml) qui crée la Release GitHub.
#
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly TARGET_FILE="${SCRIPT_DIR}/fedora-setup.sh"
readonly DEFAULT_BRANCH="master"

# Pages de documentation affichant le numéro de version. Elles portent un
# élément « <span data-version>vX.Y.Z</span> » dans la barre latérale : sans
# cette mise à jour, le site publié annoncerait indéfiniment la version
# figée au moment de sa rédaction.
readonly DOCS_DIR="${SCRIPT_DIR}/docs"

# Générateur des captures d'écran du README et de la documentation.
readonly SCREENSHOTS_TOOL="${SCRIPT_DIR}/tools/screenshots.py"
readonly SCREENSHOTS_DIR="${DOCS_DIR}/img"

usage() {
    cat << EOF
Usage : ./release.sh patch|minor|major

Incrémente la version de fedora-setup.sh (semver), commit, tag vX.Y.Z
et pousse le commit + le tag vers origin.

  patch   x.y.Z -> x.y.(Z+1)   corrections, sans changement de comportement
  minor   x.Y.z -> x.(Y+1).0   nouvelles fonctionnalités rétro-compatibles
  major   X.y.z -> (X+1).0.0   changements non rétro-compatibles
EOF
}

error() {
    echo "ERREUR : $*" >&2
}

if [[ $# -ne 1 ]]; then
    usage
    exit 1
fi

case "$1" in
    patch|minor|major) bump_type="$1" ;;
    -h|--help)          usage; exit 0 ;;
    *)                   error "Argument invalide : $1"; usage; exit 1 ;;
esac

# --- Vérifications préalables ---

if [[ ! -f "$TARGET_FILE" ]]; then
    error "Fichier introuvable : $TARGET_FILE"
    exit 1
fi

if [[ -n "$(git -C "$SCRIPT_DIR" status --porcelain)" ]]; then
    error "Le dépôt a des changements non commités. Commitez ou stashez d'abord."
    exit 1
fi

current_branch="$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD)"
if [[ "$current_branch" != "$DEFAULT_BRANCH" ]]; then
    echo "Attention : vous êtes sur la branche « ${current_branch} », pas « ${DEFAULT_BRANCH} »."
    read -r -p "Continuer quand même ? [y/N] : " answer
    [[ "${answer,,}" == "y" ]] || { echo "Annulé."; exit 1; }
fi

# Le script publié tourne en root sur des machines réelles : on refuse de
# publier une version qui ne passerait pas la CI (même contrôles qu'elle).
if ! bash -n "$TARGET_FILE"; then
    error "Erreur de syntaxe dans $(basename "$TARGET_FILE")."
    exit 1
fi
if command -v shellcheck &> /dev/null; then
    if ! shellcheck -S warning "$TARGET_FILE" "${SCRIPT_DIR}/release.sh"; then
        error "ShellCheck signale des problèmes : corrigez-les avant de publier."
        exit 1
    fi
else
    echo "Attention : shellcheck absent, vérification ignorée (sudo dnf install ShellCheck)."
fi

# Une branche en retard sur origin ferait échouer le push après le commit
# et le tag locaux : mieux vaut s'en apercevoir avant de modifier quoi que ce soit.
if git -C "$SCRIPT_DIR" fetch --quiet origin "$DEFAULT_BRANCH" 2> /dev/null; then
    behind="$(git -C "$SCRIPT_DIR" rev-list --count "HEAD..origin/${DEFAULT_BRANCH}")"
    if [[ "$behind" -gt 0 ]]; then
        error "La branche locale a ${behind} commit(s) de retard sur origin/${DEFAULT_BRANCH} : faites un git pull d'abord."
        exit 1
    fi
else
    echo "Attention : impossible de joindre origin, synchronisation non vérifiée."
fi

# --- Lecture et calcul de la nouvelle version ---

current_version="$(grep -m1 '^readonly VERSION=' "$TARGET_FILE" | sed -E 's/^readonly VERSION="(.*)"$/\1/')"
if [[ -z "$current_version" ]]; then
    error "Impossible de lire VERSION dans $TARGET_FILE"
    exit 1
fi

if [[ ! "$current_version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    error "Version actuelle non conforme au semver : $current_version"
    exit 1
fi

major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[3]}"

case "$bump_type" in
    patch) patch=$((patch + 1)) ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    major) major=$((major + 1)); minor=0; patch=0 ;;
esac

new_version="${major}.${minor}.${patch}"
tag="v${new_version}"

if git -C "$SCRIPT_DIR" rev-parse "$tag" &> /dev/null; then
    error "Le tag $tag existe déjà."
    exit 1
fi

# --- Confirmation ---

echo "Version actuelle : $current_version"
echo "Nouvelle version : $new_version ($bump_type)"
echo
# « || true » indispensable : sous pipefail, un grep sans correspondance
# ferait échouer le script avant même la demande de confirmation.
doc_pages=0
if [[ -d "$DOCS_DIR" ]]; then
    doc_pages=$(grep -l '<span data-version>' "$DOCS_DIR"/*.html 2>/dev/null | wc -l || true)
fi

step=1
echo "Ceci va :"
echo "  $((step++)). Modifier VERSION dans $(basename "$TARGET_FILE")"
if [[ $doc_pages -gt 0 ]]; then
    echo "  $((step++)). Mettre à jour la version dans ${doc_pages} page(s) de docs/"
fi
if [[ -x "$SCREENSHOTS_TOOL" ]]; then
    echo "  $((step++)). Régénérer les captures d'écran (docs/img/)"
fi
echo "  $((step++)). Commiter : « Release $tag »"
echo "  $((step++)). Créer le tag $tag"
echo "  $((step++)). Pousser $DEFAULT_BRANCH et $tag vers origin"
echo
read -r -p "Confirmer ? [y/N] : " answer
[[ "${answer,,}" == "y" ]] || { echo "Annulé."; exit 1; }

# --- Exécution ---

sed -i -E "s/^readonly VERSION=\"${current_version//./\\.}\"/readonly VERSION=\"${new_version}\"/" "$TARGET_FILE"

# Vérification : le sed ci-dessus est silencieux s'il ne trouve rien.
if ! grep -q "^readonly VERSION=\"${new_version}\"$" "$TARGET_FILE"; then
    error "La version n'a pas pu être mise à jour dans $(basename "$TARGET_FILE")."
    git -C "$SCRIPT_DIR" checkout -- "$TARGET_FILE"
    exit 1
fi

files_to_commit=("$TARGET_FILE")

# Répercuter la version dans la documentation. Le remplacement cible
# l'attribut data-version : un numéro cité en exemple dans le texte n'est
# jamais touché par erreur.
if [[ -d "$DOCS_DIR" ]]; then
    updated_docs=0
    for page in "$DOCS_DIR"/*.html; do
        [[ -e "$page" ]] || continue
        if grep -q '<span data-version>' "$page"; then
            sed -i -E "s|(<span data-version>)v[0-9]+\.[0-9]+\.[0-9]+(</span>)|\1v${new_version}\2|" "$page"
            files_to_commit+=("$page")
            updated_docs=$((updated_docs + 1))
        fi
    done
    if [[ $updated_docs -gt 0 ]]; then
        echo "Documentation mise à jour : ${updated_docs} page(s)"
    fi
fi

# Les captures affichent la bannière « Fedora Setup vX.Y.Z » : elles sont
# régénérées depuis la sortie réelle du script, déjà à la nouvelle version.
# Un échec n'est pas bloquant (les anciennes images restent valables).
if [[ -x "$SCREENSHOTS_TOOL" ]]; then
    if "$SCREENSHOTS_TOOL"; then
        files_to_commit+=("$SCREENSHOTS_DIR")
    else
        echo "Attention : captures d'écran non régénérées, publication poursuivie."
        git -C "$SCRIPT_DIR" checkout -- "$SCREENSHOTS_DIR" 2> /dev/null || true
    fi
fi

git -C "$SCRIPT_DIR" add "${files_to_commit[@]}"
git -C "$SCRIPT_DIR" commit -m "Release ${tag}"
git -C "$SCRIPT_DIR" tag -a "$tag" -m "$tag"
git -C "$SCRIPT_DIR" push origin "$DEFAULT_BRANCH"
git -C "$SCRIPT_DIR" push origin "$tag"

echo
echo "Publié : $tag"
