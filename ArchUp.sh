#!/usr/bin/env bash
# ArchUp: backup, restore and audit helper for Arch Linux.
# Backups are read from the live system; restore overwrites matching paths.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly APP_NAME='ArchUp'
readonly LOG_LIMIT=1048576
readonly LOG_KEEP=524288
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly BACKUP_LOG="$SCRIPT_DIR/archup_backup.log"
readonly RESTORE_LOG="$SCRIPT_DIR/archup_restore.log"
readonly ENV_FILE="$SCRIPT_DIR/.env"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
TARGET_DEVICE_LABEL=''; MOUNT_POINT='/mnt/arch'; HASH_SECRET_KEY=''
DEVICE=''; MOUNTED_BY_US=0

fnc_logger_rotate() {
    local file=$1 size tmp
    [[ -f $file ]] || return 0
    size=$(stat -c '%s' -- "$file") || return 1
    (( size < LOG_LIMIT )) && return 0
    tmp=$(mktemp "${file}.rotate.XXXXXX") || return 1
    # Keep roughly the newest 500 KiB, dropping a possibly partial first line.
    tail -c "$LOG_KEEP" -- "$file" | sed '1d' > "$tmp"
    cat -- "$tmp" > "$file"
    rm -f -- "$tmp"
    printf '[%s] [ALERT] [Rotação automática: log reduzido de %s para aproximadamente %s bytes.]\n' \
        "$(date '+%F %T')" "$size" "$LOG_KEEP" >> "$file"
}

fnc_log() {
    local file=$1 level=$2 message=$3
    fnc_logger_rotate "$file"
    printf '[%s] [%s] [%s]\n' "$(date '+%F %T')" "$level" "$message" >> "$file"
}

fnc_error_trap() {
    local rc=$? line=${BASH_LINENO[0]:-?}
    fnc_log "$RESTORE_LOG" ERROR "Falha inesperada (código $rc, linha $line)." || true
    printf '\n%sErro inesperado (código %s, linha %s). Consulte %s.%s\n' "$RED" "$rc" "$line" "$RESTORE_LOG" "$RESET" >&2
    exit "$rc"
}
trap fnc_error_trap ERR

fnc_banner() {
    clear 2>/dev/null || true
    printf '%s╭──────────────────────────────────────────────────╮%s\n' "$CYAN" "$RESET"
    printf '%s│%s        _    ____   ____ _   _   _   _ ____       %s│%s\n' "$CYAN" "$RESET" "$CYAN" "$RESET"
    printf '%s│%s       / \  |  _ \ / ___| | | | | | | |  _ \      %s│%s\n' "$CYAN" "$RESET" "$CYAN" "$RESET"
    printf '%s│%s      / _ \ | |_) | |   | |_| | | | | | |_) |     %s│%s\n' "$CYAN" "$RESET" "$CYAN" "$RESET"
    printf '%s│%s     / ___ \|  _ <| |___|  _  | | |_| |  __/      %s│%s\n' "$CYAN" "$RESET" "$CYAN" "$RESET"
    printf '%s│%s    /_/   \_\_| \_\\___ _|_| |_|  \___/|_|         %s│%s\n' "$CYAN" "$RESET" "$CYAN" "$RESET"
    printf '%s│%s                                             	   %s│%s\n' "$CYAN" "$RESET" "$CYAN" "$RESET"
    printf '%s│%s     Bem-vindo ao Arch-Up — @Alyton Cogo    	   %s│%s\n' "$CYAN" "$RESET" "$CYAN" "$RESET"
    printf '%s╰──────────────────────────────────────────────────╯%s\n\n' "$CYAN" "$RESET"
}

