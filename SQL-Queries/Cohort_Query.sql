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