
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
            observation_period_start_date AS obs_start_date,
            observation_period_end_date AS obs_end_date
        FROM observation_period
        GROUP BY person_id, observation_period_start_date, observation_period_end_date
    ) op
    ON co.person_id = op.person_id
        WHERE dl.disorder_without_specifiers = 'major depressive disorder'
           AND co.condition_start_date IS NOT NULL
    GROUP BY co.person_id, p.birth_datetime, op.obs_start_date, op.obs_end_date
    HAVING MIN(co.condition_start_date) >= (p.birth_datetime + INTERVAL '18 years')
        AND op.obs_start_date <= MIN(co.condition_start_date) - INTERVAL '12 months'
        AND op.obs_end_date >= MIN(co.condition_start_date) + INTERVAL '90 days'
),
    psych_ip AS (
        SELECT
            vo.person_id,
            vo.visit_start_date,
            COALESCE(vo.visit_end_date, vo.visit_start_date) AS visit_end_date
        FROM visit_occurrence vo
        WHERE vo.visit_concept_id = 9201
    ),
    cohort_obs AS (
        SELECT
            c.person_id,
            MAX(op.observation_period_end_date) AS obs_end_date
        FROM cohort c
        JOIN observation_period op
            ON op.person_id = c.person_id
        GROUP BY c.person_id
    ),
    inpatient_at_index AS (
        SELECT DISTINCT c.person_id
        FROM cohort c
        JOIN psych_ip pv
            ON pv.person_id = c.person_id
        AND pv.visit_start_date <= c.index_date
        AND pv.visit_end_date   >= c.index_date
    ),
    hosp_90d AS (
        SELECT
            c.person_id,
            MIN(pv.visit_start_date) AS first_hosp_date
        FROM cohort c
        JOIN psych_ip pv
            ON pv.person_id = c.person_id
        AND pv.visit_start_date >  c.index_date
        AND pv.visit_start_date <= c.index_date + INTERVAL '90 days'
        GROUP BY c.person_id
    ),
    base AS (
        SELECT
            c.person_id,
            c.index_date,
            CASE WHEN ai.person_id IS NOT NULL THEN 1 ELSE 0 END                      AS f_inpatient_at_index,
            CASE WHEN h.person_id  IS NOT NULL THEN 1 ELSE 0 END                      AS f_hosp_90d,
            CASE WHEN co.obs_end_date >= c.index_date + INTERVAL '90 days' THEN 1 ELSE 0 END AS f_full_followup
        FROM cohort c
        LEFT JOIN cohort_obs         co ON co.person_id = c.person_id
        LEFT JOIN inpatient_at_index ai ON ai.person_id = c.person_id
        LEFT JOIN hosp_90d           h  ON h.person_id  = c.person_id
    )

    SELECT
        person_id,
        index_date,
        f_hosp_90d AS hospitalized_90d
    FROM base
    WHERE f_inpatient_at_index = 0
    AND (f_hosp_90d = 1 OR f_full_followup = 1)