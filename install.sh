#!/bin/sh
# llama.cpp auto installer: detects OS, CPU arch and GPU, then installs the matching build.
#
#   curl -fsSL https://github.com/__REPO__/releases/latest/download/install.sh | sh
#
# Env overrides:
#   LLAMA_REPO      GitHub repo that hosts the builds      (default: __REPO__)
#   LLAMA_VERSION   release tag, e.g. b6000 / v1.0         (default: latest)
#   LLAMA_VARIANT   force: cpu | vulkan | cuda12 | rocm | metal | opencl
#   LLAMA_DIR       install dir                             (default: ~/.local/llama)
#   LLAMA_BIN       dir for command symlinks                (default: ~/.local/bin, Termux: $PREFIX/bin)
#   GH_PROXY        prefix for GitHub downloads, e.g. a mirror
set -eu

REPO="${LLAMA_REPO:-FgsiDev/llama.cpp-bin}"
VERSION="${LLAMA_VERSION:-latest}"
FORCE="${LLAMA_VARIANT:-}"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------- downloader ----------
if have curl; then
  fetch()  { curl -fL --retry 3 --progress-bar -o "$2" "$1"; }
  exists() { curl -fsIL -o /dev/null "$1"; }
elif have wget; then
  fetch()  { wget -q --show-progress -O "$2" "$1"; }
  exists() { wget -q --spider "$1"; }
else
  die "need curl or wget"
fi

# ---------- OS / arch ----------
UNAME_S=$(uname -s)
UNAME_M=$(uname -m)
OS=""
if [ -n "${TERMUX_VERSION:-}" ] || [ -d /data/data/com.termux ] || [ "$(uname -o 2>/dev/null)" = "Android" ]; then
  OS=android
elif [ "$UNAME_S" = "Linux" ]; then
  OS=linux
elif [ "$UNAME_S" = "Darwin" ]; then
  OS=macos
else
  die "unsupported OS: $UNAME_S (Windows: download the .zip from the release page)"
fi

case "$UNAME_M" in
  x86_64|amd64)          ARCH=x86_64 ;;
  aarch64|arm64|armv8*)  ARCH=aarch64 ;;
  armv7*|armv8l|armhf)   ARCH=armv7 ;;
  *) die "unsupported CPU: $UNAME_M" ;;
esac
# 32-bit userland on a 64-bit kernel (common on Android/Termux)
if [ "$ARCH" = "aarch64" ] && have getconf && [ "$(getconf LONG_BIT 2>/dev/null)" = "32" ]; then
  ARCH=armv7
fi

