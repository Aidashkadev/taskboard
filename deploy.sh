
set -eu

# ---------------------------- Параметры --------------------------------------
APP_NAME="taskboard"
REPOSITORY_URL="${REPOSITORY_URL:-https://github.com/Aidashkadev/taskboard.git}"
APP_HOST="0.0.0.0"
APP_PORT="${APP_PORT:-8000}"

DB_HOST="localhost"
DB_PORT="5432"
DB_NAME="taskboard"
DB_USER="taskboard"
DB_PASSWORD="taskboard"

# Если deploy.sh лежит внутри репозитория (сценарий проверки преподавателем),
# используем эту папку. Иначе код будет клонирован в ./taskboard.
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
if [ -f "$SCRIPT_DIR/requirements.txt" ] && [ -d "$SCRIPT_DIR/app" ]; then
    APP_DIR="$SCRIPT_DIR"
else
    APP_DIR="${APP_DIR:-$PWD/$APP_NAME}"
fi

VENV_DIR="$APP_DIR/.venv"
PID_FILE="$APP_DIR/.app.pid"
LOG_FILE="$APP_DIR/app.log"
APP_URL="http://localhost:$APP_PORT"
HEALTH_URL="$APP_URL/api/health"
DATABASE_URL="postgresql+psycopg://$DB_USER:$DB_PASSWORD@$DB_HOST:$DB_PORT/$DB_NAME"

