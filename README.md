# llama.cpp auto-build

Build otomatis [llama.cpp](https://github.com/ggml-org/llama.cpp) lewat GitHub Actions untuk semua device (VPS, PC, Raspberry Pi, Mac, Windows, Termux/Android). Installer mendeteksi hardware dan memilih build yang cocok sendiri: CPU kalau tidak ada GPU, GPU kalau ada.

## Install (satu baris)

Linux, Termux, macOS:

```sh
curl -fsSL https://raw.githubusercontent.com/FgsiDev/llama.cpp-bin/main/install.sh | sh
```

Windows: download zip `llama-cpu-windows-x86_64` atau `llama-vulkan-windows-x86_64` dari halaman Releases.

Setelah selesai tersedia command `llama-cli`, `llama-server`, `llama-bench`, dst, plus dua helper: `llama-auto` dan `llama-get`.

## Deteksi hardware otomatis

| Kondisi device | Build yang dipilih |
|---|---|
| Termux / Android 64-bit (arm64) | `cpu-android-aarch64` |
| Termux / Android 32-bit | `cpu-android-armv7` (best effort) |
| Android Snapdragon (Adreno) | `opencl-android-aarch64`, eksperimental, hanya dengan `LLAMA_VARIANT=opencl` |
| Linux dengan GPU NVIDIA (`nvidia-smi`) | `cuda12-linux-x86_64`, runtime CUDA diunduh otomatis bila belum ada |
| Linux dengan GPU AMD + ROCm | `rocm-linux-x86_64` (eksperimental) |
| Linux dengan GPU lain / driver Vulkan (Intel, AMD, NVIDIA, ARM Mali) | `vulkan-linux-<arch>` |
| Linux tanpa GPU (VPS biasa) | `cpu-linux-<arch>` |
| Raspberry Pi 32-bit | `cpu-linux-armv7` |
| Mac Apple Silicon | `metal-macos-aarch64` |
| Mac Intel | `cpu-macos-x86_64` |

Urutan fallback: kalau paket terbaik tidak ada di release, installer turun ke berikutnya sampai `cpu`.

Di dalam setiap paket (Linux, Android, Windows) backend GPU dan varian CPU (AVX2, AVX512, NEON, SVE, dst) dimuat dinamis saat runtime (`GGML_BACKEND_DL`). Jadi satu paket tetap jalan di CPU lama maupun baru, dan kalau driver GPU tidak ada, llama.cpp otomatis memakai CPU.

**TPU:** llama.cpp tidak punya backend Google TPU. VM TPU tetap bisa menjalankan paket CPU. NPU lain seperti Ascend CANN, Hexagon, dan OpenVINO tidak dibuild di sini karena butuh SDK khusus.

## Model dari Hugging Face (atau dari mana saja)

Build memakai TLS, jadi llama.cpp bisa mengunduh model sendiri:

```sh
# langsung dari HF, otomatis di-cache
llama-auto server -hf unsloth/Qwen3-4B-GGUF
llama-auto cli    -hf unsloth/Qwen3-4B-GGUF:Q4_K_M -p "halo"

# repo private / gated
export HF_TOKEN=hf_xxx
llama-auto server -hf org/private-model-GGUF

# mirror HF (mis. jaringan yang memblokir huggingface.co)
export HF_ENDPOINT=https://hf-mirror.com

# URL langsung (server mana pun)
llama-auto server -mu https://example.com/path/model.gguf
```

Helper `llama-get` mengunduh file GGUF ke `~/models` (bisa resume), berguna untuk build tanpa TLS (armv7 / fallback) atau untuk menyimpan model sendiri:

```sh
llama-get unsloth/Qwen3-4B-GGUF                 # pilih Q4_K_M otomatis
llama-get unsloth/Qwen3-4B-GGUF:Q8_0            # pilih quant tertentu
llama-get https://host/path/model.gguf          # URL langsung
LLAMA_MODELS=/data/models llama-get org/repo    # folder tujuan lain
```

Model lokal tetap bisa dipakai: `llama-auto cli -m /path/model.gguf`.

## `llama-auto`

Pembungkus tipis: `llama-auto <cli|server|bench|...> [argumen]`. Kalau yang terpasang build GPU, otomatis menambah `-ngl 99` (offload semua layer). Build CPU dijalankan apa adanya. Kalau kamu sudah memberi `-ngl` atau `--device` sendiri, wrapper tidak mengubahnya. Cek perangkat yang terdeteksi dengan `llama-cli --list-devices`.

## Opsi installer

| Variabel | Fungsi |
|---|---|
| `LLAMA_VARIANT` | paksa `cpu`, `vulkan`, `cuda12`, `rocm`, `metal`, atau `opencl` |
| `LLAMA_VERSION` | pin ke tag rilis tertentu (default `latest`) |
| `LLAMA_DIR` | folder instalasi (default `~/.local/llama`) |
| `LLAMA_BIN` | folder symlink command (default `~/.local/bin`, di Termux `$PREFIX/bin`) |
| `GH_PROXY` | prefix mirror untuk download GitHub |

Contoh: `LLAMA_VARIANT=cpu sh install.sh` untuk memaksa CPU walau ada GPU.

## Cara build (GitHub Actions)

1. Taruh `.github/workflows/build-llama.yml` dan `install.sh` di root repo kamu.
2. Jalankan manual: tab Actions, pilih *Build llama.cpp (auto hardware)*, Run workflow. Input `llama_ref` bisa branch, tag, atau commit llama.cpp (default `master`).
3. Atau push tag `v*`.
4. Hasilnya muncul di Releases, lengkap dengan `SHA256SUMS.txt` dan `install.sh` yang sudah berisi nama repo kamu.

Catatan build:
- Job CPU Linux x86_64/aarch64, Android arm64, dan macOS wajib sukses supaya release terbit. Job GPU (CUDA, ROCm, Vulkan), armv7, OpenCL Android, dan Windows ditandai `continue-on-error`: kalau gagal, paket itu saja yang tidak ada, sisanya tetap dirilis.
- Build CUDA 12 mencakup arsitektur 6.1 sampai 9.0 (GTX 10xx sampai H100). Ubah lewat input `cuda_archs`.
- Build CUDA memakan waktu lama (bisa lebih dari 1 jam) di runner gratis.
- Release dibuat dari commit llama.cpp yang dipin di awal job, jadi semua paket berasal dari kode yang sama.

## Build manual di device (tanpa Actions)

```sh
apt update && apt install -y git cmake build-essential libssl-dev
git clone https://github.com/ggml-org/llama.cpp && cd llama.cpp
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release -j2
```

Tambahkan `-DGGML_VULKAN=ON`, `-DGGML_CUDA=ON`, atau `-DGGML_HIP=ON` untuk GPU. Di Termux pakai `pkg install git cmake clang openssl`.
