#!/bin/bash
# Personal APFS installation. Never format, mount an image, or create a fallback store.
set -euo pipefail
VOLUME='/Volumes/JARVIS'
MOUNT='/Volumes/JARVIS/Jarvis'
DATA_UUID='8B1F8F32-6526-49B0-8C21-9C472EB5D8E8'
MODE="${1:---app}"
case "$MODE" in --app|--project|--ios|--storage|--check) ;; *) printf '지원하지 않는 실행 옵션입니다.\n' >&2; exit 2 ;; esac
volume_uuid() { /usr/sbin/diskutil info -plist "$1" | /usr/bin/plutil -extract VolumeUUID raw -o - -; }
if [[ "$(volume_uuid "$VOLUME" 2>/dev/null || true)" != "$DATA_UUID" || ! -d "$MOUNT" || -L "$MOUNT" || ! -f "$MOUNT/Project/Package.swift" ]]; then
    printf 'JARVIS APFS 저장 공간과 Jarvis 폴더를 확인해주세요. 로컬에 대체 저장소를 만들지 않습니다.\n' >&2
    exit 1
fi
case "$MODE" in
    --check) printf 'JARVIS APFS 저장 공간 확인 완료: %s\n' "$MOUNT" ;;
    --app) /usr/bin/open "$MOUNT/Applications/JARVIS.app" ;;
    --project) /usr/bin/open "$MOUNT/Project/JarvisMac/JarvisMac.xcodeproj" ;;
    --ios) /usr/bin/open "$MOUNT/Project/Jarvis.xcodeproj" ;;
    --storage) /usr/bin/open "$MOUNT" ;;
esac