# ---------------------------- Вспомогательные функции -------------------------
info() { printf '[INFO]  %s\n' "$*"; }
ok()   { printf '[OK]    %s\n' "$*"; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

# При любой неожиданной ошибке (set -e) выводим понятное сообщение
on_exit() {
    code=$?
    if [ "$code" -ne 0 ]; then
        printf '[ERROR] Развертывание не завершено (код возврата: %s).\n' "$code" >&2
    fi
}
trap on_exit EXIT

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# sudo нужен только если мы не root
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    has_cmd sudo || die "Нужны права администратора, но sudo не найден."
    SUDO="sudo"
fi

# ---------------------------- Шаг 1. Системные пакеты -------------------------
detect_pkg_manager() {
    if has_cmd apt-get; then echo apt
    elif has_cmd dnf; then echo dnf
    elif has_cmd yum; then echo yum
    else echo unknown
    fi
}

pg_installed() {
    ls /usr/lib/postgresql/*/bin/postgres >/dev/null 2>&1 || has_cmd postgres
}

install_system_packages() {
    info "Шаг 1/7: проверка системных программ"
    PKG=$(detect_pkg_manager)
    MISSING=""

    has_cmd git     || MISSING="$MISSING git"
    has_cmd curl    || MISSING="$MISSING curl"
    has_cmd python3 || MISSING="$MISSING python3"

    if has_cmd python3; then
        python3 -m pip --version >/dev/null 2>&1 || MISSING="$MISSING pip"
        python3 -c 'import venv, ensurepip' >/dev/null 2>&1 || MISSING="$MISSING venv"
    else
        MISSING="$MISSING pip venv"
    fi
    pg_installed || MISSING="$MISSING postgresql"

    if [ -z "$MISSING" ]; then
        ok "Все необходимые программы уже установлены"
        return 0
    fi

    info "Не хватает:$MISSING — устанавливаю через $PKG"
    case "$PKG" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            # Сторонние репозитории могут давать ошибку при update — это не критично
            $SUDO apt-get update -y || info "apt-get update завершился с предупреждением, продолжаю"
            $SUDO apt-get install -y git curl python3 python3-pip python3-venv \
                postgresql postgresql-contrib \
                || die "Не удалось установить пакеты через apt-get"
            ;;
        dnf|yum)
            $SUDO "$PKG" install -y git curl python3 python3-pip \
                postgresql-server postgresql-contrib \
                || die "Не удалось установить пакеты через $PKG"
            ;;
        *)
            die "Неизвестный менеджер пакетов. Установите вручную:$MISSING"
            ;;
    esac
    ok "Системные программы установлены"
}

# ---------------------------- Шаг 2. Исходный код -----------------------------
get_source_code() {
    info "Шаг 2/7: получение исходного кода"
    if [ -d "$APP_DIR/.git" ] || [ -f "$APP_DIR/requirements.txt" ]; then
        ok "Репозиторий уже существует: $APP_DIR (клонирование пропущено)"
    else
        git clone "$REPOSITORY_URL" "$APP_DIR" \
            || die "Не удалось клонировать $REPOSITORY_URL"
        ok "Репозиторий склонирован в $APP_DIR"
    fi
    [ -f "$APP_DIR/requirements.txt" ] || die "В $APP_DIR нет requirements.txt"
}

# ---------------------------- Шаг 3. Виртуальное окружение --------------------
create_venv() {
    info "Шаг 3/7: виртуальное окружение"
    if [ -x "$VENV_DIR/bin/python" ]; then
        ok "Виртуальное окружение уже существует: $VENV_DIR"
    else
        python3 -m venv "$VENV_DIR" || die "Не удалось создать виртуальное окружение"
        ok "Создано виртуальное окружение: $VENV_DIR"
    fi
}

# ---------------------------- Шаг 4. Python-зависимости -----------------------
install_python_deps() {
    info "Шаг 4/7: установка Python-зависимостей"
    "$VENV_DIR/bin/python" -m pip install --quiet --upgrade pip \
        || die "Не удалось обновить pip в виртуальном окружении"
    "$VENV_DIR/bin/python" -m pip install --quiet -r "$APP_DIR/requirements.txt" \
        || die "Не удалось установить зависимости из requirements.txt"
    ok "Зависимости установлены"
}

# ---------------------------- Шаг 5. PostgreSQL -------------------------------
# Запуск psql от имени системного пользователя postgres
pg_admin() {
    if [ "$(id -u)" -eq 0 ]; then
        (cd / && runuser -u postgres -- psql -v ON_ERROR_STOP=1 "$@")
    else
        (cd / && sudo -u postgres psql -v ON_ERROR_STOP=1 "$@")
    fi
}

start_postgres() {
    # Fedora/RHEL: кластер нужно инициализировать при первом запуске
    if [ "$PKG" != "apt" ] && [ ! -f /var/lib/pgsql/data/PG_VERSION ] && has_cmd postgresql-setup; then
        info "Инициализация кластера PostgreSQL"
        $SUDO postgresql-setup --initdb || die "Не удалось инициализировать PostgreSQL"
    fi

    if [ -d /run/systemd/system ] && has_cmd systemctl; then
        $SUDO systemctl enable --now postgresql || die "Не удалось запустить сервис postgresql"
    else
        $SUDO service postgresql start || die "Не удалось запустить сервис postgresql"
    fi

    # Ждём, пока сервер начнёт принимать подключения
    i=0
    while [ "$i" -lt 30 ]; do
        if pg_admin -tAc "SELECT 1" >/dev/null 2>&1; then
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    die "PostgreSQL не отвечает после запуска"
}

setup_database() {
    info "Шаг 5/7: подготовка PostgreSQL"
    start_postgres
    ok "Сервис PostgreSQL запущен"

    # Пользователь: создаём, если нет; иначе просто обновляем пароль
    if [ "$(pg_admin -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'")" = "1" ]; then
        pg_admin -c "ALTER USER $DB_USER WITH PASSWORD '$DB_PASSWORD'" >/dev/null \
            || die "Не удалось обновить пароль пользователя $DB_USER"
        ok "Пользователь $DB_USER уже существует"
    else
        pg_admin -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASSWORD'" >/dev/null \
            || die "Не удалось создать пользователя $DB_USER"
        ok "Создан пользователь $DB_USER"
    fi

    # База данных: владельцем делаем нашего пользователя (нужно для PostgreSQL 15+)
    if [ "$(pg_admin -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")" = "1" ]; then
        pg_admin -c "ALTER DATABASE $DB_NAME OWNER TO $DB_USER" >/dev/null \
            || die "Не удалось назначить владельца базы $DB_NAME"
        ok "База данных $DB_NAME уже существует"
    else
        pg_admin -c "CREATE DATABASE $DB_NAME OWNER $DB_USER" >/dev/null \
            || die "Не удалось создать базу данных $DB_NAME"
        ok "Создана база данных $DB_NAME"
    fi

    # Проверяем, что приложение сможет подключиться с этими учётными данными
    PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
        -tAc "SELECT 1" >/dev/null 2>&1 \
        || die "Не удаётся подключиться к базе $DB_NAME под пользователем $DB_USER"
    ok "Подключение к базе данных работает"
}

# ---------------------------- Шаг 6. Запуск приложения ------------------------
stop_old_instance() {
    if [ -f "$PID_FILE" ]; then
        OLD_PID=$(cat "$PID_FILE")
        if kill -0 "$OLD_PID" 2>/dev/null; then
            info "Останавливаю предыдущий запуск (PID $OLD_PID)"
            kill "$OLD_PID" 2>/dev/null || true
            sleep 1
        fi
        rm -f "$PID_FILE"
    fi
}

start_app() {
    info "Шаг 6/7: запуск приложения"
    stop_old_instance
    cd "$APP_DIR"
    DATABASE_URL="$DATABASE_URL" nohup "$VENV_DIR/bin/uvicorn" app.main:app \
        --host "$APP_HOST" --port "$APP_PORT" >"$LOG_FILE" 2>&1 &
    APP_PID=$!
    echo "$APP_PID" >"$PID_FILE"
    ok "Uvicorn запущен (PID $APP_PID), лог: $LOG_FILE"
}

# ---------------------------- Шаг 7. Проверка --------------------------------
check_health() {
    info "Шаг 7/7: проверка healthcheck ($HEALTH_URL)"
    i=0
    while [ "$i" -lt 30 ]; do
        if ! kill -0 "$APP_PID" 2>/dev/null; then
            tail -n 20 "$LOG_FILE" >&2 || true
            die "Приложение завершилось с ошибкой сразу после запуска (см. $LOG_FILE)"
        fi
        if curl -fsS "$HEALTH_URL" >/dev/null 2>&1; then
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    tail -n 20 "$LOG_FILE" >&2 || true
    die "Healthcheck не прошёл за 30 секунд: $HEALTH_URL"
}

# ---------------------------- Основной сценарий -------------------------------
install_system_packages
get_source_code
create_venv
install_python_deps
setup_database
start_app
check_health

echo
echo "Application deployed successfully."
echo "Application is available at: $APP_URL"
echo "Swagger API: $APP_URL/docs"
echo "Healthcheck: $HEALTH_URL"
echo "Остановить приложение: kill \$(cat $PID_FILE)"
