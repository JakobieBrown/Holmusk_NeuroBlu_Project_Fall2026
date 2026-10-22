import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
import shap
import lightgbm as lgb
from catboost import CatBoostClassifier
from xgboost import XGBClassifier
from sklearn.ensemble import RandomForestClassifier
from sklearn.isotonic import IsotonicRegression
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import (average_precision_score, brier_score_loss, precision_recall_curve,
                             roc_auc_score, roc_curve)
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler

TOP_K_PERCENTS = [1, 5, 10]


# ------------------------------------------------------------- evaluation ----
def evaluate(y, p):
    y = np.asarray(y)
    p = np.asarray(p)
    base = y.mean()
    out = {"n": len(y), "positives": int(y.sum()), "base_rate": base,
           "roc_auc": roc_auc_score(y, p), "pr_auc": average_precision_score(y, p),
           "brier": brier_score_loss(y, p)}
    order = np.argsort(-p, kind="mergesort")
    for k in TOP_K_PERCENTS:
        n_top = max(1, int(round(len(y) * k / 100)))
        hits = y[order[:n_top]].sum()
        out[f"precision_top{k}pct"] = hits / n_top
        out[f"recall_top{k}pct"] = hits / y.sum()
        out[f"lift_top{k}pct"] = (hits / n_top) / base
    return out


def _finish(model, X_val, Y_val, X_test, Y_test):
    """Score validation and test, recalibrate on validation (isotonic), print the metrics table."""
    p_val = model.predict_proba(X_val)[:, 1]
    p_test = model.predict_proba(X_test)[:, 1]
    p_test_cal = IsotonicRegression(out_of_bounds="clip", y_min=0, y_max=1).fit(p_val, Y_val).predict(p_test)
    table = pd.DataFrame({"validation": evaluate(Y_val, p_val),
                          "test": evaluate(Y_test, p_test),
                          "test (recalibrated)": evaluate(Y_test, p_test_cal)}).T
    print(table.T.round(4).to_string())
    return {"model": model, "p_val": p_val, "p_test": p_test, "p_test_cal": p_test_cal,
            "val_pr_auc": table.loc["validation", "pr_auc"], "table": table}


def calibration_table(y, p, n_bins=10):
    df = pd.DataFrame({"y": np.asarray(y), "p": np.asarray(p)})
    df["bin"] = pd.qcut(df["p"].rank(method="first"), n_bins, labels=False)
    return df.groupby("bin").agg(patients=("y", "size"), mean_predicted=("p", "mean"),
                                 observed_rate=("y", "mean")).reset_index()


def bootstrap_ci(y, p, n_boot=100, seed=42):
    rng = np.random.default_rng(seed)
    y, p = np.asarray(y), np.asarray(p)
    rocs, prs = [], []
    for _ in range(n_boot):
        idx = rng.integers(0, len(y), len(y))
        if y[idx].sum() == 0:
            continue
        rocs.append(roc_auc_score(y[idx], p[idx]))
        prs.append(average_precision_score(y[idx], p[idx]))
    return (np.percentile(rocs, [2.5, 97.5]), np.percentile(prs, [2.5, 97.5]))


# ------------------------------------------------------------------ models ----
def logreg_model(X_train, Y_train, X_val, Y_val, X_test, Y_test, feature_names):
    model = make_pipeline(StandardScaler(), LogisticRegression(max_iter=500, C=1.0, random_state=42))
    model.fit(X_train, Y_train)
    return _finish(model, X_val, Y_val, X_test, Y_test)


def randomforest_model(X_train, Y_train, X_val, Y_val, X_test, Y_test, feature_names):
    model = RandomForestClassifier(n_estimators=300, min_samples_leaf=50, max_features="sqrt",
                                   n_jobs=-1, random_state=42)
    model.fit(X_train, Y_train)
    return _finish(model, X_val, Y_val, X_test, Y_test)


