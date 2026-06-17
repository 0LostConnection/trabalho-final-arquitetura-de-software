#!/usr/bin/env bash
# Converte SVGs para PNG com fundo branco e margem, em alta resolução.
# Estratégia: rsvg-convert renderiza o SVG → magick adiciona a borda em pixels reais.
#
# Uso: ./svg_to_png.sh [arquivo.svg ...]
#   Sem argumentos converte todos os .svg do diretório atual.

set -euo pipefail

# --- Configurações ---
ZOOM=3        # fator de escala (3× ≈ 288 DPI); use 4 para ainda mais resolução
MARGIN=120    # margem em pixels reais de saída (após zoom)
BG="white"

if [[ $# -gt 0 ]]; then
    files=("$@")
else
    mapfile -t files < <(printf '%s\n' *.svg 2>/dev/null)
fi

if [[ ${#files[@]} -eq 0 ]]; then
    echo "Nenhum arquivo .svg encontrado." >&2
    exit 1
fi

for svg in "${files[@]}"; do
    [[ -f "$svg" ]] || { echo "Arquivo não encontrado: $svg" >&2; continue; }

    out="${svg%.svg}.png"

    # 1) Renderiza o SVG em PNG de alta resolução (pipe para evitar arquivo temporário)
    # 2) magick adiciona fundo branco + borda uniforme no espaço real de pixels
    rsvg-convert \
        --zoom "$ZOOM" \
        --background-color "$BG" \
        "$svg" \
    | magick - \
        -background "$BG" \
        -flatten \
        -bordercolor "$BG" \
        -border "${MARGIN}x${MARGIN}" \
        "$out"

    # Exibe resolução final
    dims=$(magick identify -format "%wx%h" "$out")
    echo "✓  $svg  →  $out  (${dims}px)"
done
