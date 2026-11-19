#!/usr/bin/env bash
# build_opticraft.sh — самостоятельная сборка OptiCraft под Linux.
#
# Положите этот скрипт в папку с исходниками OptiCraft (рядом с CMakeLists.txt)
# и запустите:  ./build_opticraft.sh
#
# Что делает:
#   1. Ищет в системе компилятор C++, CMake, make/ninja, unzip, X11, GLFW и GLM.
#      Недостающее ставит через пакетный менеджер (apt, dnf, pacman, zypper).
#      Если пакетного менеджера нет, скачивает CMake, GLFW и GLM из интернета.
#   2. Собирает игру в Release с -march=native под этот процессор.
#   3. Кладёт исполняемый файл OptiCraft в эту же папку (папка assets остаётся).
#   4. Удаляет остальные исходники и сам скрипт.
#
# Опции:
#   --no-system-packages  не ставить пакеты системой, скачивать из интернета
#   --keep-sources        не удалять исходники и скрипт (для отладки)

set -euo pipefail
shopt -s nullglob dotglob

NO_PKG=0
KEEP=0

step() { printf '\n==> %s\n' "$*"; }
die()  { printf '\nОШИБКА: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --no-system-packages)  NO_PKG=1 ;;
        --keep-sources)        KEEP=1 ;;
        *) die "неизвестная опция: $1" ;;
    esac
    shift
done

[ "$(uname -s)" = "Linux" ] || die "этот скрипт только для Linux"
case "$(uname -m)" in
    x86_64|amd64) ;;
    *) die "поддерживается только x86_64" ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"
SRC="$HERE"
[ -f "$SRC/CMakeLists.txt" ] && [ -d "$SRC/src" ] && [ -d "$SRC/assets" ] \
    || die "скрипт нужно положить в папку с исходниками OptiCraft (рядом должны быть CMakeLists.txt, src и assets)"

GLFW_ZIP_URL="https://github.com/glfw/glfw/releases/download/3.4/glfw-3.4.zip"
GLM_ZIP_URL="https://github.com/g-truc/glm/releases/download/1.0.1/glm-1.0.1-light.zip"
CMAKE_TGZ_URL="https://github.com/Kitware/CMake/releases/download/v3.31.6/cmake-3.31.6-linux-x86_64.tar.gz"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------- утилиты ----------
fetch() {  # fetch URL FILE: скачивает с 3 попытками
    local url=$1 out=$2 i
    for i in 1 2 3; do
        if have curl; then
            curl -fsSL --retry 2 -o "$out" "$url" && return 0
        elif have wget; then
            wget -q -O "$out" "$url" && return 0
        else
            die "нужен curl или wget для скачивания"
        fi
        sleep 3
    done
    die "не удалось скачать $url"
}

unzip_to() {  # unzip_to ZIP DIR
    mkdir -p "$2"
    if have unzip; then
        unzip -q "$1" -d "$2"
    elif have python3; then
        python3 -m zipfile -e "$1" "$2"
    else
        die "нужен unzip или python3 для распаковки"
    fi
}

# ---------- пакетный менеджер ----------
PM=""
for c in apt-get dnf pacman zypper; do
    if have "$c"; then PM=$c; break; fi
done

SUDO=""
if [ "$(id -u)" -ne 0 ] && have sudo; then SUDO=sudo; fi

pkg_install() {
    [ "$NO_PKG" -eq 0 ] || return 1
    [ -n "$PM" ] || return 1
    if [ "$(id -u)" -ne 0 ] && [ -z "$SUDO" ]; then return 1; fi
    case "$PM" in
        apt-get)
            $SUDO apt-get update -qq
            $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
                build-essential cmake ninja-build pkg-config unzip curl ca-certificates \
                libgl-dev libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev \
                libglfw3-dev libglm-dev
            ;;
        dnf)
            $SUDO dnf install -y gcc-c++ make cmake ninja-build pkgconf-pkg-config unzip curl \
                mesa-libGL-devel libX11-devel libXrandr-devel libXinerama-devel \
                libXcursor-devel libXi-devel glfw-devel glm-devel
            ;;
        pacman)
            $SUDO pacman -S --noconfirm --needed base-devel cmake ninja pkgconf unzip curl \
                mesa libx11 libxrandr libxinerama libxcursor libxi glfw glm
            ;;
        zypper)
            $SUDO zypper --non-interactive install gcc-c++ make cmake ninja pkg-config unzip curl \
                Mesa-libGL-devel libX11-devel libXrandr-devel libXinerama-devel \
                libXcursor-devel libXi-devel glfw-devel glm-devel
            ;;
    esac
}

# ---------- проверки наличия ----------
cmake_ok() {
    have cmake || return 1
    local v
    v="$(cmake --version | awk 'NR==1{print $3}')"
    [ "$(printf '%s\n' 3.16 "$v" | sort -V | head -n1)" = "3.16" ]
}
have_compiler() { have g++ || have clang++; }
have_x11() {
    [ -f /usr/include/X11/Xlib.h ] \
        && [ -f /usr/include/X11/extensions/Xrandr.h ] \
        && [ -f /usr/include/X11/extensions/Xinerama.h ] \
        && [ -f /usr/include/X11/Xcursor/Xcursor.h ] \
        && [ -f /usr/include/X11/extensions/XInput2.h ]
}
have_glfw() {
    { have pkg-config && pkg-config --exists glfw3; } \
        || [ -f /usr/lib/x86_64-linux-gnu/cmake/glfw3/glfw3Config.cmake ] \
        || [ -f /usr/lib64/cmake/glfw3/glfw3Config.cmake ] \
        || [ -f /usr/local/lib/cmake/glfw3/glfw3Config.cmake ]
}
have_glm() { [ -f /usr/include/glm/glm.hpp ] || [ -f /usr/local/include/glm/glm.hpp ]; }

