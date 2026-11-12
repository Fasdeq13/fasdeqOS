#!/bin/bash
set -euo pipefail

if [ "${FASDEQ_INNER:-0}" != 1 ]; then
    [ "$(id -u)" = 0 ] || exec sudo -E bash "$(readlink -f "$0")" "$@"
    command -v podman >/dev/null || { echo "podman не найден"; exit 1; }
    SELF=$(readlink -f "$0")
    OUTDIR=${OUTDIR:-$PWD}
    WORK=$(mktemp -d /var/tmp/fasdeqos.XXXXXX)
    IMG=docker.io/library/ubuntu:24.04
    HAD=0
    podman image exists "$IMG" && HAD=1
    cleanup() {
        podman rm -f fasdeqos-build >/dev/null 2>&1 || true
        [ "$HAD" = 1 ] || podman rmi -f "$IMG" >/dev/null 2>&1 || true
        rm -rf "$WORK"
    }
    trap cleanup EXIT
    echo "Сборка идёт во временном контейнере, зависимости на хосте не ставятся"
    echo "Нужно около 15 ГБ свободного места в /var/tmp и 1-2 часа"
    podman run --name fasdeqos-build --privileged --security-opt label=disable \
        -v /dev:/dev -v "$WORK":/work -v "$OUTDIR":/out -v "$SELF":/fasdeqos.sh:ro \
        -e FASDEQ_INNER=1 -e SELFTEST="${SELFTEST:-}" -e COMP="${COMP:-}" \
        "$IMG" bash /fasdeqos.sh
    [ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER" "$OUTDIR"/FasdeqOS-*.iso* 2>/dev/null || true
    echo
    echo "Готово: $(ls "$OUTDIR"/FasdeqOS-*.iso | head -1)"
    echo "Контейнер, образ и рабочая папка удалены, на хосте ничего не осталось"
    echo
    echo "Запись на флешку: sudo dd if=FasdeqOS-0.2-x86_64.iso of=/dev/sdX bs=4M status=progress oflag=sync"
    echo "Проверка в виртуалке: загрузка с ISO, BIOS или UEFI, вход выполняется сам"
    exit 0
fi