fnc_load_env() {
    local line key value
    [[ -r $ENV_FILE ]] || { printf '%sArquivo de configuração ausente: %s%s\n' "$RED" "$ENV_FILE" "$RESET"; return 1; }
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%%#*}; [[ $line =~ ^[[:space:]]*$ ]] && continue
        [[ $line == *=* ]] || { printf 'Linha inválida no .env.\n' >&2; return 1; }
        key=${line%%=*}; value=${line#*=}
        key=${key//[[:space:]]/}; value=${value#"${value%%[![:space:]]*}"}; value=${value%"${value##*[![:space:]]}"}
        if [[ ${#value} -ge 2 && ( ${value:0:1} == '"' || ${value:0:1} == "'" ) ]]; then value=${value:1:${#value}-2}; fi
        case $key in
            TARGET_DEVICE_LABEL) TARGET_DEVICE_LABEL=$value ;;
            MOUNT_POINT) MOUNT_POINT=$value ;;
            HASH_SECRET_KEY) HASH_SECRET_KEY=$value ;;
            *) printf 'Variável não reconhecida no .env: %s\n' "$key" >&2; return 1 ;;
        esac
    done < "$ENV_FILE"
    [[ -n $TARGET_DEVICE_LABEL && -n $MOUNT_POINT && -n $HASH_SECRET_KEY ]] || { printf '%sPreencha TARGET_DEVICE_LABEL, MOUNT_POINT e HASH_SECRET_KEY em .env.%s\n' "$RED" "$RESET"; return 1; }
    [[ $HASH_SECRET_KEY != 'SUA_CHAVE_SECRETA_AQUI' && ${#HASH_SECRET_KEY} -ge 16 ]] || { printf '%sHASH_SECRET_KEY precisa ser uma chave própria com pelo menos 16 caracteres.%s\n' "$RED" "$RESET"; return 1; }
    [[ $MOUNT_POINT == /* && $MOUNT_POINT != / ]] || { printf 'MOUNT_POINT deve ser um caminho absoluto diferente de /.\n' >&2; return 1; }
}

fnc_check_deps() {
    local cmd missing=()
    for cmd in pv zstd openssl lsblk findmnt findfs mount umount df tar sha256sum awk sort stat numfmt du find realpath readlink cmp sed tail mktemp chmod pacman ldconfig; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if ((${#missing[@]})); then
        printf '%sDependências ausentes: %s. Instale-as com pacman antes de continuar.%s\n' "$RED" "${missing[*]}" "$RESET"
        return 1
    fi
}

fnc_check_device() {
    local row
    DEVICE=''
    if [[ $TARGET_DEVICE_LABEL == UUID=* ]]; then
        row=$(findfs "$TARGET_DEVICE_LABEL" 2>/dev/null || true)
    else
        row=$(findfs "LABEL=$TARGET_DEVICE_LABEL" 2>/dev/null || true)
        [[ -n $row ]] || row=$(findfs "UUID=$TARGET_DEVICE_LABEL" 2>/dev/null || true)
    fi
    DEVICE=$row
    if [[ -z $DEVICE || ! -b $DEVICE ]]; then
        fnc_log "$BACKUP_LOG" ERROR "Dispositivo com LABEL/UUID '$TARGET_DEVICE_LABEL' não encontrado."
        printf '%sDispositivo LABEL/UUID "%s" não encontrado.%s\n' "$RED" "$TARGET_DEVICE_LABEL" "$RESET"
        return 1
    fi
    mkdir -p -- "$MOUNT_POINT"
    if findmnt -rn --mountpoint "$MOUNT_POINT" >/dev/null 2>&1; then
        local current
        current=$(findmnt -rn -o SOURCE --target "$MOUNT_POINT")
        [[ $(readlink -f -- "$current") == $(readlink -f -- "$DEVICE") ]] || { printf '%sO ponto de montagem já está ocupado por outro dispositivo.%s\n' "$RED" "$RESET"; return 1; }
    else
        if ! mount "$DEVICE" "$MOUNT_POINT"; then
            fnc_log "$BACKUP_LOG" ERROR "Falha ao montar $DEVICE em $MOUNT_POINT."
            printf '%sFalha ao montar o dispositivo em %s.%s\n' "$RED" "$MOUNT_POINT" "$RESET"
            return 1
        fi
        MOUNTED_BY_US=1
    fi
    [[ -w $MOUNT_POINT ]] || { printf '%sO dispositivo montado não permite gravação.%s\n' "$RED" "$RESET"; return 1; }
}

fnc_unmount_if_needed() {
    if (( MOUNTED_BY_US )); then umount -- "$MOUNT_POINT" || fnc_log "$RESTORE_LOG" WARN "Não foi possível desmontar $MOUNT_POINT."; MOUNTED_BY_US=0; fi
}
trap fnc_unmount_if_needed EXIT

fnc_mount_or_return() { fnc_check_device; }

fnc_alert() {
    printf '\n%s╔══════════════════════════════════════════════════════════╗\n║ ALERTA URGENTE: integridade não confirmada               ║\n║ Não restaure este backup. Isole o dispositivo, preserve   ║\n║ uma cópia para análise e investigue corrupção/adulteração.║\n╚══════════════════════════════════════════════════════════╝%s\n\n' "$RED" "$RESET"
}

fnc_hmac_file() {
    local archive=$1 output=$2 digest
    digest=$(sha256sum -- "$archive" | awk '{print $1}')
    printf '%s' "$digest" | openssl dgst -sha256 -hmac "$HASH_SECRET_KEY" -binary > "$output"
}

fnc_verify_signature() {
    local archive=$1 signature="$1.hmac" tmp
    [[ -f $archive && -f $signature ]] || return 1
    tmp=$(mktemp)
    fnc_hmac_file "$archive" "$tmp"
    if cmp -s -- "$tmp" "$signature"; then rm -f -- "$tmp"; return 0; fi
    rm -f -- "$tmp"; return 1
}

fnc_backups() { find "$MOUNT_POINT" -maxdepth 1 -type f -name 'archup_*.tar.zst' -printf '%T@|%p\n' | sort -t '|' -k1,1nr | cut -d '|' -f2-; }

fnc_created_at() {
    local file=$1 epoch
    epoch=$(stat -c %W -- "$file")
    # Filesystems without a birth time report 0; use mtime and label it as a fallback.
    (( epoch > 0 )) || epoch=$(stat -c %Y -- "$file")
    date -d "@$epoch" '+%F %T'
}

fnc_create_backup() {
    local estimate free timestamp archive part signature count old
    fnc_mount_or_return || return 1
    estimate=$(du -sx --one-file-system --block-size=1 --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run --exclude=/tmp --exclude=/mnt --exclude=/media --exclude=/lost+found --exclude=/var/cache/pacman/pkg / 2>/dev/null | awk '{print $1}')
    free=$(df -P -B1 "$MOUNT_POINT" | awk 'NR==2 {print $4}')
    [[ $estimate =~ ^[0-9]+$ && $free =~ ^[0-9]+$ ]] || { printf '%sNão foi possível estimar espaço disponível/necessário.%s\n' "$RED" "$RESET"; return 1; }
    if (( free < estimate + estimate / 20 )); then
        fnc_log "$BACKUP_LOG" ERROR "Espaço insuficiente: estimado ${estimate}B, livre ${free}B."
        printf '%sEspaço insuficiente. Estimativa conservadora: %s; livre: %s (inclui margem de 5%%).%s\n' "$RED" "$(numfmt --to=iec --suffix=B "$estimate")" "$(numfmt --to=iec --suffix=B "$free")" "$RESET"
        return 1
    fi
    timestamp=$(date '+%Y%m%d_%H%M%S')
    archive="$MOUNT_POINT/archup_${timestamp}.tar.zst"; part="$archive.part"; signature="$archive.hmac"
    printf '%sCriando backup. Os caminhos são exibidos conforme o tar os processa.%s\n' "$CYAN" "$RESET"
    fnc_log "$BACKUP_LOG" INFO "Início do backup $archive (estimativa ${estimate} bytes)."
    set +e
    tar --create --file=- --directory=/ --one-file-system --numeric-owner --acls --xattrs --sparse --verbose \
        --exclude='./proc' --exclude='./sys' --exclude='./dev' --exclude='./run' --exclude='./tmp' \
        --exclude='./mnt' --exclude='./media' --exclude='./lost+found' --exclude='./var/cache/pacman/pkg' . \
        2> >(tee /dev/tty >&2) | pv --size "$estimate" --timer --eta --rate --bytes | zstd -T0 -3 -o "$part"
    local status=(${PIPESTATUS[@]})
    set -e
    if (( status[0] != 0 || status[1] != 0 || status[2] != 0 )); then
        rm -f -- "$part"; fnc_log "$BACKUP_LOG" ERROR "Criação do backup falhou (tar/pv/zstd: ${status[*]})."; return 1
    fi
    mv -- "$part" "$archive"
    if ! fnc_hmac_file "$archive" "$signature"; then rm -f -- "$archive" "$signature"; fnc_log "$BACKUP_LOG" ERROR 'Falha ao assinar backup.'; return 1; fi
    chmod 600 -- "$archive" "$signature"
    mapfile -t old < <(fnc_backups)
    count=0
    for old_archive in "${old[@]}"; do
        ((count+=1))
        if (( count > 2 )); then rm -f -- "$old_archive" "$old_archive.hmac"; fi
    done
    fnc_log "$BACKUP_LOG" INFO "Backup concluído: $archive; HMAC-SHA256 validado ao gravar."
    printf '\n%sBackup criado: %s%s\n' "$GREEN" "${archive##*/}" "$RESET"
}

fnc_list_backups() {
    local file n=0 size when
    mapfile -t BACKUPS < <(fnc_backups)
    if ((${#BACKUPS[@]} == 0)); then printf 'Nenhum backup encontrado.\n'; return 1; fi
    printf '\n#  Arquivo                                      Data/hora             Tamanho\n'
    for file in "${BACKUPS[@]}"; do
        ((n+=1)); size=$(du -h -- "$file" | awk '{print $1}'); when=$(fnc_created_at "$file")
        printf '%-3s%-45s %-20s %s\n' "$n" "${file##*/}" "$when" "$size"
    done
}

fnc_restore() {
    local choice target archive
    fnc_mount_or_return || return 1
    fnc_list_backups || return 0
    printf 'Selecione o número do snapshot: '; read -r choice
    [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#BACKUPS[@]} )) || { printf 'Seleção inválida.\n'; return 1; }
    archive=${BACKUPS[choice-1]}
    if ! fnc_verify_signature "$archive"; then fnc_log "$RESTORE_LOG" ALERT "HMAC inválido/ausente: $archive"; fnc_alert; return 1; fi
    printf '\n%sA restauração sobrescreve arquivos existentes no destino e não remove arquivos extras.%s\n' "$YELLOW" "$RESET"
    printf 'Destino (diretório já existente; padrão /): '; read -r target
    target=${target:-/}; [[ -d $target ]] || { printf 'O destino precisa ser um diretório existente.\n'; return 1; }
    target=$(realpath -- "$target")
    [[ $target != "$MOUNT_POINT" && $target != "$MOUNT_POINT"/* ]] || { printf 'O destino não pode ser o dispositivo de backup.\n'; return 1; }
    printf 'Para confirmar, digite RESTORE: '; read -r choice
    [[ $choice == RESTORE ]] || { printf 'Restauração cancelada.\n'; return 0; }
    fnc_log "$RESTORE_LOG" INFO "Restauração de $archive para $target iniciada."
    local total; total=$(stat -c %s -- "$archive")
    if ! zstd -dc -- "$archive" | pv --size "$total" --timer --eta --rate --bytes | tar --extract --file=- --directory="$target" --numeric-owner --same-owner --acls --xattrs --verbose; then
        fnc_log "$RESTORE_LOG" ERROR "Restauração falhou: $archive"; return 1
    fi
    fnc_log "$RESTORE_LOG" INFO "Restauração concluída: $archive para $target."
    printf '\n%sRestauração concluída em %s.%s\n' "$GREEN" "$target" "$RESET"
}

fnc_verify() {
    local archive total bad=0
    fnc_mount_or_return || return 1
    mapfile -t BACKUPS < <(fnc_backups)
    if ((${#BACKUPS[@]} == 0)); then printf 'Nenhum backup encontrado.\n'; return 0; fi
    for archive in "${BACKUPS[@]}"; do
        printf '\nVerificando %s\n' "${archive##*/}"; total=$(stat -c %s -- "$archive")
        if ! fnc_verify_signature "$archive"; then printf '%sHMAC ausente ou inválido.%s\n' "$RED" "$RESET"; fnc_log "$RESTORE_LOG" ALERT "HMAC inválido/ausente: $archive"; bad=1; continue; fi
        if ! zstd -t -- "$archive" 2>/dev/null; then printf '%sArquivo zstd corrompido.%s\n' "$RED" "$RESET"; fnc_log "$RESTORE_LOG" ALERT "Teste zstd falhou: $archive"; bad=1; continue; fi
        if ! zstd -dc -- "$archive" | pv --size "$total" --timer --eta --rate --bytes | tar --list --file=- >/dev/null; then
            printf '%sEstrutura tar inválida.%s\n' "$RED" "$RESET"; fnc_log "$RESTORE_LOG" ALERT "Teste tar falhou: $archive"; bad=1
        else printf '%sIntegridade confirmada: assinatura, compressão e estrutura tar.%s\n' "$GREEN" "$RESET"; fnc_log "$RESTORE_LOG" INFO "Integridade confirmada: $archive"; fi
    done
    if (( bad )); then fnc_alert; return 1; fi
}

fnc_libs() {
    local output="$MOUNT_POINT/libs.txt" tmp size
    fnc_mount_or_return || return 1
    tmp=$(mktemp "$MOUNT_POINT/.libs.XXXXXX")
    { printf '# Gerado em %s\n\n# Todos os pacotes instalados (pacman -Q)\n' "$(date '+%F %T')"; pacman -Q; printf '\n# Pacotes explicitamente instalados (pacman -Qqe)\n'; pacman -Qqe; printf '\n# Bibliotecas compartilhadas (ldconfig -p)\n'; ldconfig -p; } > "$tmp"
    size=$(stat -c %s -- "$tmp")
    pv --size "$size" --timer --eta --rate --bytes "$tmp" > "$output"
    rm -f -- "$tmp"; chmod 600 -- "$output"
    fnc_log "$RESTORE_LOG" INFO "Inventário atualizado em $output."
    printf '%sInventário salvo em %s%s\n' "$GREEN" "$output" "$RESET"
}

fnc_storage() {
    fnc_mount_or_return || return 1
    local file size when absolute
    printf '\n%-42s %-12s %-20s %s\n' 'Nome do arquivo' 'Tamanho' 'Data de criação*' 'Caminho absoluto'
    printf '%s\n' '────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────'
    while IFS= read -r -d '' file; do
        size=$(du -h -- "$file" | awk '{print $1}'); when=$(fnc_created_at "$file"); absolute=$(realpath -- "$file")
        printf '%-42s %-12s %-20s %s\n' "${file##*/}" "$size" "$when" "$absolute"
    done < <(find "$MOUNT_POINT" -maxdepth 1 -type f \( -name 'archup_*' -o -name 'libs.txt' \) -print0 | sort -z)
    printf '%s\n' '────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────'
    df -hP "$MOUNT_POINT" | awk 'NR==2 {printf "Total: %s | Usado: %s | Livre: %s | Ocupação: %s\n",$2,$3,$4,$5}'
    printf '*Data de criação quando o sistema de arquivos informa esse dado; caso contrário, data de modificação.\n'
}

fnc_menu() {
    local option
    while true; do
        fnc_banner
        printf '%s1)%s Criar Backup\n%s2)%s Recuperação\n%s3)%s Verificar Integridade\n%s4)%s Consultar Bibliotecas\n%s5)%s Armazenamento\n%s6)%s Sair\n\n' \
            "$BOLD" "$RESET" "$BOLD" "$RESET" "$BOLD" "$RESET" "$BOLD" "$RESET" "$BOLD" "$RESET" "$BOLD" "$RESET"
        printf 'Escolha uma opção: '; read -r option || break
        case $option in
            1) fnc_create_backup || true ;;
            2) fnc_restore || true ;;
            3) fnc_verify || true ;;
            4) fnc_libs || true ;;
            5) fnc_storage || true ;;
            6) printf 'Até logo.\n'; return 0 ;;
            *) printf 'Opção inválida.\n' ;;
        esac
        printf '\nPressione Enter para voltar ao menu...'; read -r _ || true
    done
}

main() {
    if (( EUID != 0 )); then printf '%sExecute com sudo: sudo %s%s\n' "$YELLOW" "${BASH_SOURCE[0]}" "$RESET"; exit 1; fi
    if ! fnc_check_deps; then exit 1; fi
    if ! fnc_load_env; then exit 1; fi
    fnc_menu
}
main "$@"
