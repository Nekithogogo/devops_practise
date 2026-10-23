#!/usr/bin/env bash
# Доставка статического ресурса на devops-vm
# Использование: scripts/deploy.sh [--dry-run]
set -euo pipefail

REMOTE="devops"                          # псевдоним из ~/.ssh/config (ПР № 5, шаг 1.6)
REMOTE_DIR="/var/www/devops-site"
SITE_URL="https://devops.local"
CA_CERT="${HOME}/devops.crt"
# Если имя devops.local не прописано в hosts, адрес можно передать явно: DEVOPS_IP=192.168.56.101
RESOLVE=(${DEVOPS_IP:+--resolve "devops.local:443:${DEVOPS_IP}"})
REPO_ROOT="$(git rev-parse --show-toplevel)"
LOCAL_DIR="${REPO_ROOT}/site/"

die() { echo "deploy: $*" >&2; exit 1; }

# 1. Разбор аргумента --dry-run
DRY_RUN=""
case "${1:-}" in
    "")        ;;
    --dry-run) DRY_RUN="--dry-run" ;;
    *)         die "неизвестный аргумент '$1'. Использование: $0 [--dry-run]" ;;
esac

# 2. Проверки по требованиям 4 и 5
[[ -f "${LOCAL_DIR}index.html" ]] || die "нет файла site/index.html — доставка отменена (иначе --delete удалит главную страницу)"

cd "$REPO_ROOT"
if ! git diff --quiet || ! git diff --cached --quiet \
   || [[ -n "$(git ls-files --others --exclude-standard -- site/)" ]]; then
    git status --short >&2
    die "есть незафиксированные изменения — зафиксируйте их коммитом перед доставкой"
fi
COMMIT="$(git rev-parse --short HEAD)"

# 3. Синхронизация: одно SSH-соединение, без интерактивного запроса пароля
echo "Доставка ${COMMIT}: ${LOCAL_DIR} -> ${REMOTE}:${REMOTE_DIR}/ ${DRY_RUN}"
rsync -avz --delete --chmod=D755,F644 ${DRY_RUN} \
    -e "ssh -o BatchMode=yes -o ConnectTimeout=5" \
    "$LOCAL_DIR" "${REMOTE}:${REMOTE_DIR}/" \
    || die "rsync завершился с ошибкой"

# 4. При --dry-run — завершение без проверки доступности
if [[ -n "$DRY_RUN" ]]; then
    echo "Пробный запуск: состояние сервера не изменено"
    exit 0
fi

# 5. Проверка доступности с проверкой сертификата (без -k)
curl -fsS --max-time 5 --cacert "$CA_CERT" "${RESOLVE[@]}" -o /dev/null "$SITE_URL/" \
    || die "ресурс ${SITE_URL} недоступен после доставки"

echo "Доставлен коммит ${COMMIT}"
