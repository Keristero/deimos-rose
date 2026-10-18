#!/bin/sh
# Marigold V2 for terrain_recover's height seed, the way its authors set it
# up (setup/setup_env.sh upstream: Python 3.10, torch, then the package with
# every dependency pinned), in DR_MARIGOLD instead of a conda env:
#
#   DR_MARIGOLD/src     the repository at MARIGOLD_COMMIT, with marigold-v2.patch
#   DR_MARIGOLD/venv    Python 3.10
#   DR_MARIGOLD/assets  the checkpoints, linked from the Hugging Face cache
#
# torch comes from TORCH_INDEX as TORCH_SPEC; the defaults are upstream's,
# for NVIDIA. For AMD Strix Halo (gfx1151):
#   TORCH_INDEX=https://rocm.nightlies.amd.com/v2/gfx1151/ TORCH_SPEC="torch torchvision"
# The weights are about 45 GB (the Qwen-Image-Edit-2509 transformer is 39).
# Rerunning is safe: each step is skipped once done.
set -e

MARIGOLD_REPO=https://github.com/huawei-bayerlab/marigold-v2.git
MARIGOLD_COMMIT=8ea69d69fa78d10c73be8abe1459a5326e8aa524
MARIGOLD_WEIGHTS_REVISION=cdf9810fb690886391a63aec012b5f501064fb0d
QWEN_REVISION=d3968ef930e841f4c73640fb8afa3b306a78167e
TORCH_INDEX="${TORCH_INDEX:-https://download.pytorch.org/whl/cu128}"
TORCH_SPEC="${TORCH_SPEC:-torch==2.10.0 torchvision==0.25.0}"

here=$(cd "$(dirname "$0")" && pwd)
: "${DR_MARIGOLD:?set DR_MARIGOLD (mise sets it)}"
mkdir -p "$DR_MARIGOLD"
src="$DR_MARIGOLD/src"
venv="$DR_MARIGOLD/venv"

if [ ! -d "$src/.git" ]; then
	git clone -q "$MARIGOLD_REPO" "$src"
fi
git -C "$src" checkout -q "$MARIGOLD_COMMIT"
if git -C "$src" apply --check "$here/marigold-v2.patch" 2>/dev/null; then
	git -C "$src" apply "$here/marigold-v2.patch"
elif ! git -C "$src" apply --reverse --check "$here/marigold-v2.patch" 2>/dev/null; then
	echo "marigold-v2.patch applies neither way to $src: remove it and rerun"
	exit 1
fi

py="$venv/bin/python"
[ -x "$py" ] || py="$venv/Scripts/python.exe"
if [ ! -x "$py" ]; then
	if command -v uv >/dev/null; then
		uv venv -q --seed --python 3.10 "$venv"
	else
		"${PYTHON:-python3.10}" -m venv "$venv"
	fi
	py="$venv/bin/python"
	[ -x "$py" ] || py="$venv/Scripts/python.exe"
fi
# shellcheck disable=SC2086 # TORCH_SPEC is a list of requirements
"$py" -m pip install -q --index-url "$TORCH_INDEX" $TORCH_SPEC
"$py" -m pip install -q -e "$src"
"$py" -m pip check
# Upstream's bitsandbytes (0.49.2) has no build for ROCm past 7.2 and no
# override; 0.50 falls back to its 7.2 build. The one change to upstream's
# pins, on ROCm only (so after the check).
if "$py" -c "import sys, torch; sys.exit(not torch.version.hip)"; then
	"$py" -m pip install -q "bitsandbytes==0.50.2"
fi

"$py" - "$DR_MARIGOLD/assets/checkpoints" "$MARIGOLD_WEIGHTS_REVISION" "$QWEN_REVISION" <<'EOF'
import os, sys
from huggingface_hub import snapshot_download

out, marigold, qwen = sys.argv[1:]
os.makedirs(out, exist_ok=True)
# What scripts/download_assets.py fetches for folder inference: the depth,
# normals and albedo heads, their prompt embeddings, and the Qwen base.
for name, repo, revision, patterns in [
    ("Marigold-V2", "huawei-bayerlab/marigold-v2-0", marigold,
     ["depth/Log-stage2/*", "normals/*", "albedo/*", "manifest.json",
      "qwen_text_embeddings/*realimg512*", "qwen_text_embeddings/*dummy512*"]),
    ("Qwen-Image-Edit-2509", "Qwen/Qwen-Image-Edit-2509", qwen,
     ["model_index.json", "transformer/*", "vae/*", "scheduler/*"]),
]:
    path = snapshot_download(repo, revision=revision, allow_patterns=patterns)
    link = os.path.join(out, name)
    if os.path.islink(link) or os.path.exists(link):
        if os.path.realpath(link) == os.path.realpath(path):
            continue
        os.remove(link)
    os.symlink(path, link)
    print(name, "->", path)
EOF
"$py" -c "import torch; print('torch', torch.__version__, 'GPU:', torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'none')"
