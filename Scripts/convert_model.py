#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""
Convert all-MiniLM-L6-v2 to CoreML format for TabMail iOS.

Usage:
    pip install coremltools transformers torch
    python Scripts/convert_model.py
    xcrun coremlcompiler compile AllMiniLML6v2.mlpackage TabMail/Resources/

This produces AllMiniLML6v2.mlmodelc which should be placed in TabMail/Resources/.
The tokenizer.json should also be copied to TabMail/Resources/.
"""

import coremltools as ct
import torch
from transformers import AutoModel, AutoTokenizer
import numpy as np

MODEL_NAME = "sentence-transformers/all-MiniLM-L6-v2"
MAX_SEQ_LENGTH = 256
OUTPUT_NAME = "AllMiniLML6v2"


def mean_pooling(model_output, attention_mask):
    """Mean pooling - take attention mask into account for correct averaging."""
    token_embeddings = model_output[0]
    input_mask_expanded = attention_mask.unsqueeze(-1).expand(token_embeddings.size()).float()
    return torch.sum(token_embeddings * input_mask_expanded, 1) / torch.clamp(
        input_mask_expanded.sum(1), min=1e-9
    )


class MiniLMWrapper(torch.nn.Module):
    """Wrapper that returns mean-pooled + L2-normalized sentence embeddings."""

    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, input_ids, attention_mask):
        output = self.model(input_ids=input_ids, attention_mask=attention_mask)
        embeddings = mean_pooling(output, attention_mask)
        # L2 normalize
        embeddings = torch.nn.functional.normalize(embeddings, p=2, dim=1)
        return embeddings


def main():
    print(f"Loading {MODEL_NAME}...")
    tokenizer = AutoTokenizer.from_pretrained(MODEL_NAME)
    model = AutoModel.from_pretrained(MODEL_NAME)
    model.eval()

    wrapper = MiniLMWrapper(model)

    # Dummy inputs for tracing
    dummy_input_ids = torch.zeros(1, MAX_SEQ_LENGTH, dtype=torch.int32)
    dummy_attention_mask = torch.zeros(1, MAX_SEQ_LENGTH, dtype=torch.int32)

    print("Tracing model...")
    traced = torch.jit.trace(wrapper, (dummy_input_ids, dummy_attention_mask))

    print("Converting to CoreML...")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, MAX_SEQ_LENGTH), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, MAX_SEQ_LENGTH), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="sentence_embedding")],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS17,
    )

    # Save as mlpackage
    output_path = f"{OUTPUT_NAME}.mlpackage"
    mlmodel.save(output_path)
    print(f"Saved {output_path}")

    # Also save tokenizer.json for bundling
    tokenizer.save_pretrained(".")
    print("Saved tokenizer.json")

    print(f"\nNext steps:")
    print(f"  xcrun coremlcompiler compile {output_path} TabMail/Resources/")
    print(f"  cp tokenizer.json TabMail/Resources/")


if __name__ == "__main__":
    main()
