#!/bin/bash

# ======================================================================
# WP-CLI скрипт для резервного копирования и восстановления WordPress
# ======================================================================
# Автор: wpadmin
# Версия: 1.0
# Описание: Этот скрипт выполняет полное резервное копирование WordPress
#           сайта (файлы и база данных) и предоставляет инструменты для
#           восстановления из резервной копии при необходимости.
# ======================================================================

# Определяем цвета для вывода информации
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функция вывода информации
info() {
    echo -e "${BLUE}[ИНФО]${NC} $1"
}

# Функция вывода сообщений об успехе
success() {
    echo -e "${GREEN}[УСПЕХ]${NC} $1"
}

# Функция вывода предупреждений
warning() {
    echo -e "${YELLOW}[ПРЕДУПРЕЖДЕНИЕ]${NC} $1"
}

# Функция вывода ошибок
error() {
    echo -e "${RED}[ОШИБКА]${NC} $1"
}

# Функция проверки наличия необходимых инструментов
check_requirements() {
    info "Проверка наличия необходимых инструментов..."
    
    # Проверяем наличие wp-cli
    if ! command -v wp &> /dev/null; then
        error "WP-CLI не установлен. Установите его, следуя инструкциям на https://wp-cli.org/"
        exit 1
    fi
    
    # Проверяем наличие tar
    if ! command -v tar &> /dev/null; then
        error "tar не установлен. Установите его с помощью вашего пакетного менеджера."
        exit 1
    fi
    
    # Проверяем наличие gzip
    if ! command -v gzip &> /dev/null; then
        error "gzip не установлен. Установите его с помощью вашего пакетного менеджера."
        exit 1
    fi
    
    success "Все необходимые инструменты установлены."
}

# Функция проверки окружения WordPress
check_wordpress() {
    info "Проверка окружения WordPress..."
    
    # Проверяем, что мы находимся в корневой директории WordPress
    if ! wp core is-installed --quiet; then
        error "WordPress не установлен или скрипт запущен не из корневой директории WordPress."
        exit 1
    fi
    
    success "WordPress установлен и доступен."
}

# Функция создания резервной копии
create_backup() {
    local backup_dir="$1"
    local include_uploads="$2"
    
    # Создаем директорию для резервных копий, если она не существует
    if [ ! -d "$backup_dir" ]; then
        mkdir -p "$backup_dir"
        info "Создана директория для резервных копий: $backup_dir"
    fi
    
    # Генерируем имя файла резервной копии с текущей датой и временем
    local date_time=$(date +"%Y-%m-%d_%H-%M-%S")
    local backup_name="wp_backup_${date_time}"
    local backup_path="${backup_dir}/${backup_name}"
    
    # Создаем директорию для текущей резервной копии
    mkdir -p "$backup_path"
    
    info "Начало процесса резервного копирования..."
    
    # Получение информации о сайте для дополнительного файла информации
    local site_url=$(wp option get siteurl)
    local wp_version=$(wp core version)
    
    # Сохраняем информацию о бэкапе в текстовый файл
    {
        echo "Резервная копия WordPress"
        echo "Дата создания: $(date)"
        echo "URL сайта: $site_url"
        echo "Версия WordPress: $wp_version"
        echo "Включены загружаемые файлы: $include_uploads"
        echo "Плагины:"
        wp plugin list --format=csv | awk -F',' '{print $1 " (версия: " $2 ", статус: " $3 ")"}'
        echo "Темы:"
        wp theme list --format=csv | awk -F',' '{print $1 " (версия: " $2 ", статус: " $3 ")"}'
    } > "${backup_path}/backup_info.txt"
    
    # Экспортируем базу данных
    info "Экспорт базы данных..."
    if wp db export "${backup_path}/database.sql" --add-drop-table; then
        success "База данных успешно экспортирована."
    else
        error "Ошибка при экспорте базы данных."
        return 1
    fi
    
    # Создаем список файлов для исключения из резервной копии
    local exclude_list="${backup_path}/exclude.txt"
    {
        echo "wp-content/backup*"
        echo "wp-content/cache"
        echo "wp-content/upgrade"
        echo "wp-content/debug.log"
        echo ".git"
        echo "*.tar.gz"
        echo "*.zip"
        echo "*.log"
        
        # Исключаем загружаемые файлы, если указано
        if [ "$include_uploads" = "no" ]; then
            echo "wp-content/uploads"
        fi
    } > "$exclude_list"
    
    # Архивируем файлы WordPress
    info "Архивирование файлов WordPress..."
    if tar -czf "${backup_path}/wp-files.tar.gz" --exclude-from="$exclude_list" .; then
        success "Файлы WordPress успешно архивированы."
    else
        error "Ошибка при архивировании файлов WordPress."
        return 1
    fi
    
    # Создаем итоговый архив, который включает все файлы резервной копии
    info "Создание итогового архива резервной копии..."
    if tar -czf "${backup_dir}/${backup_name}.tar.gz" -C "$backup_dir" "$backup_name"; then
        success "Резервная копия успешно создана: ${backup_dir}/${backup_name}.tar.gz"
        
        # Очищаем временные файлы
        rm -rf "$backup_path"
        
        # Выводим информацию о резервной копии
        echo ""
        echo "Информация о резервной копии:"
        echo "- Имя файла: ${backup_name}.tar.gz"
        echo "- Путь: ${backup_dir}/${backup_name}.tar.gz"
        echo "- Размер: $(du -h "${backup_dir}/${backup_name}.tar.gz" | cut -f1)"
        echo "- Создан: $(date)"
        echo ""
        
        return 0
    else
        error "Ошибка при создании итогового архива резервной копии."
        return 1
    fi
}

