#!/usr/bin/env python3
"""
Génère les captures d'écran du README et de la documentation (docs/img/*.svg).

Chaque capture est la sortie RÉELLE de fedora-setup.sh en mode simulation
(--dry-run), exécutée dans un pseudo-terminal pour conserver les couleurs,
puis convertie en SVG façon fenêtre de terminal. Les images restent donc
fidèles au script : il suffit de relancer cet outil après une modification.

Usage : ./tools/screenshots.py            (depuis la racine du dépôt, sans sudo)
"""

import html
import os
import pty
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "docs", "img")
SCRIPT = "./fedora-setup.sh"

# Chaque capture : fichier, titre de fenêtre, commande affichée, arguments,
# et plages de lignes conservées (None = tout). Entre deux plages, une ligne
# « ⋮ » signale la coupe : la sortie complète ferait plusieurs écrans.
SHOTS = [
    {
        "file": "dry-run.svg",
        "title": "fedora-setup — simulation",
        "args": ["--dry-run", "--yes"],
        # En-tête, détection GPU (le cœur du script), puis récapitulatif
        "keep": [(0, 2), ("==> Pilotes graphiques", 16), (-4, None)],
    },
    {
        "file": "clean.svg",
        "title": "fedora-setup --clean",
        "args": ["--clean", "--dry-run"],
        "keep": [(0, 24)],
    },
    {
        "file": "security.svg",
        "title": "fedora-setup --security",
        "args": ["--security", "--dry-run", "--yes"],
        "keep": [(0, 20)],
    },
    {
        "file": "help.svg",
        "title": "fedora-setup --help",
        "args": ["--help"],
        "keep": [(0, 24)],
    },
]

# Palette (fond sombre, lisible en thème clair comme en thème sombre)
BG, BAR, FG, DIM = "#1e2030", "#2a2d42", "#d6dbf5", "#7f849c"
SGR_COLORS = {
    "31": "#f38ba8",  # rouge   : erreurs
    "32": "#a6e3a1",  # vert    : OK
    "33": "#f9e2af",  # jaune   : avertissements
    "34": "#89b4fa",
    "36": "#89dceb",  # cyan    : sections, « simulé »
    "90": DIM,
}

FONT_SIZE, LINE_H, CHAR_W, PAD, BAR_H = 13, 19, 7.85, 18, 34
MAX_COLS = 96

ANSI_RE = re.compile(r"\x1b\[([0-9;]*)m")


def run_capture(args):
    """Exécute le script dans un pseudo-terminal (couleurs actives).

    fedora-setup.sh n'émet ses couleurs que si sa sortie est un terminal
    ([[ -t 1 ]]) : on lui fournit donc un pty plutôt qu'un simple tube.
    L'entrée standard est /dev/null : aucune question ne peut bloquer.
    """
    cmd = " ".join([SCRIPT] + args)
    env = dict(os.environ, LANG="fr_FR.UTF-8", TERM="xterm-256color")
    master, slave = pty.openpty()
    proc = subprocess.Popen(
        [SCRIPT] + args, cwd=ROOT, env=env,
        stdin=subprocess.DEVNULL, stdout=slave, stderr=slave,
    )
    os.close(slave)
    chunks = []
    while True:
        try:
            data = os.read(master, 65536)
        except OSError:  # EIO : le processus a fermé le terminal
            break
        if not data:
            break
        chunks.append(data)
    proc.wait(timeout=600)
    os.close(master)
    return cmd, b"".join(chunks).decode("utf-8", "replace").replace("\r", "")


def trim(lines, keep):
    """Ne conserve que les plages demandées, séparées par « ⋮ »."""
    if not keep:
        return lines
    result = []
    for i, (start, end) in enumerate(keep):
        # Une plage peut débuter sur un texte (titre de section) plutôt que
        # sur un numéro de ligne : elle survit ainsi à l'ajout de lignes
        # en amont. « end » est alors un nombre de lignes.
        if isinstance(start, str):
            start = next(n for n, line in enumerate(lines) if start in ANSI_RE.sub("", line))
            end = start + end
        chunk = lines[start:end]
        if i and chunk:
            result.append("\x1b[90m    ⋮\x1b[0m")
        result.extend(chunk)
    return result


