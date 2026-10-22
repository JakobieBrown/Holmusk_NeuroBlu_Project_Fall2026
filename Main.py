import pandas as pd
from sklearn.model_selection import GroupShuffleSplit

setattr(pd, "Int64Index", pd.Index)

setattr(pd, "Float64Index", pd.Index)

import neuroblu as nb
import numpy as np
from sklearn.impute import SimpleImputer
from sklearn.metrics import roc_auc_score
import Models
import Queries

# ---- settings ----
LABEL = "hospitalized_90d"
ID = "person_id"
DATE = "index_date"

# text categories -> ordered numbers (anything not listed here becomes null)
CATEGORY_ORDER = {"phq9_severity_category": {"none-minimal": 0, "mild": 1, "moderate": 2,
                                             "moderately severe": 3, "severe": 4},
                  "phq2_severity_category": {"no depression": 0, "likely depression": 1}}

# new missingness column -> column whose nulls mean "never screened"
MISSING_INDICATORS = {"phq9_total_missing": "phq9_total_score",
                      "phq9_item9_missing": "phq9_item9_value",
                      "cssrs_missing": "cssrs_wish_to_be_dead_1m"}

SPLIT_MODE = "temporal"      # "temporal" (train on earlier index dates) or "random" (grouped by person_id)
TRAIN_FRAC = 0.60
VAL_FRAC = 0.20              # test = the remainder
APPLY_TAIL_CUTOFF = True     # negatives need full follow-up but positives don't, so the latest index dates are all positives
USE_RANDOM_FOREST = False    # slow on millions of rows
LEAKAGE_AUC_FLAG = 0.75      # single-feature AUC above this is flagged
SUSPICIOUS_TEST_AUC = 0.90   # test ROC-AUC above this is flagged


def load_dataframe(name, sql):

    #load dataframe and save it if it isnt saved already

    try:

        return nb.get_df(name)

    except Exception:

        nb.save_df(nb.get_query(sql), name, 1)

        return nb.get_df(name)