# Функция восстановления из резервной копии
restore_backup() {
    local backup_file="$1"
    
    if [ ! -f "$backup_file" ]; then
        error "Файл резервной копии не найден: $backup_file"
        return 1
    fi
    
    # Проверяем, что файл резервной копии является tar.gz архивом
    if [[ "$backup_file" != *.tar.gz ]]; then
        error "Файл резервной копии должен быть в формате tar.gz."
        return 1
    fi
    
    info "Начало процесса восстановления из резервной копии: $backup_file"
    
    # Создаем временную директорию для распаковки архива
    local temp_dir="/tmp/wp_restore_$(date +%s)"
    mkdir -p "$temp_dir"
    
    # Распаковываем архив
    info "Распаковка архива резервной копии..."
    if tar -xzf "$backup_file" -C "$temp_dir"; then
        success "Архив успешно распакован."
    else
        error "Ошибка при распаковке архива."
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Находим распакованную директорию
    local backup_dir=$(find "$temp_dir" -type d -name "wp_backup_*" | head -n 1)
    
    if [ -z "$backup_dir" ]; then
        error "Не удалось найти директорию с распакованной резервной копией."
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Проверяем наличие необходимых файлов в резервной копии
    if [ ! -f "${backup_dir}/database.sql" ] || [ ! -f "${backup_dir}/wp-files.tar.gz" ]; then
        error "Резервная копия повреждена или имеет неверный формат."
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Просим подтверждение перед восстановлением
    echo ""
    warning "ВНИМАНИЕ! Процесс восстановления перезапишет текущую базу данных и файлы WordPress."
    warning "Убедитесь, что у вас есть резервная копия текущего состояния перед продолжением."
    echo ""
    read -p "Вы уверены, что хотите продолжить? (y/n): " confirm
    
    if [[ "$confirm" != [Yy]* ]]; then
        info "Восстановление отменено."
        rm -rf "$temp_dir"
        return 0
    fi
    
    # Восстанавливаем базу данных
    info "Восстановление базы данных..."
    if wp db import "${backup_dir}/database.sql"; then
        success "База данных успешно восстановлена."
    else
        error "Ошибка при восстановлении базы данных."
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Восстанавливаем файлы WordPress
    info "Восстановление файлов WordPress..."
    if tar -xzf "${backup_dir}/wp-files.tar.gz" -C .; then
        success "Файлы WordPress успешно восстановлены."
    else
        error "Ошибка при восстановлении файлов WordPress."
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Очищаем кэш WordPress
    info "Очистка кэша WordPress..."
    wp cache flush --quiet
    
    # Обновляем URL-ы в базе данных, если это необходимо
    info "Проверка URL-ов сайта..."
    local current_url=$(wp option get siteurl)
    echo "Текущий URL сайта: $current_url"
    
    read -p "Нужно ли обновить URL сайта? (y/n): " update_url
    
    if [[ "$update_url" == [Yy]* ]]; then
        read -p "Введите новый URL сайта: " new_url
        
        if [ -n "$new_url" ]; then
            info "Обновление URL-ов сайта..."
            
            # Обновляем URL сайта
            wp option update siteurl "$new_url"
            wp option update home "$new_url"
            
            # Обновляем URL-ы в контенте
            wp search-replace "$current_url" "$new_url" --all-tables --skip-columns=guid
            
            success "URL-ы сайта успешно обновлены на: $new_url"
        fi
    fi
    
    # Очищаем временные файлы
    rm -rf "$temp_dir"
    
    # Выводим информацию о завершении восстановления
    echo ""
    success "Восстановление из резервной копии успешно завершено!"
    echo ""
    
    return 0
}