def parse_line(line):
    """Découpe une ligne ANSI en segments (texte, couleur, gras)."""
    segments, color, bold, pos = [], None, False, 0
    for m in ANSI_RE.finditer(line):
        if m.start() > pos:
            segments.append((line[pos:m.start()], color, bold))
        for code in (m.group(1) or "0").split(";"):
            if code in ("0", ""):
                color, bold = None, False
            elif code == "1":
                bold = True
            elif code in SGR_COLORS:
                color = SGR_COLORS[code]
        pos = m.end()
    if pos < len(line):
        segments.append((line[pos:], color, bold))
    return segments


def clip(segments, width):
    """Tronque une ligne trop longue en ajoutant « … »."""
    out, used = [], 0
    for text, color, bold in segments:
        if used + len(text) > width:
            out.append((text[: width - used - 1] + "…", color, bold))
            return out
        out.append((text, color, bold))
        used += len(text)
    return out


def to_svg(title, cmd, lines):
    rows = [[("$ ", DIM, False), (cmd, FG, True)], []]
    rows += [clip(parse_line(line), MAX_COLS) for line in lines]
    cols = max(sum(len(t) for t, _, _ in r) for r in rows)
    width = int(max(cols, 60) * CHAR_W + 2 * PAD)
    height = BAR_H + PAD + len(rows) * LINE_H + PAD // 2

    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}" role="img" aria-label="{html.escape(title)}">',
        f"<title>{html.escape(title)}</title>",
        "<style>text{font-family:'JetBrains Mono','Fira Code',ui-monospace,"
        "SFMono-Regular,Menlo,Consolas,'DejaVu Sans Mono',monospace;"
        f"font-size:{FONT_SIZE}px;white-space:pre}}.b{{font-weight:700}}</style>",
        f'<rect width="{width}" height="{height}" rx="10" fill="{BG}"/>',
        f'<path d="M0 10a10 10 0 0 1 10-10h{width - 20}a10 10 0 0 1 10 10v{BAR_H - 10}H0z" fill="{BAR}"/>',
    ]
    for i, c in enumerate(("#ff5f57", "#febc2e", "#28c840")):
        parts.append(f'<circle cx="{20 + i * 20}" cy="{BAR_H // 2}" r="6" fill="{c}"/>')
    parts.append(
        f'<text x="{width // 2}" y="{BAR_H // 2 + 4}" fill="{DIM}" '
        f'text-anchor="middle">{html.escape(title)}</text>'
    )

    y = BAR_H + PAD + FONT_SIZE
    for row in rows:
        spans = []
        for text, color, bold in row:
            if not text:
                continue
            attrs = f' fill="{color}"' if color else ""
            attrs += ' class="b"' if bold else ""
            spans.append(f"<tspan{attrs}>{html.escape(text)}</tspan>")
        if spans:
            parts.append(f'<text x="{PAD}" y="{y}" fill="{FG}" xml:space="preserve">{"".join(spans)}</text>')
        y += LINE_H

    parts.append("</svg>")
    return "\n".join(parts) + "\n"


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    for shot in SHOTS:
        cmd, out = run_capture(shot["args"])
        # Chemins présentés tels qu'après --install, et jamais le dossier
        # personnel de celui qui génère les images.
        out = out.replace(ROOT, "/opt/fedora-setup")
        out = out.replace(os.path.expanduser("~"), "~")
        lines = out.rstrip("\n").split("\n")
        lines = trim(lines, shot["keep"])
        shown = cmd.replace("./fedora-setup.sh", "fedora-setup")
        path = os.path.join(OUT_DIR, shot["file"])
        with open(path, "w", encoding="utf-8") as f:
            f.write(to_svg(shot["title"], shown, lines))
        print(f"  {os.path.relpath(path, ROOT)}  ({len(lines)} lignes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
