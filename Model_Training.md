# Training the NeuroSense XGBoost model

Train a binary classifier to detect tremor in a 10-second wrist accelerometer window. The first version targets the Apple Watch’s nominal 50 Hz stream. The current backend uses a signal-quality gate and spectral rules in [`score.py`](backend/app/sense/score.py). Use those rules as the baseline. Keep the existing 0–100 intensity score and its confidence band separate from the classifier’s probability of tremor.

## 1. Prepare the motion data and labels

- Download [PADS v1.0.0](https://physionet.org/content/parkinsons-disease-smartwatch/1.0.0/) for research and prototyping. Locate the directory containing both `patients/` and `movement/timeseries/`. PADS records wrist acceleration in g at 100 Hz. Review the dataset’s noncommercial license before reusing or distributing material. [PADS license](https://physionet.org/content/parkinsons-disease-smartwatch/view-license/1.0.0/)
- Use PADS to exercise data loading, segmentation and feature extraction. Its participant diagnoses and movement-task names are metadata. They do not establish whether an individual window contains tremor.
- Build the supervised set from labeled wrist windows, including real tremor, quiet periods and challenging negatives such as walking, writing, eating and brushing. Have reviewers label each window `tremor`, `not_tremor` or `unsure`. Write down the label criteria and adjudicate disagreements. Keep uncertain windows for abstention analysis and exclude them from binary fitting.
- Collect raw windows and labels in a dedicated, approved training dataset with pseudonymous participant IDs. The application’s [review queue](backend/app/schemas.py) stores score results and reviews a selected subset of windows. The main SQLite score history does not retain the raw accelerometer arrays needed to reconstruct features. Keep raw recordings and participant manifests out of Git.

Run the existing PADS summary from the repository root. Adjust `PADS_ROOT` if your extract has a different directory name.

```bash
cd backend
PADS_ROOT=data/pads/raw/pads-parkinsons-disease-smartwatch-dataset-1.0.0
test -d "$PADS_ROOT/patients" && test -d "$PADS_ROOT/movement/timeseries" &&
  PYTHONPATH=. uv run --locked python ../scripts/eval_pads.py "$PADS_ROOT"
```

This is a diagnostic summary of the current rules. The model comparison in step 4 uses labeled windows.

## 2. Build the feature table

1. Parse accelerometer XYZ in g. The PADS loader in [`eval_pads.py`](scripts/eval_pads.py) reads these columns with `x[:, 1:4]`. Use the timestamps and sample rate to detect gaps. For regular PADS traces, apply antialiasing before downsampling from 100 Hz to 50 Hz. Segment each wrist and recording independently into nonoverlapping 10-second windows. Keep capture source, task and session in the manifest for evaluation.
2. Apply the current quality checks for malformed, short, clipped, flat or noisy signals. Keep counts and reasons for rejected windows. Separate those checks from the current `voluntary_movement` rule, which is part of the comparator. Keep valid voluntary-motion windows in the training set.
3. Extract features from the detrended XYZ signal. Use Welch spectra with 2-second segments and sum power across axes, following [`score.py`](backend/app/sense/score.py). Share the feature extractor and its settings between training and inference.

| Feature column | Definition |
| --- | --- |
| `low_rms_g` | Square root of integrated power in 0.3–3 Hz |
| `tremor_rms_g` | Square root of integrated power in 3–12 Hz |
| `hf_rms_g` | Square root of integrated power in 12–24 Hz |
| `dominant_hz` | Strongest spectral bin in the 3–12 Hz band |
| `peak_concentration` | Share of 3–12 Hz power within 1 Hz of the dominant peak, using the band limits |
| `frequency_drift_hz` | Standard deviation of the dominant tremor-band frequency across three equal subwindows |

Write `backend/data/training/windows.csv` with one row per quality-passing window. Include `participant_id`, a unique `window_id`, `label`, and the six features above. Save window provenance and rejected-window counts alongside the table. Record how the extractor handles zero band power and invalid values. Keep diagnoses, participant identifiers, task names and wrist labels out of the feature matrix.

## 3. Train a first candidate

Run this from `backend/` after preparing the CSV. It creates roughly 60% train, 20% validation and 20% test splits, grouped by participant. Both wrists and all recording sessions from a participant stay together. Check class and participant counts in every split. Keep the test participants fixed for later tuning runs. [Grouped stratification in scikit-learn](https://scikit-learn.org/stable/modules/generated/sklearn.model_selection.StratifiedGroupKFold.html)

The command uses the CPU-only XGBoost package in a temporary environment. Use `xgboost` if a CPU-only wheel is unavailable for your platform. [XGBoost installation](https://xgboost.readthedocs.io/en/stable/install.html) · [uv script dependencies](https://docs.astral.sh/uv/guides/scripts/)

```bash
uv run --no-project --python 3.13 --with xgboost-cpu --with scikit-learn --with pandas python - <<'PY'
import importlib.metadata
import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.metrics import average_precision_score
from sklearn.model_selection import StratifiedGroupKFold
from xgboost import XGBClassifier

seed = 42
features = [
    "low_rms_g", "tremor_rms_g", "hf_rms_g", "dominant_hz",
    "peak_concentration", "frequency_drift_hz",
]
labels = {"not_tremor": 0, "tremor": 1}
data = pd.read_csv("data/training/windows.csv", dtype={"participant_id": str, "window_id": str})
if data["label"].isna().any() or not set(data["label"]) <= {*labels, "unsure"}:
    raise ValueError("Every row must have a valid reviewer label")
data = data[data["label"].isin(labels)].reset_index(drop=True)
x = data[features]
y = data["label"].map(labels)
groups = data["participant_id"]
if groups.isna().any() or data["window_id"].isna().any() or not data["window_id"].is_unique:
    raise ValueError("Participant IDs are required, and window IDs must be unique")
if not np.isfinite(x.to_numpy(dtype=float)).all():
    raise ValueError("Resolve missing or nonfinite features before fitting")

outer = StratifiedGroupKFold(n_splits=5, shuffle=True, random_state=seed)
inner = StratifiedGroupKFold(n_splits=4, shuffle=True, random_state=seed)
dev, test = next(outer.split(x, y, groups))
train_rel, val_rel = next(inner.split(x.iloc[dev], y.iloc[dev], groups.iloc[dev]))
train, val = dev[train_rel], dev[val_rel]

splits = {"train": train, "validation": val, "test": test}
participants = {name: set(groups.iloc[idx]) for name, idx in splits.items()}
for name, idx in splits.items():
    if y.iloc[idx].nunique() != 2:
        raise ValueError(f"{name} needs examples of both classes from its own participants")
    print(name, "participants", len(participants[name]), "windows by label", y.iloc[idx].value_counts().to_dict())
assert sum(map(len, participants.values())) == len(set.union(*participants.values()))

model = XGBClassifier(
    objective="binary:logistic", tree_method="hist", eval_metric="aucpr",
    n_estimators=500, max_depth=3, learning_rate=0.05,
    early_stopping_rounds=25, random_state=seed, n_jobs=4,
)
model.fit(x.iloc[train], y.iloc[train], eval_set=[(x.iloc[val], y.iloc[val])], verbose=False)
val_probs = model.predict_proba(x.iloc[val])[:, 1]
print("Validation average precision", round(average_precision_score(y.iloc[val], val_probs), 4))

out = Path("data/training/candidate")
out.mkdir(parents=True, exist_ok=False)
model.save_model(str(out / "tremor.ubj"))
manifest = pd.concat([data.iloc[idx][["window_id", "participant_id"]].assign(split=name)
                      for name, idx in splits.items()])
manifest.to_csv(out / "splits.csv", index=False)
metadata = {
    "features": features, "labels": labels, "sample_rate_hz": 50, "window_seconds": 10,
    "seed": seed, "best_iteration": model.best_iteration, "python": sys.version.split()[0],
    "packages": {name: importlib.metadata.version(name) for name in
                 ("xgboost-cpu", "scikit-learn", "pandas", "numpy", "scipy")},
}
(out / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
PY
```

When using the full XGBoost package, change `xgboost-cpu` to `xgboost` in both the command and the package-version list. Use a fresh artifact directory for each run. The validation set controls early stopping. The test rows are recorded in the manifest without scoring them during training. [XGBoost’s estimator interface](https://xgboost.readthedocs.io/en/stable/python/sklearn_estimator.html)

## 4. Evaluate and decide whether to integrate

1. Use the validation participants to choose tuning settings and cutoffs for tremor, no tremor and abstain. The class probabilities need separate validation if they will be interpreted as calibrated confidence. For repeated tuning, use grouped cross-validation within the development set and reuse the saved test participant IDs.
2. Freeze the features, model and cutoffs. Evaluate once on the held-out participants from `splits.csv`. Compare with the current spectral rules on the same labeled windows and quality gate. For a binary baseline comparison, choose a 0–100 score cutoff on validation and count existing rule refusals as abstentions. Report the model’s average precision and compare sensitivity, specificity, false positives during voluntary activity and coverage. Show quality refusals and classifier abstentions separately.
3. Report results by activity and capture source, and estimate uncertainty by resampling participants rather than individual windows. Validate on a separately collected set from the intended Apple Watch workflow before changing runtime behavior.
4. Save the feature schema, source revision, dataset versions, split manifest, package versions, thresholds and evaluation report with the model. Load the artifact in a fresh process and check that predictions match on fixed inputs. Keep the existing scorer as the fallback during any later backend integration. An abstention should continue to return `insufficient_data` without a numeric score.