check_all() {
    MISSING=()
    have_compiler || MISSING+=("компилятор C++")
    cmake_ok      || MISSING+=("CMake 3.16+")
    { have ninja || have make; } || MISSING+=("ninja или make")
    have unzip    || MISSING+=("unzip")
    have_x11      || MISSING+=("заголовки X11")
    have_glfw     || MISSING+=("GLFW")
    have_glm      || MISSING+=("GLM")
}

step "Поиск инструментов и библиотек в системе"
check_all
if [ "${#MISSING[@]}" -gt 0 ]; then
    echo "Не найдено: ${MISSING[*]}"
    if pkg_install; then
        echo "Пакеты установлены через $PM"
    else
        echo "Пакетный менеджер недоступен, будет скачано из интернета там, где возможно"
    fi
    check_all
fi
for item in "${MISSING[@]:-}"; do
    [ -n "$item" ] && echo "  всё ещё не найдено: $item"
done

# Из интернета нельзя получить компилятор и заголовки X11
have_compiler || die "нет компилятора C++. Установите g++ (например: sudo apt install build-essential)"
have_x11      || die "нет заголовков X11. Установите libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev"
{ have ninja || have make; } || die "нет make или ninja. Установите make (например: sudo apt install build-essential)"

# ---------- скачивание недостающего ----------
if ! cmake_ok; then
    step "Скачивание CMake"
    fetch "$CMAKE_TGZ_URL" "$WORK/cmake.tgz"
    mkdir -p "$WORK/cmake"
    tar -xzf "$WORK/cmake.tgz" -C "$WORK/cmake" --strip-components=1
    PATH="$WORK/cmake/bin:$PATH"
fi

PREFIX="$WORK/prefix"
if ! have_glm; then
    step "Скачивание GLM 1.0.1"
    fetch "$GLM_ZIP_URL" "$WORK/glm.zip"
    unzip_to "$WORK/glm.zip" "$WORK/glm-src"
    export CPLUS_INCLUDE_PATH="$WORK/glm-src${CPLUS_INCLUDE_PATH:+:$CPLUS_INCLUDE_PATH}"
fi

if ! have_glfw; then
    step "Скачивание и сборка GLFW 3.4 (статически)"
    fetch "$GLFW_ZIP_URL" "$WORK/glfw.zip"
    unzip_to "$WORK/glfw.zip" "$WORK/glfw-src"
    GLFW_SRC="$(find "$WORK/glfw-src" -maxdepth 2 -name CMakeLists.txt -printf '%h\n' | head -n1)"
    [ -n "$GLFW_SRC" ] || die "в архиве GLFW не найден CMakeLists.txt"
    GEN=()
    have ninja && GEN=(-G Ninja)
    cmake -S "$GLFW_SRC" -B "$WORK/glfw-build" ${GEN[@]+"${GEN[@]}"} \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
        -DGLFW_BUILD_EXAMPLES=OFF -DGLFW_BUILD_TESTS=OFF -DGLFW_BUILD_DOCS=OFF \
        -DGLFW_BUILD_WAYLAND=OFF \
        -DCMAKE_INSTALL_PREFIX="$PREFIX"
    cmake --build "$WORK/glfw-build" --parallel "$(nproc)"
    cmake --install "$WORK/glfw-build"
    export CMAKE_PREFIX_PATH="$PREFIX${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
fi

# ---------- сборка OptiCraft ----------
step "Сборка OptiCraft (Release, -march=native под этот процессор)"
GEN=()
have ninja && GEN=(-G Ninja)
BUILD="$WORK/build"
cmake -S "$SRC" -B "$BUILD" ${GEN[@]+"${GEN[@]}"} \
    -DCMAKE_BUILD_TYPE=Release -DOPTICRAFT_NATIVE_ARCH=ON -DOPTICRAFT_TRACY=OFF
cmake --build "$BUILD" --target OptiCraft --parallel "$(nproc)"

BIN="$BUILD/OptiCraft"
[ -x "$BIN" ] || die "OptiCraft не собран"
if ldd "$BIN" | grep -q 'not found'; then
    ldd "$BIN" | grep 'not found' >&2
    die "у собранного файла не хватает библиотек"
fi

# ---------- результат ----------
step "Сохранение результата в $SRC"
cp -f "$BIN" "$SRC/OptiCraft"
chmod +x "$SRC/OptiCraft"

if [ "$KEEP" -eq 0 ]; then
    step "Удаление исходников и скрипта"
    for entry in "$SRC"/*; do
        case "$(basename "$entry")" in
            OptiCraft|assets) continue ;;
        esac
        rm -rf -- "$entry"
    done
    rm -f -- "$SELF"
fi

echo
echo "Готово: $SRC/OptiCraft"
echo "Запуск: cd \"$SRC\" && ./OptiCraft"
