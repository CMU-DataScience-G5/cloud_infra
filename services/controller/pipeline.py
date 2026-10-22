"""Swin UNETR pre/post-processing.

Mirrors `test_transforms` + `sliding_window_inference` from the Swin-UNETR training
notebooks (Swin-UNETR/notebook/*.ipynb) so served predictions match training-time
validation, then inverts the spatial transforms so the mask lines up voxel-for-voxel
with the uploaded CT (the original repo saved masks in the resized space with an
identity affine, which can't be overlaid in a viewer).

Kept free of Triton/GCS so it can be tested with any `predictor`.
"""

from collections.abc import Callable
from dataclasses import dataclass

import nibabel as nib
import numpy as np
import torch
from monai.inferers import sliding_window_inference
from monai.transforms import (
    Compose,
    CropForegroundd,
    EnsureChannelFirstd,
    Invertd,
    LoadImaged,
    Orientationd,
    Resized,
    ScaleIntensityRanged,
)

ROI_SIZE = (96, 96, 96)  # SwinUNETR(img_size=(96, 96, 96))


@dataclass(frozen=True)
class Task:
    triton_model: str
    labels: tuple[str, ...]  # index = class id
    resize: tuple[int, int, int]  # Resized(spatial_size=...) used in training
    overlap: float = 0.8  # notebooks' inference cell
    sw_batch_size: int = 4
    hu_min: float = -175.0
    hu_max: float = 250.0

    @classmethod
    def from_dict(cls, d: dict) -> "Task":
        return cls(
            triton_model=d["triton_model"],
            labels=tuple(d["labels"]),
            resize=tuple(d["resize"]),
            overlap=float(d.get("overlap", 0.8)),
            sw_batch_size=int(d.get("sw_batch_size", 4)),
            hu_min=float(d.get("hu_min", -175)),
            hu_max=float(d.get("hu_max", 250)),
        )


def preprocessing(task: Task) -> Compose:
    return Compose(
        [
            LoadImaged(keys="image", image_only=True),
            EnsureChannelFirstd(keys="image", channel_dim="no_channel"),  # AddChanneld in the notebooks
            ScaleIntensityRanged(
                keys="image", a_min=task.hu_min, a_max=task.hu_max, b_min=0.0, b_max=1.0, clip=True
            ),
            CropForegroundd(keys="image", source_key="image"),
            Orientationd(keys="image", axcodes="RAS"),
            Resized(keys="image", spatial_size=task.resize, mode="trilinear"),
        ]
    )


Predictor = Callable[[torch.Tensor], torch.Tensor]  # (B, 1, 96, 96, 96) -> (B, C, 96, 96, 96)


def segment(path: str, task: Task, predictor: Predictor) -> np.ndarray:
    """Returns a uint8 label volume on the same voxel grid as the NIfTI at `path`."""
    pre = preprocessing(task)
    data = pre({"image": path})

    with torch.no_grad():
        logits = sliding_window_inference(
            data["image"].unsqueeze(0), ROI_SIZE, task.sw_batch_size, predictor, overlap=task.overlap
        )
    # Argmax before inverting: inverting a 1-channel label map with nearest-neighbour is
    # much cheaper than inverting C full-resolution logit maps.
    data["pred"] = logits[0].argmax(dim=0, keepdim=True).float()

    inverted = Invertd(keys="pred", transform=pre, orig_keys="image", nearest_interp=True)(data)
    return inverted["pred"][0].cpu().numpy().round().astype(np.uint8)


def save_mask(mask: np.ndarray, reference: nib.Nifti1Image, path: str) -> None:
    header = reference.header.copy()
    header.set_data_dtype(np.uint8)
    header.set_slope_inter(1, 0)  # CT headers often carry HU rescaling; labels must not be scaled
    nib.save(nib.Nifti1Image(mask, reference.affine, header), path)