# Функция для вывода списка доступных резервных копий
list_backups() {
    local backup_dir="$1"
    
    if [ ! -d "$backup_dir" ]; then
        error "Директория для резервных копий не существует: $backup_dir"
        return 1
    fi
    
    echo ""
    info "Доступные резервные копии в директории: $backup_dir"
    echo ""
    
    local count=0
    local backups=()
    
    # Перебираем все файлы tar.gz в директории резервных копий
    while IFS= read -r backup_file; do
        # Проверяем, что имя файла соответствует шаблону имени резервной копии
        if [[ "$(basename "$backup_file")" =~ ^wp_backup_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}\.tar\.gz$ ]]; then
            count=$((count + 1))
            backups+=("$backup_file")
            
            # Извлекаем дату из имени файла
            local file_name=$(basename "$backup_file")
            local date_part=${file_name#wp_backup_}
            date_part=${date_part%.tar.gz}
            date_part=${date_part//_/ }
            
            # Получаем размер файла
            local file_size=$(du -h "$backup_file" | cut -f1)
            
            echo "$count. $file_name"
            echo "   - Дата создания: $date_part"
            echo "   - Размер: $file_size"
            echo "   - Путь: $backup_file"
            echo ""
        fi
    done < <(find "$backup_dir" -type f -name "wp_backup_*.tar.gz" | sort -r)
    
    if [ "$count" -eq 0 ]; then
        warning "Резервных копий не найдено в указанной директории."
        return 0
    fi
    
    return 0
}

# Основная функция для обработки команд
main() {
    local command="$1"
    shift
    
    case "$command" in
        backup)
            local backup_dir="./wp-content/backups"
            local include_uploads="yes"
            
            # Обрабатываем дополнительные параметры
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --dir=*)
                        backup_dir="${1#*=}"
                        shift
                        ;;
                    --no-uploads)
                        include_uploads="no"
                        shift
                        ;;
                    *)
                        error "Неизвестный параметр: $1"
                        return 1
                        ;;
                esac
            done
            
            check_requirements
            check_wordpress
            create_backup "$backup_dir" "$include_uploads"
            ;;
            
        restore)
            local backup_file=""
            
            # Обрабатываем дополнительные параметры
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --file=*)
                        backup_file="${1#*=}"
                        shift
                        ;;
                    *)
                        backup_file="$1"
                        shift
                        ;;
                esac
            done
            
            if [ -z "$backup_file" ]; then
                error "Не указан файл резервной копии для восстановления."
                echo "Использование: $0 restore --file=/путь/к/файлу.tar.gz"
                return 1
            fi
            
            check_requirements
            check_wordpress
            restore_backup "$backup_file"
            ;;
            
        list)
            local backup_dir="./wp-content/backups"
            
            # Обрабатываем дополнительные параметры
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --dir=*)
                        backup_dir="${1#*=}"
                        shift
                        ;;
                    *)
                        error "Неизвестный параметр: $1"
                        return 1
                        ;;
                esac
            done
            
            list_backups "$backup_dir"
            ;;
            
        help|--help|-h)
            echo "WordPress Backup & Restore - скрипт для резервного копирования и восстановления WordPress"
            echo ""
            echo "Использование:"
            echo "  $0 backup [опции]        - Создать резервную копию"
            echo "  $0 restore --file=ФАЙЛ   - Восстановить из резервной копии"
            echo "  $0 list [опции]          - Вывести список доступных резервных копий"
            echo "  $0 help                  - Вывести эту справку"
            echo ""
            echo "Опции для backup:"
            echo "  --dir=ДИРЕКТОРИЯ         - Директория для сохранения резервной копии (по умолчанию: ./wp-content/backups)"
            echo "  --no-uploads             - Исключить директорию uploads из резервной копии"
            echo ""
            echo "Опции для list:"
            echo "  --dir=ДИРЕКТОРИЯ         - Директория с резервными копиями (по умолчанию: ./wp-content/backups)"
            echo ""
            echo "Примеры:"
            echo "  $0 backup                - Создать полную резервную копию"
            echo "  $0 backup --dir=/path/to/backups --no-uploads - Создать резервную копию без uploads в указанной директории"
            echo "  $0 restore --file=/path/to/backups/wp_backup_2023-10-15_12-30-00.tar.gz - Восстановить из указанного файла"
            echo "  $0 list --dir=/path/to/backups - Вывести список резервных копий в указанной директории"
            ;;
            
        *)
            error "Неизвестная команда: $command"
            echo "Используйте '$0 help' для просмотра доступных команд."
            return 1
            ;;
    esac
}

# Если скрипт запущен без аргументов, показываем справку
if [ $# -eq 0 ]; then
    main help
    exit 0
fi

# Вызываем основную функцию с переданными аргументами
main "$@"
exit $?
