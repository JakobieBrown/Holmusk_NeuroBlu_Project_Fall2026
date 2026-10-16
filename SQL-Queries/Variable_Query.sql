
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
       AND vo.visit_start_date <= c.index_date
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
       AND m.measurement_date <= c.index_date
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
       AND m.measurement_date <= c.index_date
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

phq2_total_ranked AS (
    SELECT
        c.person_id,
        c.index_date,
        m.measurement_date,
        m.value_as_number AS phq2_total_score,
        ROW_NUMBER() OVER (PARTITION BY c.person_id ORDER BY m.measurement_date DESC) AS rn
    FROM cohort(4393589) c
    JOIN measurement m
        ON m.person_id = c.person_id
       AND m.measurement_date <= c.index_date
    JOIN measurement_lookup ml
        ON m.measurement_concept_id = ml.measurement_concept_id
       AND ml.scale = 'phq-2'
       AND ml.scale_item = 0
),
phq2_total_latest AS (
    SELECT
        person_id,
        phq2_total_score
    FROM phq2_total_ranked
    WHERE rn = 1
),
phq9_items12_by_date AS (
    SELECT
        c.person_id,
        m.measurement_date,
        MAX(CASE WHEN ml.scale_item = 1 THEN m.value_as_number END) AS item1,
        MAX(CASE WHEN ml.scale_item = 2 THEN m.value_as_number END) AS item2
    FROM cohort(4393589) c
    JOIN measurement m
        ON m.person_id = c.person_id
       AND m.measurement_date <= c.index_date
    JOIN measurement_lookup ml
        ON m.measurement_concept_id = ml.measurement_concept_id
       AND ml.scale = 'phq-9'
       AND ml.scale_item IN (1, 2)
    GROUP BY c.person_id, m.measurement_date
),
phq2_derived_ranked AS (
    SELECT
        person_id,
        item1 + item2 AS phq2_total_score_derived,
        ROW_NUMBER() OVER (PARTITION BY person_id ORDER BY measurement_date DESC) AS rn
    FROM phq9_items12_by_date
    WHERE item1 IS NOT NULL AND item2 IS NOT NULL
),
phq2_derived_latest AS (
    SELECT person_id, phq2_total_score_derived
    FROM phq2_derived_ranked
    WHERE rn = 1
),
phq2_combined AS (
    SELECT
        COALESCE(r.person_id, d.person_id) AS person_id,
        COALESCE(r.phq2_total_score, d.phq2_total_score_derived) AS phq2_total_score
    FROM phq2_total_latest r
    FULL OUTER JOIN phq2_derived_latest d
        ON d.person_id = r.person_id
),
phq2_final AS (
    SELECT
        person_id,
        phq2_total_score,
        CASE
            WHEN phq2_total_score BETWEEN 0 AND 2 THEN 'no depression'
            WHEN phq2_total_score BETWEEN 3 AND 6 THEN 'likely depression'
        END AS phq2_severity_category
    FROM phq2_combined
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
       AND co.condition_start_date <= c.index_date
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
       AND co.condition_start_date <= c.index_date
    LEFT JOIN diagnosis_lookup dl
        ON co.condition_concept_id = dl.icd_concept_id
       AND dl.disorder_group = 'personality disorder'
    WHERE co.condition_occurrence_id IS NULL OR dl.disorder_group IS NOT NULL
    GROUP BY c.person_id
),
cssrs_items AS (
    SELECT
        c.person_id,
        m.measurement_date,
        m.custom2_str,
        m.value_as_number,
        m.value_as_concept_id
    FROM cohort(4393589) c
    JOIN measurement m
        ON m.person_id = c.person_id
       AND m.measurement_date <= c.index_date
       AND m.custom2_str IN (
           'c-ssrs: si_wishtobedead_1month',
           'c-ssrs: si_nonspecificthoughts_1month',
           'c-ssrs: si_methods_noplan_nointent_1month',
           'c-ssrs: si_intent_noplan_1month',
           'c-ssrs: si_intent_plan_1month',
           'c-ssrs: si_mostsevere_1month'
       )
),
cssrs_latest_date AS (
    SELECT person_id, MAX(measurement_date) AS last_cssrs_date
    FROM cssrs_items
    GROUP BY person_id
),
cssrs_table AS (
    SELECT
        i.person_id,
        MAX(CASE WHEN i.custom2_str = 'c-ssrs: si_wishtobedead_1month'
                 THEN CASE WHEN i.value_as_concept_id = 45877994 THEN 1
                           WHEN i.value_as_concept_id = 45878245 THEN 0 END
            END) AS cssrs_wish_to_be_dead_1m,
        MAX(CASE WHEN i.custom2_str = 'c-ssrs: si_nonspecificthoughts_1month'
                 THEN CASE WHEN i.value_as_concept_id = 45877994 THEN 1
                           WHEN i.value_as_concept_id = 45878245 THEN 0 END
            END) AS cssrs_nonspecific_thoughts_1m,
        MAX(CASE WHEN i.custom2_str = 'c-ssrs: si_methods_noplan_nointent_1month'
                 THEN CASE WHEN i.value_as_concept_id = 45877994 THEN 1
                           WHEN i.value_as_concept_id = 45878245 THEN 0 END
            END) AS cssrs_si_methods_noplan_nointent_1m,
        MAX(CASE WHEN i.custom2_str = 'c-ssrs: si_intent_noplan_1month'
                 THEN CASE WHEN i.value_as_concept_id = 45877994 THEN 1
                           WHEN i.value_as_concept_id = 45878245 THEN 0 END
            END) AS cssrs_si_intent_noplan_1m,
        MAX(CASE WHEN i.custom2_str = 'c-ssrs: si_intent_plan_1month'
                 THEN CASE WHEN i.value_as_concept_id = 45877994 THEN 1
                           WHEN i.value_as_concept_id = 45878245 THEN 0 END
            END) AS cssrs_si_intent_plan_1m,
        MAX(CASE WHEN i.custom2_str = 'c-ssrs: si_mostsevere_1month'
                 THEN i.value_as_number
            END) AS cssrs_most_severe_si_1m
    FROM cssrs_items i
    JOIN cssrs_latest_date d
        ON d.person_id = i.person_id
       AND i.measurement_date = d.last_cssrs_date
    GROUP BY i.person_id
),
cssrs_final AS (
    SELECT
        t.*,
        CASE
            WHEN t.cssrs_si_intent_plan_1m = 1               THEN 5  -- intent with specific plan
            WHEN t.cssrs_si_intent_noplan_1m = 1             THEN 4  -- some intent, no plan
            WHEN t.cssrs_si_methods_noplan_nointent_1m = 1   THEN 3  -- methods, no plan or intent
            WHEN t.cssrs_nonspecific_thoughts_1m = 1         THEN 2  -- non-specific active thoughts
            WHEN t.cssrs_wish_to_be_dead_1m = 1              THEN 1  -- wish to be dead
            WHEN t.cssrs_wish_to_be_dead_1m = 0
             AND t.cssrs_nonspecific_thoughts_1m = 0         THEN 0  -- screened negative
        END AS cssrs_most_severe_si_derived
    FROM cssrs_table t
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
    p2.phq2_total_score,
    p2.phq2_severity_category,
    COALESCE(sud.sud_active_flag, 0)                   AS sud_active_flag,
    COALESCE(sud.sud_history_flag, 0)                  AS sud_history_flag,
    COALESCE(pd.personality_disorder_flag, 0)          AS personality_disorder_flag,
    cf.cssrs_wish_to_be_dead_1m,
    cf.cssrs_nonspecific_thoughts_1m,
    cf.cssrs_si_methods_noplan_nointent_1m,
    cf.cssrs_si_intent_noplan_1m,
    cf.cssrs_si_intent_plan_1m,
    COALESCE(cf.cssrs_most_severe_si_1m, cf.cssrs_most_severe_si_derived) AS cssrs_most_severe_si_1m
    
FROM cohort(4393589) c
LEFT JOIN prior_psych_inpatient     pi  ON pi.person_id  = c.person_id
LEFT JOIN phq2_final                p2  ON p2.person_id  = c.person_id
LEFT JOIN phq9_total_latest         p9  ON p9.person_id  = c.person_id
LEFT JOIN phq9_item9_latest         p9i ON p9i.person_id = c.person_id
LEFT JOIN sud_flags                 sud ON sud.person_id = c.person_id
LEFT JOIN personality_disorder_flag pd  ON pd.person_id  = c.person_id
LEFT JOIN cssrs_final cf ON cf.person_id = c.person_id