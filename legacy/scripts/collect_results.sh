#!/usr/bin/env bash
# Empaqueta todos los logs de la sesión en un único fichero para enviármelo. Se ejecuta en el host.
#   ./scripts/collect_results.sh
set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$(date +%Y%m%d_%H%M)"
OUT="${HOME}/drone_s1_resultados_${STAMP}.tar.gz"

cd "${REPO_DIR}"
ls -la logs > logs/99_indice.txt 2>&1

# Los ULog pueden ser grandes: se incluyen solo si ocupan menos de 50 MB en total
ULOG_MB=$(du -cm logs/*.ulg 2>/dev/null | tail -1 | cut -f1)
if [ "${ULOG_MB:-0}" -gt 50 ]; then
    echo "Los ULog ocupan ${ULOG_MB} MB: se excluyen del paquete (envíamelos aparte si te los pido)"
    tar czf "${OUT}" --exclude='*.ulg' logs
else
    tar czf "${OUT}" logs
fi

echo "Paquete listo: ${OUT} ($(du -h "${OUT}" | cut -f1))"
echo "Adjúntalo en el chat."
