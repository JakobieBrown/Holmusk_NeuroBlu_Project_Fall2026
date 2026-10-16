# Predictive modelling of clinical outcomes in Major Depressive Disorder 

**USI CIS 477 & CS483 Capstone — Fall 2026**
**Client:** Holmusk (NeuroBlu Platform)

---

## Project Overview

This project builds a machine learning pipeline to predict 90-day hospitalisation risk in adult patients diagnosed with Major Depressive Disorder (MDD), using inpatient admissions following outpatient visits as the target outcome.

---

## Team

| Name | Role |
|---|---|
| Jakobie Brown | Team Lead, Documentation + Model Engineer + Research + SQL |
| Kateryna Saienko | Documentation + Model Engineer + Research + SQL |
| Aaron Slather | Documentation + Model Engineer + Research + SQL |

---

## Research Question

> Among adult patients diagnosed with Major Depressive Disorder, which clinical variables (medications, lab values, diagnoses, procedures, and demographics) are predictive of inpatient hospitalisation within 90 days of an outpatient visit?

---

# Data

This project uses the **OMOP Common Data Model** via the NeuroBlu platform. Key tables include:

| Table | Purpose |
|---|---|
| `person` | Demographics (age, sex, race/ethnicity) |
| `condition_occurrence` | Diagnoses - define the cohort, gather data for variables  |
| `measurement` | Gather variables from PHQ-9 and C-SSRS |
| `measurement_lookup` | Concept definitions for measurement values and units |
| `visit_occurance` | Gather previous psychiatric inpatient visits |
| `care_site` | Determine inpatient visit is with a psychiatric unit |
| `diagnosis_lookup` | Concept definitions for diagnoses |

### Cohort Definition

- **Inclusion:** Patients with diagnosis for MDD 
- **Index Date:** First diagnosis date
- **Requirements:** Minimum Age 18 at diagnosis

### Features

- **Psychiatric Inpatient Visits:** Frequency, Recency
- **PHQ-9 Data:** Total score, Severity, Item 9 response
- **Substance Use Disorder Diagnoses:** Active, History
- **Personality Disorder:** Active
- **C-SSRS Data:** Responses to `Wish to be Dead`, `Non-Specific Active Suicidal Thoughts`, `Active Suicidal Ideation with Any Methods (Not Plan) without Intent to Act`, `Active Suicidal Ideation with Some Intent to Act without Specific Plan`, and `Active Suicidal Ideation with Specific Plan and Intent`, as well as Most Severe Ideation score.

---

## Project Timeline

#### Discovery
**Sept. 7 - Sept. 20**
- Data sources and preprocessing
- Cohort Definition

#### Preparation
**Sept. 21 - Oct. 11**
- Data cleaning 
- Feature Engineering

#### Development
**Oct. 12 - Nov. 8**
- Modeling
- Pipeline Implementation

#### Finilization
**Nov. 9 - Nov. 22**
- Visualization
- Reporting

---

## Background

This project is part of a multi-semester research collaboration between USI and Holmusk:

- **Fall 2024 (CS483):** Drug lookup tool, SQL query exploration, OMOP data model research
- **Spring 2025 (CS461/CS483):** ML model to detect and clean invalid `days_supply` values in drug records using Isolation Forest
- **Fall 2025:** Software development iteration, anomaly detection on lab measurements (temperature, BMI, systolic BP, pulse rate)
- **Spring 2026 (CS483):** Identifying outcome drivers in cognitive decline
- **Fall 2026 (CS483):** Predicting hospitalization within 90 days for patients with MDD - current semester