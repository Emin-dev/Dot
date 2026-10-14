# R50: T3-Video / Wan2.2-5B feasibility research

Research date: 2026-10-14 UTC. Status: **bounded research complete for review; no implementation or Apple Silicon acceptance**.

## Decision

Keep this a separately admitted, optional video experiment. There is no verified basis to enable it on Dot's 36 GB minimum or 48 GB recommended hardware, bundle it into the fast voice path, or promise native-4K generation speed. The exact requested model can be identified, but the published inference path is CUDA-oriented and the released attention implementation fixes its geometry to a 4K, 81-frame workload. A Mac port and resource measurement are prerequisites, not configuration switches.

This report changes no checklist status, code, model selection, installation, publication or distribution decision. It contains no measured Dot/video benchmark. No models were downloaded, loaded or executed; no software was installed, legal agreement accepted, payment made, external scan started, or live checkout edited.

## 1. Exact identity and provenance

The checklist's shorthand **T3-Video-Wan2.2-5B** maps to the authors' **T3-Video-Wan2.2-T2V-5B.safetensors**, in **APRIL-AIGC/T3-Video**. T3 means Transform Trained Transformer. The authors link this model repository from their [T3-Video source repository](https://github.com/zhangzjn/T3-Video) and [research paper, arXiv:2512.13492v2](https://arxiv.org/abs/2512.13492v2), revised 2026-10-05. This is a native-4K research adaptation, not an alias for the ordinary Wan2.2 checkpoint.

The documented 5B recipe combines that T3 checkpoint with **Wan-AI/Wan2.2-TI2V-5B**, including its UMT5 encoder, Wan2.2 VAE and base DiT shards. The published command uses 2176×3840 pixels, 81 frames and 50 denoising steps. The separate T3 1.3B checkpoint is not the requested model. The base TI2V model's image-to-video support does not establish image-to-video acceptance for this released T3 T2V artifact. [Authors' quickstart](https://github.com/zhangzjn/T3-Video#quickstart)

Observed remote identities, not locally verified payloads:

| Artifact | Remote metadata observed | Provenance |
| --- | --- | --- |
| T3 5B checkpoint | Approximately 10 GB; SHA-256 `1e5a400bb9b705f287eeac571c90fd15a88406d9418b26ffb33ae0591679b1a5` | [Publisher's file page](https://huggingface.co/APRIL-AIGC/T3-Video/blob/main/T3-Video-Wan2.2-T2V-5B.safetensors) |
| Wan UMT5 encoder | 11,361,920,418 bytes; SHA-256 `7cace0da2b446bbbbc57d031ab6cf163a3d59b366da94e5afe36745b746fd81d` | [Publisher's LFS pointer](https://huggingface.co/Wan-AI/Wan2.2-TI2V-5B/raw/main/models_t5_umt5-xxl-enc-bf16.pth) |
| Wan2.2 VAE | 2,818,839,170 bytes; SHA-256 `20eb789667fa5e60e7516bf509512f6cb61f01b0aa0695eadaea930c13892b36` | [Publisher's LFS pointer](https://huggingface.co/Wan-AI/Wan2.2-TI2V-5B/raw/main/Wan2.2_VAE.pth) |
| Base Wan DiT | Index declares 19,999,150,848 tensor bytes across three shards; headers add overhead | [Publisher's shard index](https://huggingface.co/Wan-AI/Wan2.2-TI2V-5B/blob/main/diffusion_pytorch_model.safetensors.index.json) |
| Base Wan repository | Observed revision `921dbaf3f1674a56f47e83fb80a34bac8a8f203e` | [Revision](https://huggingface.co/Wan-AI/Wan2.2-TI2V-5B/commit/921dbaf3f1674a56f47e83fb80a34bac8a8f203e) |

The T3 tree displayed abbreviated revision `b38f51b`, and the checkpoint page displayed file commit `592693d`. Full immutable T3 repository/source revisions and exact T3 byte length were not established through the available page reads. Do not treat abbreviations, remote hashes or changing `main` links as an install manifest. Before a POC, resolve immutable revisions and every artifact's size/hash, then verify actual bytes after an authorized acquisition. The tree currently lists two weight files, not a complete prepackaged Mac runtime. [T3 file inventory](https://huggingface.co/APRIL-AIGC/T3-Video/tree/main)

## 2. License evidence and remaining distribution gate

- The T3 source [LICENSE](https://raw.githubusercontent.com/zhangzjn/T3-Video/main/LICENSE) and the model repository's [LICENSE](https://huggingface.co/APRIL-AIGC/T3-Video/blob/main/LICENSE) contain Apache License 2.0. The model card labels the release Apache-2.0 and also directs users to the Wan2.1 license for Wan-related models. That cross-reference should remain in the provenance review rather than being silently removed. [T3 model card](https://huggingface.co/APRIL-AIGC/T3-Video)
- The selected base [Wan2.2 model card](https://huggingface.co/Wan-AI/Wan2.2-TI2V-5B) labels its release Apache-2.0; the upstream [Wan2.2 license](https://raw.githubusercontent.com/Wan-Video/Wan2.2/main/LICENSE.txt) is Apache 2.0. Google's [UMT5-XXL card](https://huggingface.co/google/umt5-xxl) likewise labels its upstream model Apache-2.0. This does not by itself prove the provenance of every converted encoder/tokenizer file.
- Engineering preparation for redistribution must collect the exact applicable licenses, copyright/attribution and NOTICE material, preserve required notices, and identify modifications. Apache-2.0 section 4 is conditional; it is not blanket clearance for the entire Dot package. [T3 license, redistribution section](https://huggingface.co/APRIL-AIGC/T3-Video/blob/main/LICENSE)
- Still unreviewed: the complete pinned DiffSynth fork, Python/PyTorch and numerical dependencies, tokenizer assets, video encoding/export dependencies, converted or quantized artifacts, and any sample media included in delivery. No opinion on training-data or generated-output rights is established here. No account or hosting terms were accepted.

## 3. Runtime support: what is established

| Route | Evidence | R50 conclusion |
| --- | --- | --- |
| Authors' PyTorch/DiffSynth CUDA path | Launcher selects BF16 and CUDA, configures CPU offload, creates the pipeline from base assets, then applies a full T3 DiT state dictionary. Its default launcher can start eight workers, each assigned a CUDA device. [Launcher source](https://raw.githubusercontent.com/zhangzjn/T3-Video/main/infer_multi_gpu.py) | Published reference route; not executed here. Eight workers partition samples, not proof that one clip requires eight GPUs. Never run its default multiworker configuration on a Mac. |
| PyTorch MPS | Apple documents MPS GPU acceleration and a device-availability probe. [Apple guidance](https://developer.apple.com/metal/pytorch/) PyTorch documents the backend independently. [MPS notes](https://docs.pytorch.org/docs/2.14/notes/mps.html) | Supported underlying Apple framework; exact T3 pipeline unverified. Requires a reviewed port and operator/dtype/offload tests. |
| Standard Diffusers Wan | Diffusers lists Wan2.2 TI2V 5B and offers MPS as a device in Wan examples. [Wan pipeline documentation](https://huggingface.co/docs/diffusers/api/pipelines/wan) | Useful base-model integration evidence; not evidence that T3's modified attention and checkpoint work unchanged. |
| MLX | Apple's MLX project supports shared-memory CPU/GPU computation. [MLX](https://github.com/ml-explore/mlx) | Potential separate implementation substrate. No author-supported exact T3 MLX artifact or validated conversion was established in this review. This cannot replace Splash for Dot's LLM. |
| Core ML / ANE | No exact T3-Video-5B converted artifact or end-to-end acceptance was established from the primary sources reviewed. | Unverified conversion/reimplementation work; no ANE acceleration claim. |
| Community Mac implementations | Maintainers describe MPS support for base Wan2.2 and MLX support for the base TI2V-5B family. [Wan2.2-Mac](https://github.com/HighDoping/Wan2.2-Mac), [VGA MLX Video](https://github.com/VeryGoodAI/vga-mlx-video) | Primary evidence only of those maintainers' implementations. They do not establish T3 compatibility, trusted packaging, cancellation, quality or Dot hardware fit. No community speed numbers are used here. |

Important porting details:

1. The released attention source defaults to the Wan2.1 mode. The Wan2.2 mode fixes `T=21`, `H=68`, `W=120`, corresponding to the published 4K/81-frame latent grid; rearranges and divisibility checks depend on it. It contains an ordinary PyTorch scaled-dot-product-attention fallback, but also float64/complex positional computations. Each path requires target-device verification. A simple CUDA-to-MPS edit is insufficient evidence. [Attention implementation](https://raw.githubusercontent.com/zhangzjn/T3-Video/main/diffsynth/models/wan_video_dit.py)
2. The repository's device/offload manager must be inspected and ported with its pipeline, including allocation limits and cleanup. CPU offload is not automatically a reduction in total unified-memory demand. [Pipeline implementation](https://raw.githubusercontent.com/zhangzjn/T3-Video/main/diffsynth/pipelines/wan_video_new.py)
3. Hugging Face displays a generic Diffusers snippet suggesting MPS, but the same page reports a configuration parsing warning and demonstrates an image-returning generic pipeline. That generated snippet is not an author-tested T3 Mac recipe. [T3 model page](https://huggingface.co/APRIL-AIGC/T3-Video)
4. Do not reduce resolution or frame count in the published recipe and call it a supported small test. Shape-compatible lower-cost experimentation needs an explicit port/configuration change, separately checked for numerical and quality effects. Arbitrary-resolution quality is not established.

## 4. Resource accounting, separated from benchmarks

Units: GB = 1,000,000,000 bytes; GiB = 1,073,741,824 bytes. Figures below are arithmetic from remote metadata and stated assumptions, **not measured working sets, installer sizes or certified disk requirements**.

### Storage estimates

- Published-recipe selection: approximately **44.18 GB / 41.15 GiB**, comprising ~10 GB T3 + 11.362 GB UMT5 + 2.819 GB VAE + 19.999 GB base DiT tensors. Add shard headers, tokenizer/configuration, code, runtime libraries, caches, output and staging overhead. The base repository tree reports 34.2 GB in total. [Base inventory](https://huggingface.co/Wan-AI/Wan2.2-TI2V-5B/tree/main)
- A hypothetical direct-T3 loader that avoids storing base DiT shards would reduce those selected weights to approximately **24.18 GB / 22.52 GiB**. This is a design opportunity, not the supplied load path or a verified install option. It requires proving architecture construction, complete key coverage and numerical equivalence.
- Two independent materialized copies of the published-recipe selection would occupy about **88.36 GB** before other assets. Filesystem deduplication or download-cache sharing must not be assumed. Disk admission should sum a pinned manifest's actual stored/staged/cache/output byte requirements and preserve an explicit free-space reserve.
- Dot's reviewed README records **19,930,313,310 bytes** for its fixed Qwen target/draft/vision payload. That disk payload plus one selected video payload already totals roughly **64.11 GB**, before the existing speech/runtime/app assets. This is storage arithmetic only, not an estimate of Qwen RAM.

### Memory estimates and risk

- A nominal 5 billion parameter transformer alone requires roughly 10 GB in a two-byte representation, 5 GB at eight bits or 2.5 GB at four bits, before metadata/scales, activations, caches or runtime allocations. No exact T3 quantized format, loader compatibility or retained quality is validated here; quantization cannot be counted as available capacity relief.
- An illustrative simultaneously resident set with a ~10 GB DiT, the 11.362 GB encoder and a roughly 1.409 GB two-byte VAE is **~22.77 GB / 21.21 GiB**. Keeping the VAE's ~2.819 GB stored representation instead gives **~24.18 GB / 22.52 GiB**. These assumptions do not establish actual tensor dtypes or scheduling. Sequential loading might reduce residency; loading/casting/state-dictionary duplication can increase peak consumption substantially.
- A full 81-frame 2176×3840 RGB clip alone is **2,030,469,120 bytes** at one byte per channel, or **8,121,876,480 bytes** at float32. These are representation sizes, not observed allocation behavior; tiled decoding and incremental export could avoid retaining a full buffer. Latents, attention/FFN intermediates and temporary copies remain additional.
- On a shared CPU/GPU memory system, unloading GPU work to CPU is not equivalent to adding another RAM pool. MLX's documented shared-memory behavior illustrates this distinction; actual PyTorch copies and allocator retention must be measured. [MLX memory model](https://github.com/ml-explore/mlx)
- Therefore **36 GB and 48 GB are both unaccepted for this optional feature**. Neither the nominal parameter count nor a 24 GB NVIDIA VRAM recipe proves space for macOS, a resident Qwen/Splash engine, speech and T3 together. No total concurrent-memory estimate is substituted for the missing core/video measurements.

### Published performance evidence, with strict scope

The base Wan2.2 TI2V-5B publisher describes its 1280×704 recipe with CPU encoder/offload options as runnable on a GPU with at least 24 GB VRAM. This is a base-model NVIDIA-oriented configuration, not T3 4K or Mac acceptance. [Base model instructions](https://huggingface.co/Wan-AI/Wan2.2-TI2V-5B)

The T3 paper's Table 2 explicitly covers **1.3B**, with 50-step CFG and a separate 8-step/eVAE deployment variant. Table 3 reports 59.5G test memory at 4K in that surrounding default-model analysis. The paper describes H20/FlashAttention2 hardware and selects 1.3B as its default model; its 5B generalization table reports quality. These figures are author measurements, not reproduced results, and cannot establish this 5B checkpoint's Apple Silicon latency or memory. Do not transfer the headline speedup or optimized deployment variant to the released 5B file. [Paper, tables 2–3 and 6; implementation details](https://arxiv.org/html/2512.13492v2)

## 5. Compatibility with Dot's fixed priorities and gates

The canonical requirements retain Qwen 3.8 27B Q4 through Splash, the Splash 1.3.1 baseline and pinned target/draft/vision assets, plus the local British female Kokoro `bf_isabella` quality reference. The `mlx-community` publisher name does not authorize changing the LLM engine. The product target remains M4 Pro-class/36 GB minimum, 48 GB recommended, with macOS 26.4+ required for the selected Splash runtime; the reported M5 Pro/48 GB personal test class is not video certification. [Canonical checklist](../BUILD_CHECKLIST.md), [README](../../README.md)

Proposed video policy, requiring implementation and acceptance before activation:

- Separate optional capability and payload with an honest unsupported/unavailable state. Core startup, offline conversation and public core provisioning must not depend on video assets. No automatic download, cloud inference, model/voice swap or paid fallback.
- Preserve the single resident Qwen/Splash engine. No second conversational model and no silent eviction of it to make video fit. If the measured resource envelope cannot preserve the fast voice contract, refuse or defer the optional job.
- Admit at most one explicitly requested video job. Prefer a separately owned cancellable worker for this long-running, resource-heavy task, only if the isolation benefit justifies that boundary. Never reuse or mutate Splash's interpreter/environment. Contain local file access and deny unintended network access.
- Conversation, Stop, Quit, thermal/memory pressure and stale-job replacement must revoke video work safely. A long GPU dispatch is not proven immediately interruptible. Measure actual voice admission/recovery and worker teardown; do not advertise instantaneous yield based on a cancellation flag alone.
- No ambient screen capture, microphone/audio retention or implicit export. Start with a harmless authored text prompt. Any future image input requires an explicit task input and agreed retention/export behavior.
- Keep hardware detection separate from admission: exact chip/RAM/OS checks, runtime/backend availability, manifest-valid local assets, available disk and measured safe working-set budget must all pass. A successful device probe alone enables no user-visible video capability.

## 6. Smallest optional proof of concept

This is an ordered acceptance proposal, **not work performed or permission to start a new execution task**. It ends at the first unresolved gate and returns a reproducible failure report. No publication, installation into Dot, model substitution or purchase is part of it.

1. **Freeze the experiment before acquiring payloads.** Resolve the exact source/model revisions, complete file manifest and licenses, minimal dependencies, safe deserialization path and reviewable Mac-port delta. Agree a bounded local disk/RAM/runtime budget on an authorized test machine. Inspect why the full base model is needed and whether its duplication can be eliminated without changing the result. No unsafe pickle execution or unrestricted remote model code.
2. **Model-free operator/shape probe.** Use tiny synthetic tensors to test T3 window permutation, local/remote attention, positional math, dtype casts and tiled VAE primitives on the selected Apple backend against a CPU reference with predeclared tolerances. Validate the full 21×68×120 shape algebra without allocating full-model tensors. Reject unsupported operators, nonfinite values and undisclosed CPU fallbacks. This stage can prove a porting prerequisite, not generation quality.
3. **One controlled real load/step, only if admitted.** Acquire only pinned required files within the approved resource plan; verify hashes and strict state-dictionary compatibility. Record cold-load peak before any generation. Attempt one denoise step at a shape the reviewed port actually supports. A tiny-shape port test is labelled diagnostic; the released 4K checkpoint's product quality remains untested. Fail safely on memory pressure, OOM, deadline, operator failure or cancellation; do not disable allocator safeguards or evict Qwen to continue.
4. **One real clip only after the earlier gates pass.** Run a single fixed harmless prompt/seed with the released 5B checkpoint, declared dimensions/frames/steps/dtypes and no prompt-extension model. Record actual timings and inspect every decoded frame for corruption/nonfinite artifacts, temporal coherence and prompt adherence. Reproducing the authors' 4K recipe is a separate larger test; if budget prevents it, report it unrun rather than extrapolating from a small diagnostic.
5. **Voice coexistence before any Dot admission.** On both intended RAM classes, establish voice-only baselines, then compare while video loads, denoises and decodes. Measure microphone-to-first-audible-response and tail latency, dropouts, UI stalls, cancellation/recovery, resident/driver memory, swap, thermal and energy behavior. Try Stop, new conversation and Quit in every stage, repeated jobs, pressure/error paths and offline execution. Pass only within the product's explicitly recorded voice/resource limits, with cleanup and unchanged model/voice identities. If those limits are not yet measured/defined, no acceptance decision can be made.

Measurement receipts must identify hardware, exact OS/Python/runtime/compiler versions, source revision, all model hashes, operator fallback policy, prompt/seed, geometry, sampling settings, cold/warm state and instrumentation. PyTorch exposes tensor memory, total driver allocation and a recommended working-set value; log all relevant values with process/OS memory rather than reporting only tensor allocations. A recommended working set is not reserved headroom for simultaneous processes. [PyTorch MPS instrumentation](https://docs.pytorch.org/docs/2.14/mps.html)

POC success means only that the recorded configuration passed that bounded experiment. Packaging, signed-helper boundaries, redistribution closure, clean-machine install, sustained use, broader quality and owner acceptance remain separate gates.

## 7. Concrete unresolved questions

1. Exact immutable T3 source/model revisions, exact T3 byte size, complete tokenizer/dependency closure and post-download hash verification.
2. Whether the published 5B state dictionary loads correctly with a reviewed Mac port and which BF16/FP16/FP32/complex operations require changes or CPU execution.
3. Whether a source-compatible direct checkpoint loader can avoid the original base DiT storage/load peak; whether decoded frames can stream without a full buffer.
4. Which alternative geometries have valid attention configuration and acceptable checkpoint quality. No arbitrary small-video recipe is currently certified.
5. Real peak unified memory, load/denoise/decode time, cancellation latency, voice contention, sustained thermals, battery effect and output quality on both 36 GB and 48 GB hardware.
6. Whether any useful video mode can coexist with the fixed resident Qwen/Splash and British voice without breaking the fast-voice acceptance criteria.
7. Complete licensing/attribution, safe payload acquisition/deserialization and maintainable signed native packaging. Apache labels alone do not close distribution.

## Review provenance

Read-only local context: `CONTRIBUTING.md`, `docs/BUILD_CHECKLIST.md` (R50 sentence and fixed-stack/hardware/priority context), and `README.md` from the existing working tree. Observed Git HEAD was `b5082946acd3e4a150e8a2fe57638fba2286edd4`; the checkout was dirty and no file was changed there. This report describes that reviewed context, not all later concurrent work.

Context file SHA-256 values at review:

- CONTRIBUTING.md: `1a3ec18c0f684951bf4ddd9e6547737f8c1481acfc653062527a68feb4176ad7`
- docs/BUILD_CHECKLIST.md: `6a13a149f6e8372d2c056dc86298e933dd3ee51f063919750646fddcf67820e0`
- README.md: `cebc5eb963bd5739f876e0e55c9c6b1123867e2a664914f057062724c1eeed4e`

Public research used primary model-author, research-paper, framework-vendor and named implementation-maintainer pages, inspected 2026-10-14 UTC. Remote pages can be cached and `main` can move. Links and displayed hashes support this research; they are not a downloaded-payload attestation. Some T3 metadata/commit pages were unavailable through the web reader, and the resulting immutable-revision/byte-length gaps are explicit above. No claim is made that this bounded review proves no other Mac port exists.
