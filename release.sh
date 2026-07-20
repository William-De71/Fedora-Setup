#!/usr/bin/env bash
#===============================================================================
#
#  FICHIER      : release.sh
#
#  USAGE        : ./release.sh patch|minor|major
#
#  DESCRIPTION  : Publie une nouvelle version de fedora-setup.sh :
#                 - incrémente VERSION (semver) dans fedora-setup.sh
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
echo "Ceci va :"
echo "  1. Modifier VERSION dans $(basename "$TARGET_FILE")"
echo "  2. Commiter : « Release $tag »"
echo "  3. Créer le tag $tag"
echo "  4. Pousser $DEFAULT_BRANCH et $tag vers origin"
echo
read -r -p "Confirmer ? [y/N] : " answer
[[ "${answer,,}" == "y" ]] || { echo "Annulé."; exit 1; }

# --- Exécution ---

sed -i -E "s/^readonly VERSION=\"${current_version//./\\.}\"/readonly VERSION=\"${new_version}\"/" "$TARGET_FILE"

git -C "$SCRIPT_DIR" add "$TARGET_FILE"
git -C "$SCRIPT_DIR" commit -m "Release ${tag}"
git -C "$SCRIPT_DIR" tag -a "$tag" -m "$tag"
git -C "$SCRIPT_DIR" push origin "$DEFAULT_BRANCH"
git -C "$SCRIPT_DIR" push origin "$tag"

echo
echo "Publié : $tag"
