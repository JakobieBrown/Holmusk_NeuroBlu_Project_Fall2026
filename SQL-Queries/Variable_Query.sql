
WITH prior_psych_inpatient AS (
    SELECT
        c.person_id,
        c.index_date,
        COUNT(vo.visit_occurrence_id) AS psych_ip_count_all_time,
        SUM(CASE WHEN vo.visit_start_date >= DATEADD(day, -90,  c.index_date) THEN 1 ELSE 0 END) AS psych_ip_count_90d,
        SUM(CASE WHEN vo.visit_start_date >= DATEADD(day, -180, c.index_date) THEN 1 ELSE 0 END) AS psych_ip_count_180d,
        SUM(CASE WHEN vo.visit_start_date >= DATEADD(day, -365, c.index_date) THEN 1 ELSE 0 END) AS psych_ip_count_365d
    FROM cohort(4393589) c
    LEFT JOIN visit_occurrence vo
        ON vo.person_id = c.person_id
       AND vo.visit_concept_id = 9201
       AND vo.visit_start_date < c.index_date
    LEFT JOIN care_site cs
        ON vo.care_site_id = cs.care_site_id
       AND cs.is_psych = 1
    GROUP BY c.person_id, c.index_date
),

phq9_total_ranked AS (
    SELECT
        c.person_id,
        c.index_date,
        m.measurement_date,
        m.value_as_number AS phq9_total_score,
        ROW_NUMBER() OVER (PARTITION BY c.person_id ORDER BY m.measurement_date DESC) AS rn
    FROM cohort(4393589) c
    JOIN measurement m
        ON m.person_id = c.person_id
       AND m.measurement_date < c.index_date
    JOIN measurement_lookup ml
        ON m.measurement_concept_id = ml.measurement_concept_id
       AND ml.scale = 'phq-9'
       AND ml.scale_item = 0
),
phq9_total_latest AS (
    SELECT
        person_id,
        phq9_total_score,
        CASE
            WHEN phq9_total_score BETWEEN 0  AND 4  THEN 'none-minimal'
            WHEN phq9_total_score BETWEEN 5  AND 9  THEN 'mild'
            WHEN phq9_total_score BETWEEN 10 AND 14 THEN 'moderate'
            WHEN phq9_total_score BETWEEN 15 AND 19 THEN 'moderately severe'
            WHEN phq9_total_score BETWEEN 20 AND 27 THEN 'severe'
        END AS phq9_severity_category
    FROM phq9_total_ranked
    WHERE rn = 1
),

phq9_item9_ranked AS (
    SELECT
        c.person_id,
        c.index_date,
        m.value_as_number AS phq9_item9_value,
        ROW_NUMBER() OVER (PARTITION BY c.person_id ORDER BY m.measurement_date DESC) AS rn
    FROM cohort(4393589) c
    JOIN measurement m
        ON m.person_id = c.person_id
       AND m.measurement_date < c.index_date
    JOIN measurement_lookup ml
        ON m.measurement_concept_id = ml.measurement_concept_id
       AND ml.scale = 'phq-9'
       AND ml.scale_item = 9
),
phq9_item9_latest AS (
    SELECT
        person_id,
        phq9_item9_value
    FROM phq9_item9_ranked
    WHERE rn = 1
),

sud_flags AS (
    SELECT
        c.person_id,
        MAX(CASE
                WHEN co.condition_start_date IS NOT NULL
                AND co.condition_end_date IS NULL
                THEN 1 ELSE 0
            END) AS sud_active_flag,
        MAX(CASE WHEN co.condition_start_date IS NOT NULL THEN 1 ELSE 0 END) AS sud_history_flag
    FROM cohort(4393589) c
    LEFT JOIN condition_occurrence co
        ON co.person_id = c.person_id
       AND co.condition_start_date < c.index_date
    LEFT JOIN diagnosis_lookup dl
        ON co.condition_concept_id = dl.icd_concept_id
       AND dl.disorder_group = 'psychoactive substance use disorder'
    WHERE co.condition_occurrence_id IS NULL OR dl.disorder_group IS NOT NULL
    GROUP BY c.person_id
),

personality_disorder_flag AS (
    SELECT
        c.person_id,
        MAX(CASE WHEN co.condition_start_date IS NOT NULL THEN 1 ELSE 0 END) AS personality_disorder_flag
    FROM cohort(4393589) c
    LEFT JOIN condition_occurrence co
        ON co.person_id = c.person_id
       AND co.condition_start_date < c.index_date
    LEFT JOIN diagnosis_lookup dl
        ON co.condition_concept_id = dl.icd_concept_id
       AND dl.disorder_group = 'personality disorder'
    WHERE co.condition_occurrence_id IS NULL OR dl.disorder_group IS NOT NULL
    GROUP BY c.person_id
)

SELECT
    c.person_id,
    c.index_date,
    pi.psych_ip_count_90d,
    pi.psych_ip_count_180d,
    pi.psych_ip_count_365d,
    pi.psych_ip_count_all_time,
    p9.phq9_total_score,
    p9.phq9_severity_category,
    p9i.phq9_item9_value,
    sud.sud_active_flag,
    sud.sud_history_flag,
    pd.personality_disorder_flag
FROM cohort(4393589) c
LEFT JOIN prior_psych_inpatient     pi  ON pi.person_id  = c.person_id
LEFT JOIN phq9_total_latest         p9  ON p9.person_id  = c.person_id
LEFT JOIN phq9_item9_latest         p9i ON p9i.person_id = c.person_id
LEFT JOIN sud_flags                 sud ON sud.person_id = c.person_id
LEFT JOIN personality_disorder_flag pd  ON pd.person_id  = c.person_id;
