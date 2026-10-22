"""Export a trained Swin UNETR checkpoint (Swin-UNETR notebooks' best_metric_model.pth) to ONNX
for Triton, and check the ONNX graph against PyTorch before it is published.

Usage:
  python scripts/export_model.py --weights Swin-UNETR/data/best_metric_model.pth --out-channels 2 \
      --output build/swin_unetr_lung_cancer.onnx
  scripts/publish_weights.sh swin_unetr_lung_cancer build/swin_unetr_lung_cancer.onnx

Requires: torch, monai>=1.5, einops, onnx, onnxruntime (CPU is fine).
"""

import argparse

import numpy as np
import onnx
import onnxruntime as ort
import torch
from monai.networks.nets import SwinUNETR

ROI = (96, 96, 96)


def build_model(out_channels: int) -> SwinUNETR:
    # Same constructor as the notebooks. img_size=(96, 96, 96) was dropped from MONAI >= 1.5
    # (it never affected the weights); use_checkpoint only matters for training.
    return SwinUNETR(in_channels=1, out_channels=out_channels, feature_size=48, use_checkpoint=False)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--weights", required=True, help="state_dict saved by the training notebook")
    p.add_argument("--out-channels", type=int, required=True, help="2 = cancer, 6 = lung lobes, 4 = covid")
    p.add_argument("--output", required=True, help="path of the .onnx file to write")
    p.add_argument("--opset", type=int, default=17)
    args = p.parse_args()

    model = build_model(args.out_channels)
    state = torch.load(args.weights, map_location="cpu", weights_only=True)
    model.load_state_dict(state)
    model.eval()

    dummy = torch.rand(1, 1, *ROI)
    torch.onnx.export(
        model,
        dummy,
        args.output,
        input_names=["image"],
        output_names=["logits"],
        dynamic_axes={"image": {0: "batch"}, "logits": {0: "batch"}},
        opset_version=args.opset,
        dynamo=False,
    )
    onnx.checker.check_model(args.output)

    # Verify with a batch size different from the export batch (Triton batches patches).
    sess = ort.InferenceSession(args.output, providers=["CPUExecutionProvider"])
    x = torch.rand(2, 1, *ROI)
    with torch.no_grad():
        expected = model(x).numpy()
    got = sess.run(["logits"], {"image": x.numpy()})[0]
    max_err = float(np.abs(expected - got).max())
    argmax_agree = float((expected.argmax(1) == got.argmax(1)).mean())
    print(f"output shape {got.shape}, max |torch - onnx| = {max_err:.2e}, argmax agreement = {argmax_agree:.6f}")
    if argmax_agree < 0.999:
        raise SystemExit("ONNX output does not match PyTorch; not safe to publish")
    print(f"wrote {args.output}")


if __name__ == "__main__":
    main()
