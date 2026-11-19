#!/bin/bash
# Personal installation launcher. Never format disks or create a fallback store.
set -euo pipefail
USB='/Volumes/USB'
IMAGE="$USB/M_H/Jarvis/JARVISStorage.sparsebundle"
MOUNT='/Volumes/JARVISData'
USB_UUID='8FAFC431-A23F-3295-AEC8-958B8DF60FBC'
DATA_UUID='FCFEB613-D061-4178-AC9B-9422B413AD3A'
MODE="${1:---app}"
case "$MODE" in --app|--project|--ios|--storage|--check) ;; *) printf '지원하지 않는 실행 옵션입니다.\n' >&2; exit 2 ;; esac
volume_uuid() { /usr/sbin/diskutil info -plist "$1" | /usr/bin/plutil -extract VolumeUUID raw -o - -; }
if [[ "$(volume_uuid "$USB" 2>/dev/null || true)" != "$USB_UUID" || ! -d "$IMAGE" ]]; then
    printf 'JARVIS USB를 연결해주세요. 로컬에 대체 저장소를 만들지 않습니다.\n' >&2
    exit 1
fi
if ! /usr/sbin/diskutil info "$MOUNT" >/dev/null 2>&1; then
    /usr/bin/hdiutil attach "$IMAGE" -nobrowse -owners on -mountpoint "$MOUNT"
fi
if [[ "$(volume_uuid "$MOUNT" 2>/dev/null || true)" != "$DATA_UUID" || ! -f "$MOUNT/Project/Package.swift" ]]; then
    printf 'JARVIS 저장 공간 식별자 또는 프로젝트를 확인하지 못했습니다.\n' >&2
    exit 1
fi
case "$MODE" in
    --check) printf 'JARVIS USB 저장 공간 확인 완료: %s\n' "$MOUNT" ;;
    --app) /usr/bin/open "$MOUNT/Applications/JARVIS.app" ;;
    --project) /usr/bin/open "$MOUNT/Project/JarvisMac/JarvisMac.xcodeproj" ;;
    --ios) /usr/bin/open "$MOUNT/Project/Jarvis.xcodeproj" ;;
    --storage) /usr/bin/open "$MOUNT" ;;
esac
