"""Minimal client: upload a NIfTI CT volume, save the returned segmentation mask.

Usage:
  export CTSEG_URL=$(cd terraform/2-platform && terraform output -raw gateway_url)
  export CTSEG_API_KEY=$(cd terraform/2-platform && terraform output -raw api_key)
  python scripts/client.py lung_001.nii.gz lung_001_mask.nii.gz [--task lung_cancer|lung_lobes]

Only needs the Python standard library. The mask is on the same voxel grid as the
input, so both files can be overlaid directly in OHIF / 3D Slicer.
"""

import argparse
import base64
import json
import os
import urllib.request


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("volume", help=".nii or .nii.gz CT volume")
    p.add_argument("mask", help="where to write the .nii.gz mask")
    p.add_argument("--task", help="defaults to the server's default task")
    args = p.parse_args()

    with open(args.volume, "rb") as f:
        payload = {"volume_b64": base64.b64encode(f.read()).decode()}
    if args.task:
        payload["task"] = args.task

    req = urllib.request.Request(
        os.environ["CTSEG_URL"].rstrip("/") + "/v1/segment",
        data=json.dumps(payload).encode(),
        method="POST",
        headers={"content-type": "application/json", "x-api-key": os.environ["CTSEG_API_KEY"]},
    )
    with urllib.request.urlopen(req, timeout=900) as resp:
        result = json.load(resp)

    with open(args.mask, "wb") as f:
        f.write(base64.b64decode(result.pop("mask_b64")))
    print(json.dumps(result, indent=2))
    print(f"mask written to {args.mask}")


if __name__ == "__main__":
    main()