def main():

    print("MDD 90-day psychiatric hospitalization model")

    features = load_dataframe("MDD_Hosp90_Features", Queries.Master_Features())

    labels = load_dataframe("MDD_Hosp90_Labels", Queries.Label_Query())

    features[DATE] = pd.to_datetime(features[DATE])

    labels[DATE] = pd.to_datetime(labels[DATE])

    dataframe = features.merge(labels[[ID, DATE, LABEL]], on=[ID, DATE], how="inner")

    print(f"{len(features):,} feature rows | {len(labels):,} labeled rows | {len(dataframe):,} after matching")

    if len(labels) > len(dataframe):

        print(f"WARNING: {len(labels) - len(dataframe):,} labeled rows have no matching feature row, check that both queries use the same cohort")

    dataframe[LABEL] = dataframe[LABEL].astype(int)

    #encode ordered text categories (e.g. PHQ-9 severity)

    for col, order in CATEGORY_ORDER.items():

        if col in dataframe.columns:

            unmapped = dataframe[col].notna() & ~dataframe[col].isin(order.keys())

            if unmapped.any():

                print(f"WARNING: {unmapped.sum():,} values in {col} are not in CATEGORY_ORDER and become null: {dataframe.loc[unmapped, col].unique()[:5]}")

            dataframe[col] = dataframe[col].map(order)

    ### diagnostics

    print(f"{len(dataframe):,} rows | positives {int(dataframe[LABEL].sum()):,} ({100 * dataframe[LABEL].mean():.2f}%)")

    duplicates = dataframe[ID].duplicated().sum()

    if duplicates:

        print(f"WARNING: {duplicates:,} duplicate {ID} rows, expected one row per person")

    by_year = dataframe.groupby(dataframe[DATE].dt.year)[LABEL].agg(["size", "mean"])

    by_year["mean"] = (100 * by_year["mean"]).round(2)

    print("Rows and positive rate (%) by index year")

    print(by_year.rename(columns={"size": "rows", "mean": "pos_rate_pct"}))

    ###

    if APPLY_TAIL_CUTOFF:

        last_negative = dataframe.loc[dataframe[LABEL] == 0, DATE].max()

        before = len(dataframe)

        dataframe = dataframe[dataframe[DATE] <= last_negative]

        print(f"Tail cutoff: latest negative index date is {last_negative.date()}, dropped {before - len(dataframe):,} later rows")

    dataframe = dataframe.reset_index(drop=True)

    #split data into predictors and outcome measurements

    drop_cols = [ID, DATE, LABEL]
 
    PredictorsX = dataframe.drop(columns=drop_cols)

    PredictorsX = PredictorsX.astype(float)

    for new_col, source_col in MISSING_INDICATORS.items():

        if source_col in PredictorsX.columns and PredictorsX[source_col].isna().any():

            PredictorsX[new_col] = PredictorsX[source_col].isna().astype(float)

    TargetY = dataframe[LABEL]

    feature_names = PredictorsX.columns.tolist()

    person_ids = dataframe[ID]

    if SPLIT_MODE == "temporal":

        q_train = dataframe[DATE].quantile(TRAIN_FRAC)

        q_val = dataframe[DATE].quantile(TRAIN_FRAC + VAL_FRAC)

        train_mask = (dataframe[DATE] <= q_train).values

        val_mask = ((dataframe[DATE] > q_train) & (dataframe[DATE] <= q_val)).values

        test_mask = (dataframe[DATE] > q_val).values

    else:

        gss = GroupShuffleSplit(n_splits=1, test_size=1 - TRAIN_FRAC, random_state=42)

        train_idx, rest_idx = next(gss.split(dataframe, TargetY, groups=person_ids))

        gss2 = GroupShuffleSplit(n_splits=1, test_size=(1 - TRAIN_FRAC - VAL_FRAC) / (1 - TRAIN_FRAC), random_state=42)

        val_rel, test_rel = next(gss2.split(dataframe.iloc[rest_idx], TargetY.iloc[rest_idx], groups=person_ids.iloc[rest_idx]))

        train_mask = np.zeros(len(dataframe), dtype=bool)

        val_mask = np.zeros(len(dataframe), dtype=bool)

        test_mask = np.zeros(len(dataframe), dtype=bool)

        train_mask[train_idx] = True

        val_mask[rest_idx[val_rel]] = True

        test_mask[rest_idx[test_rel]] = True

    X_train, X_val, X_test = PredictorsX[train_mask], PredictorsX[val_mask], PredictorsX[test_mask]

    Y_train, Y_val, Y_test = TargetY[train_mask], TargetY[val_mask], TargetY[test_mask]

    for split_name, mask in (("train", train_mask), ("val", val_mask), ("test", test_mask)):

        print(f"{split_name:<5} {mask.sum():>10,} rows | positives {int(TargetY[mask].sum()):>8,} ({100 * TargetY[mask].mean():.2f}%) | "
              f"{dataframe.loc[mask, DATE].min().date()} to {dataframe.loc[mask, DATE].max().date()}")

    #correlation to check for data leakage (single-feature AUC on the training split, nulls skipped)

    leak_rows = []

    for col in X_train.columns:

        present = X_train[col].notna().values

        if present.sum() < 500 or Y_train[present].nunique() < 2 or X_train[col][present].nunique() < 2:

            continue

        auc = roc_auc_score(Y_train[present], X_train[col][present])

        leak_rows.append((col, max(auc, 1 - auc), int(present.sum())))

    leak = pd.DataFrame(leak_rows, columns=["feature", "single_feature_auc", "non_null_rows"]).sort_values("single_feature_auc", ascending=False)

    print("\n--- Single-feature AUC with Target (train) ---")

    print(leak.head(10).to_string(index=False))

    flagged = leak[leak["single_feature_auc"] > LEAKAGE_AUC_FLAG]["feature"].tolist()

    if flagged:

        print(f"WARNING: above {LEAKAGE_AUC_FLAG}, check for leakage: {flagged}")

    # Drop columns with fewer than 5 non-zero values, and columns that are entirely null in training

    sparse_cols = [col for col in X_train.columns if X_train[col].isna().all() or (X_train[col].fillna(0) != 0).sum() < 5]

    if sparse_cols:

        print(f"Dropping {len(sparse_cols)} sparse columns: {sparse_cols}")

        X_train = X_train.drop(columns=sparse_cols)

        X_val = X_val.drop(columns=sparse_cols)

        X_test = X_test.drop(columns=sparse_cols)

        feature_names = [f for f in feature_names if f not in sparse_cols]

    imputer = SimpleImputer(strategy="median")

    X_train = pd.DataFrame(imputer.fit_transform(X_train), columns=feature_names)

    X_val = pd.DataFrame(imputer.transform(X_val), columns=feature_names)

    X_test = pd.DataFrame(imputer.transform(X_test), columns=feature_names)

    Y_train, Y_val, Y_test = Y_train.reset_index(drop=True), Y_val.reset_index(drop=True), Y_test.reset_index(drop=True)

    print(feature_names)

    print("Rows and Columns after preprocessing")

    print(X_train.shape)

    model_functions = {"logreg": Models.logreg_model,
                       "xgboost": Models.xgboost_model,
                       "lightgbm": Models.lightgbm_model,
                       "catboost": Models.catboost_model}

    if USE_RANDOM_FOREST:

        model_functions["randomforest"] = Models.randomforest_model

    results = {}

    for name, model_function in model_functions.items():

        print(f"\n--- {name} ---")

        results[name] = model_function(X_train, Y_train, X_val, Y_val, X_test, Y_test, feature_names)

    #pick the best model on validation PR-AUC and report it

    best = max(results, key=lambda m: results[m]["val_pr_auc"])

    print(f"\nBest model on validation PR-AUC: {best}")

    roc_ci, pr_ci = Models.bootstrap_ci(Y_test, results[best]["p_test"])

    print(f"Test ROC-AUC 95% CI {roc_ci[0]:.4f}-{roc_ci[1]:.4f} | PR-AUC 95% CI {pr_ci[0]:.4f}-{pr_ci[1]:.4f}")

    if results[best]["table"].loc["test", "roc_auc"] > SUSPICIOUS_TEST_AUC:

        print("WARNING: test ROC-AUC is unusually high for this task, check the leakage table and SHAP for features that use post-index information")

    Models.plot_curves(results, Y_test, "mdd_hosp90_curves_test.png")

    Models.plot_reliability(Y_test, results[best]["p_test"], results[best]["p_test_cal"],
                            f"Calibration ({best}, test)", f"mdd_hosp90_reliability_{best}.png")

    if best in ("xgboost", "lightgbm", "catboost"):

        importance = Models.shap_plots(results[best]["model"], X_test, best)

        print("\n--- Top SHAP features ---")

        print(importance.head(10).to_string(index=False))

if __name__ == "__main__":

    main()