# ---------- GPU detection ----------
detect_variants() {
  # prints candidate variants, best first (installer falls back down the list)
  if [ -n "$FORCE" ]; then echo "$FORCE cpu"; return; fi
  case "$OS" in
    macos)
      if [ "$ARCH" = "aarch64" ]; then echo "metal"; else echo "cpu"; fi ;;
    android)
      # Adreno OpenCL is experimental, only used when asked: LLAMA_VARIANT=opencl
      echo "cpu" ;;
    linux)
      out=""
      if [ "$ARCH" = "x86_64" ]; then
        if have nvidia-smi && nvidia-smi -L 2>/dev/null | grep -q GPU; then
          out="$out cuda12"
        elif [ -e /dev/nvidiactl ]; then
          out="$out cuda12"
        fi
        if [ -d /opt/rocm ] || have rocminfo; then
          if have rocminfo && rocminfo 2>/dev/null | grep -q gfx; then out="$out rocm"; fi
        fi
      fi
      if [ "$ARCH" = "x86_64" ] || [ "$ARCH" = "aarch64" ]; then
        if have vulkaninfo && vulkaninfo --summary 2>/dev/null | grep -q 'deviceName'; then
          out="$out vulkan"
        elif ls /usr/share/vulkan/icd.d/*.json /etc/vulkan/icd.d/*.json >/dev/null 2>&1; then
          out="$out vulkan"
        elif have lspci && lspci 2>/dev/null | grep -Eiq 'vga|3d|display'; then
          # a GPU exists but no Vulkan driver seen: still try the Vulkan build, it falls back to CPU
          if ! lspci 2>/dev/null | grep -Eiq 'vga.*(vmware|virtualbox|qxl|cirrus|bochs)'; then out="$out vulkan"; fi
        fi
      fi
      echo "$out cpu" ;;
  esac
}

# ---------- install locations ----------
if [ "$OS" = "android" ] && [ -n "${PREFIX:-}" ]; then
  DEFAULT_BIN="$PREFIX/bin"
else
  DEFAULT_BIN="$HOME/.local/bin"
fi
DIR="${LLAMA_DIR:-$HOME/.local/llama}"
BINDIR="${LLAMA_BIN:-$DEFAULT_BIN}"
mkdir -p "$DIR" "$BINDIR"

base_url() {
  if [ "$VERSION" = "latest" ]; then
    echo "https://github.com/$REPO/releases/latest/download"
  else
    echo "https://github.com/$REPO/releases/download/$VERSION"
  fi
}
BASE="${GH_PROXY:-}$(base_url)"

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t llama)
trap 'rm -rf "$TMP"' EXIT INT TERM

say "Detected: os=$OS arch=$ARCH"
CANDIDATES=$(detect_variants)
say "Candidate builds (best first):$(printf ' %s' $CANDIDATES)"

CHOSEN=""
EXT=tar.gz
for v in $CANDIDATES; do
  asset="llama-$v-$OS-$ARCH.$EXT"
  if exists "$BASE/$asset"; then
    say "Downloading $asset"
    if fetch "$BASE/$asset" "$TMP/$asset"; then CHOSEN="$v"; PKG="$TMP/$asset"; break; fi
  else
    warn "$asset not published, trying next"
  fi
done
[ -n "$CHOSEN" ] || die "no matching build found in $REPO ($VERSION) for $OS/$ARCH"

# checksum (best effort)
if exists "$BASE/SHA256SUMS.txt" && fetch "$BASE/SHA256SUMS.txt" "$TMP/SHA256SUMS.txt" 2>/dev/null; then
  want=$(grep " $(basename "$PKG")\$" "$TMP/SHA256SUMS.txt" | awk '{print $1}' || true)
  if [ -n "$want" ]; then
    if have sha256sum; then got=$(sha256sum "$PKG" | awk '{print $1}')
    elif have shasum;  then got=$(shasum -a 256 "$PKG" | awk '{print $1}')
    else got=""; fi
    if [ -n "$got" ] && [ "$got" != "$want" ]; then die "checksum mismatch for $(basename "$PKG")"; fi
    [ -n "$got" ] && say "Checksum OK"
  fi
fi

# ---------- unpack ----------
say "Installing to $DIR/current"
rm -rf "$DIR/current.new"
mkdir -p "$DIR/current.new"
tar -xzf "$PKG" -C "$DIR/current.new" --strip-components=1
rm -rf "$DIR/current"
mv "$DIR/current.new" "$DIR/current"
echo "$CHOSEN" > "$DIR/current/.variant"

# CUDA runtime (only if the machine has no CUDA 12 libs)
if [ "$CHOSEN" = "cuda12" ]; then
  if ! ldconfig -p 2>/dev/null | grep -q 'libcublas\.so\.12'; then
    say "CUDA 12 runtime libs not found, downloading them"
    rt="cudart-cuda12-linux-x86_64.tar.gz"
    if fetch "$BASE/$rt" "$TMP/$rt"; then
      tar -xzf "$TMP/$rt" -C "$DIR/current" --strip-components=1
    else
      warn "could not fetch $rt, install the CUDA 12 toolkit or use LLAMA_VARIANT=vulkan"
    fi
  fi
fi

# ---------- commands ----------
for f in "$DIR"/current/llama-*; do
  [ -f "$f" ] && [ -x "$f" ] || continue
  case "$f" in *.so|*.dll|*.dylib) continue ;; esac
  ln -sf "$f" "$BINDIR/$(basename "$f")"
done

# llama-auto: runs a llama tool with GPU offload only when a GPU build is installed
cat > "$DIR/llama-auto" <<'EOF'
#!/bin/sh
# usage: llama-auto <cli|server|bench|...> [args]   e.g. llama-auto server -hf unsloth/Qwen3-4B-GGUF
D="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)/current"
V="$(cat "$D/.variant" 2>/dev/null || echo cpu)"
tool="$1"; shift
case "$tool" in llama-*) ;; *) tool="llama-$tool" ;; esac
gpu=""
case "$V" in cpu) ;; *) gpu=1 ;; esac
for a in "$@"; do case "$a" in -ngl|--n-gpu-layers|--gpu-layers|--device) gpu="" ;; esac; done
if [ -n "$gpu" ]; then exec "$D/$tool" -ngl 99 "$@"; else exec "$D/$tool" "$@"; fi
EOF
chmod +x "$DIR/llama-auto"
ln -sf "$DIR/llama-auto" "$BINDIR/llama-auto"

# llama-get: download GGUF models from Hugging Face (or any mirror / direct URL)
cat > "$DIR/llama-get" <<'EOF'
#!/bin/sh
# usage: llama-get <hf-repo[:quant]> [file-substring]   -> saved in ${LLAMA_MODELS:-~/models}
#        llama-get https://host/path/model.gguf
# env:   HF_TOKEN (private/gated repos), HF_ENDPOINT (mirror, default https://huggingface.co),
#        LLAMA_MODELS (output dir)
set -eu
HF="${HF_ENDPOINT:-https://huggingface.co}"
OUT="${LLAMA_MODELS:-$HOME/models}"
[ $# -ge 1 ] || { sed -n '2,6p' "$0"; exit 1; }
mkdir -p "$OUT"
AUTH=""
[ -n "${HF_TOKEN:-}" ] && AUTH="Authorization: Bearer $HF_TOKEN"
get() { # url dest
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$AUTH" ]; then curl -fL -C - --retry 5 --progress-bar -H "$AUTH" -o "$2" "$1"
    else curl -fL -C - --retry 5 --progress-bar -o "$2" "$1"; fi
  else
    if [ -n "$AUTH" ]; then wget -c -q --show-progress --header="$AUTH" -O "$2" "$1"
    else wget -c -q --show-progress -O "$2" "$1"; fi
  fi
}
case "$1" in
  http://*|https://*)
    f="$OUT/$(basename "${1%%\?*}")"; echo "-> $f"; get "$1" "$f"; echo "$f"; exit 0 ;;
esac
spec="$1"; repo="${spec%%:*}"; want="${2:-}"
[ "$repo" != "$spec" ] && want="${spec#*:}"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
get "$HF/api/models/$repo" "$tmp" >/dev/null 2>&1 || { echo "cannot read repo '$repo' (private? set HF_TOKEN)"; exit 1; }
files="$(grep -o '"rfilename":"[^"]*\.gguf"' "$tmp" | sed 's/"rfilename":"//;s/"$//' | grep -vi 'mmproj' || true)"
[ -n "$files" ] || { echo "no .gguf files in $repo"; exit 1; }
if [ -n "$want" ]; then
  pick="$(printf '%s\n' "$files" | grep -i -- "$want" || true)"
else
  pick="$(printf '%s\n' "$files" | grep -i 'Q4_K_M' || true)"
  [ -n "$pick" ] || pick="$(printf '%s\n' "$files" | head -n1)"
fi
[ -n "$pick" ] || { echo "no file matches '$want'. Available:"; printf '%s\n' "$files"; exit 1; }
# split models (-00001-of-0000N) are downloaded in full
printf '%s\n' "$pick" | while IFS= read -r p; do
  d="$OUT/$(basename "$p")"; echo "-> $d"; get "$HF/$repo/resolve/main/$p" "$d"
done
EOF
chmod +x "$DIR/llama-get"
ln -sf "$DIR/llama-get" "$BINDIR/llama-get"

# ---------- done ----------
case ":$PATH:" in *":$BINDIR:"*) ;; *) warn "add to PATH:  export PATH=\"$BINDIR:\$PATH\"" ;; esac
say "Installed variant: $CHOSEN"
echo
echo "  llama-get unsloth/Qwen3-4B-GGUF                 # download a model from HF"
echo "  llama-auto cli -m ~/models/<model>.gguf -p hi   # CPU or GPU, automatically"
echo "  llama-auto server -hf unsloth/Qwen3-4B-GGUF     # or let llama.cpp pull from HF itself"
