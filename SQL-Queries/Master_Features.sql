WITH cohort AS (
    SELECT
    co.person_id,
    MIN(co.condition_start_date) AS index_date
    FROM condition_occurrence co
    JOIN diagnosis_lookup dl
        ON co.condition_concept_id = dl.icd_concept_id
    JOIN person p
        ON co.person_id = p.person_id
    JOIN (
        SELECT
            person_id,
            MIN(observation_period_start_date) AS obs_start_date
        FROM observation_period
        GROUP BY person_id
    ) op
    ON co.person_id = op.person_id
        WHERE dl.disorder_without_specifiers = 'major depressive disorder'
            AND co.condition_start_date IS NOT NULL
    GROUP BY co.person_id, p.birth_datetime, op.obs_start_date
    HAVING MIN(co.condition_start_date) >= (p.birth_datetime + INTERVAL '18 years')
        AND op.obs_start_date <= MIN(co.condition_start_date) - INTERVAL '12 months'
),
psych_ip AS (
    SELECT
        vo.person_id,
        vo.visit_start_date,
        COALESCE(vo.visit_end_date, vo.visit_start_date) AS visit_end_date
    FROM visit_occurrence vo
    JOIN care_site cs
        ON vo.care_site_id = cs.care_site_id
    WHERE vo.visit_concept_id = 9201
      AND cs.is_psych = 1
),
prior_psych_inpatient AS (
SELECT
        c.person_id,
        c.index_date,
        SUM(CASE WHEN pv.visit_start_date >= c.index_date - INTERVAL '90 days' THEN 1 ELSE 0 END) AS psych_ip_count_90d,
        SUM(CASE WHEN pv.visit_start_date >= c.index_date - INTERVAL '180 days' THEN 1 ELSE 0 END) AS psych_ip_count_180d,
        SUM(CASE WHEN pv.visit_start_date >= c.index_date - INTERVAL '365 days' THEN 1 ELSE 0 END) AS psych_ip_count_365d
    FROM cohort c
    LEFT JOIN psych_ip pv
        ON pv.person_id = c.person_id
       AND pv.visit_start_date <= c.index_date
    GROUP BY c.person_id, c.index_date
),

phq9_total_ranked AS (
    SELECT
        c.person_id,
        c.index_date,
        m.measurement_date,
        m.value_as_number AS phq9_total_score,
        ROW_NUMBER() OVER (PARTITION BY c.person_id ORDER BY m.measurement_date DESC) AS rn
    FROM cohort c
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
    FROM cohort c
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

sud_flags AS (
    SELECT
        c.person_id,
        MAX(CASE
                WHEN co.condition_start_date IS NOT NULL
                AND (co.condition_end_date IS NULL OR co.condition_end_date > c.index_date)
                THEN 1 ELSE 0
            END) AS sud_active_flag,
        MAX(CASE WHEN co.condition_start_date IS NOT NULL THEN 1 ELSE 0 END) AS sud_history_flag
    FROM cohort c
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
    FROM cohort c
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
    FROM cohort c
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
    p9.phq9_total_score,
    p9.phq9_severity_category,
    p9i.phq9_item9_value,
    COALESCE(sud.sud_active_flag, 0)                   AS sud_active_flag,
    COALESCE(sud.sud_history_flag, 0)                  AS sud_history_flag,
    COALESCE(pd.personality_disorder_flag, 0)          AS personality_disorder_flag,
    cf.cssrs_wish_to_be_dead_1m,
    cf.cssrs_nonspecific_thoughts_1m,
    cf.cssrs_si_methods_noplan_nointent_1m,
    cf.cssrs_si_intent_noplan_1m,
    cf.cssrs_si_intent_plan_1m,
    COALESCE(cf.cssrs_most_severe_si_1m, cf.cssrs_most_severe_si_derived) AS cssrs_most_severe_si_1m
    
FROM cohort c
LEFT JOIN prior_psych_inpatient     pi  ON pi.person_id  = c.person_id
LEFT JOIN phq9_total_latest         p9  ON p9.person_id  = c.person_id
LEFT JOIN phq9_item9_latest         p9i ON p9i.person_id = c.person_id
LEFT JOIN sud_flags                 sud ON sud.person_id = c.person_id
LEFT JOIN personality_disorder_flag pd  ON pd.person_id  = c.person_id
LEFT JOIN cssrs_final cf ON cf.person_id = c.person_id