def xgboost_model(X_train, Y_train, X_val, Y_val, X_test, Y_test, feature_names):
    params = dict(n_estimators=2000, learning_rate=0.05, max_depth=5, subsample=0.8,
                  colsample_bytree=0.8, min_child_weight=5, tree_method="hist",
                  eval_metric="aucpr", n_jobs=-1, random_state=42)
    try:  # newer xgboost takes early stopping in the constructor
        model = XGBClassifier(early_stopping_rounds=100, **params)
        model.fit(X_train, Y_train, eval_set=[(X_val, Y_val)], verbose=False)
    except TypeError:  # older xgboost takes it in fit()
        model = XGBClassifier(**params)
        model.fit(X_train, Y_train, eval_set=[(X_val, Y_val)], early_stopping_rounds=100, verbose=False)
    return _finish(model, X_val, Y_val, X_test, Y_test)


def lightgbm_model(X_train, Y_train, X_val, Y_val, X_test, Y_test, feature_names):
    model = lgb.LGBMClassifier(n_estimators=2000, learning_rate=0.05, num_leaves=31, min_child_samples=100,
                               subsample=0.8, subsample_freq=1, colsample_bytree=0.8,
                               random_state=42, n_jobs=-1, verbosity=-1)
    model.fit(X_train, Y_train, eval_set=[(X_val, Y_val)], eval_metric="average_precision",
              callbacks=[lgb.early_stopping(100, verbose=False)])
    return _finish(model, X_val, Y_val, X_test, Y_test)


def catboost_model(X_train, Y_train, X_val, Y_val, X_test, Y_test, feature_names):
    model = CatBoostClassifier(iterations=2000, learning_rate=0.05, depth=6, eval_metric="AUC",
                               early_stopping_rounds=100, random_seed=42, verbose=0, allow_writing_files=False)
    model.fit(X_train, Y_train, eval_set=(X_val, Y_val))
    return _finish(model, X_val, Y_val, X_test, Y_test)


# ------------------------------------------------------------------- plots ----
def plot_curves(results, Y_test, filename):
    fig, ax = plt.subplots(1, 2, figsize=(11, 4.5))
    for name, r in results.items():
        fpr, tpr, _ = roc_curve(Y_test, r["p_test"])
        prec, rec, _ = precision_recall_curve(Y_test, r["p_test"])
        ax[0].plot(fpr, tpr, label=f"{name} ({roc_auc_score(Y_test, r['p_test']):.3f})")
        ax[1].plot(rec, prec, label=f"{name} ({average_precision_score(Y_test, r['p_test']):.3f})")
    ax[0].plot([0, 1], [0, 1], "--", color="gray")
    ax[0].set(xlabel="False positive rate", ylabel="True positive rate", title="ROC (test)")
    ax[1].axhline(np.mean(Y_test), ls="--", color="gray")
    ax[1].set(xlabel="Recall", ylabel="Precision", title="Precision-recall (test)")
    for a in ax:
        a.legend(fontsize=8)
    fig.tight_layout()
    fig.savefig(filename, dpi=150)
    plt.close(fig)


def plot_reliability(Y_test, p_raw, p_cal, title, filename):
    fig, ax = plt.subplots(figsize=(5.5, 5))
    for label, p in (("raw", p_raw), ("recalibrated", p_cal)):
        t = calibration_table(Y_test, p)
        ax.plot(t["mean_predicted"], t["observed_rate"], marker="o", label=label)
    top = max(ax.get_xlim()[1], ax.get_ylim()[1])
    ax.plot([0, top], [0, top], "--", color="gray")
    ax.set(xlabel="Mean predicted risk", ylabel="Observed rate", title=title)
    ax.legend()
    fig.tight_layout()
    fig.savefig(filename, dpi=150)
    plt.close(fig)


def shap_plots(model, X_test, name, sample=20000):
    X_s = X_test.sample(n=min(sample, len(X_test)), random_state=42)
    values = shap.TreeExplainer(model).shap_values(X_s)
    if isinstance(values, list):           # older shap: one array per class
        values = values[1]
    elif getattr(values, "ndim", 2) == 3:  # newer shap: (rows, features, classes)
        values = values[:, :, 1]
    for kind in ("bar", "dot"):
        plt.figure()
        shap.summary_plot(values, X_s, plot_type=kind, show=False, max_display=20)
        plt.tight_layout()
        plt.savefig(f"mdd_hosp90_shap_{name}_{kind}.png", dpi=150, bbox_inches="tight")
        plt.close()
    importance = pd.DataFrame({"feature": X_s.columns, "mean_abs_shap": np.abs(values).mean(axis=0)})
    return importance.sort_values("mean_abs_shap", ascending=False)
