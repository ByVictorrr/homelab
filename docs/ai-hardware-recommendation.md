# DGX Spark vs. desktop GPU: what to buy for this homelab

_Written September 2026. GPU and memory prices changed a lot in 2026, so check them again before you buy._

## TL;DR

**Don't buy a DGX Spark for this project. Put a used RTX 3090 (24 GB) in
`delaplaine-server`.** If the case and PSU have room, keep the RTX 3060 in the
same box as a second GPU.

| | Used RTX 3090 in `delaplaine-server` | DGX Spark (GB10) |
|---|---|---|
| Price (Sep 2026) | ~$1,050–1,450 used | $4,699 Founders Edition (raised from $3,999 in Feb 2026); partner units such as the ASUS Ascent GX10 cost somewhat less |
| Memory for models | 24 GB GDDR6X | 128 GB unified LPDDR5X |
| Memory bandwidth (sets tok/s) | ~936 GB/s | ~273 GB/s |
| Arch | x86_64 + CUDA (what the manifests already target) | arm64 + CUDA (DGX OS / Ubuntu 24.04) |
| Frigate `stable-tensorrt` image | ✅ amd64, works as documented in `manifests/frigate.yaml` | ⚠️ no official arm64 TensorRT build for GB10; you'd have to build or maintain your own |
| Jellyfin NVENC / Immich ML | ✅ | Probably works, but not the well-tested path |
| Best at | Fast chat on 8B–32B models, vision, Frigate, transcoding | Fitting 70B–120B models or fine-tuning in memory |

## Why the desktop wins for *this* repo

Here's what the cluster actually runs on a GPU today:

1. **Open WebUI + Ollama** (`manifests/ollama.yaml`, `chat-webui.yaml`). The roster
   is 3B–14B models. Claude through the Anthropic API already handles the hard
   prompts, so local models are the offline fallback and quick-answer tier.
   Token generation speed depends on memory bandwidth. A 3090 is about 3.4× faster
   than a Spark on any model that fits in 24 GB, and even the 3060 you have now
   (360 GB/s) beats a Spark on the current roster.
2. **Frigate** (`manifests/frigate.yaml`). The TensorRT upgrade path uses
   `ghcr.io/blakeblackshear/frigate:stable-tensorrt`, which is **amd64 only**,
   plus NVDEC (`preset-nvidia-h264`). A desktop NVIDIA card works with the
   manifest as written.
3. **Immich machine learning** and **Jellyfin transcoding** both follow the
   standard x86 + NVIDIA path.
4. **JupyterLab / kerneldev / buildkit** run on the CPU and are fine either way.

A 3090's 24 GB also moves the local tier from 14B models up to **~32B models at
Q4** (e.g. `qwen2.5-coder:32b`, `qwen3:32b`), which is a real quality jump for
the offline chat and coding fallback.

### Suggested split with two GPUs in one box

| GPU | Workloads |
|---|---|
| RTX 3090 24 GB | Ollama (all chat, vision, and coding models) |
| RTX 3060 12 GB | Frigate TensorRT + NVDEC, Immich ML, Jellyfin NVENC |

With both cards, the NVIDIA device plugin reports `nvidia.com/gpu: 2`. Pin each
workload to a card with `NVIDIA_VISIBLE_DEVICES` or by enabling device-plugin
time-slicing. Before you buy, check that the PSU is **≥ 850 W** (the 3090 alone
has ~350 W transients) and that there's room for a 3-slot card.

## When a DGX Spark *would* be the right call

Get the Spark (a cheaper partner GB10 unit is fine) only if one of these is a real goal:

- Running **70B–120B models locally** (e.g. `gpt-oss:120b`, Llama 3.x 70B) with
  no cloud API at all. The Spark can fit them, but dense 70B models decode at only
  a few tok/s. MoE models like gpt-oss-120b are much more usable.
- **Fine-tuning or LoRA training** on models larger than 24 GB of VRAM allows.
- Learning the NVIDIA datacenter stack (NIM, NeMo, CUDA on Grace/arm64) for school
  or work.

If you buy one anyway, it fits the cluster well as a **k3s agent**: it's arm64 like
the Pis, so the existing images run on it. Join it with the normal
`ansible-playbook site.yml --limit <spark>` flow and install the NVIDIA GPU
operator. Move Ollama there, and **keep Frigate and Jellyfin on the x86 3060 box.**

## Alternatives considered

- **RTX 5090 (32 GB):** the fastest option, but street prices were about $4,300–5,200+
  in Sep 2026, so you pay Spark money for only 8 GB more than a 3090. Not worth it.
- **AMD Ryzen AI Max+ 395, 128 GB (e.g. Framework Desktop):** ~$2,850–3,450. It gives
  Spark-like capacity (~256 GB/s) on x86, but it uses ROCm/Vulkan instead of CUDA, and
  Frigate TensorRT won't run on it. It only makes sense if you want 70B+ models and
  would give up the NVIDIA stack.
- **Doing nothing:** a reasonable choice. The 3060 already covers the current roster,
  and Claude handles the heavy prompts. Buy the 3090 when you want 32B-class local
  models, or when Frigate plus Ollama start fighting over 12 GB.
