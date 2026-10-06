SELECT
    co.person_id,
    MIN(co.condition_start_date) AS index_date
FROM condition_occurrence co
JOIN diagnosis_lookup dl
    ON co.condition_concept_id = dl.icd_concept_id
JOIN person p
    ON co.person_id = p.person_id
WHERE dl.disorder_without_specifiers = 'major depressive disorder'
  AND co.condition_start_date IS NOT NULL
GROUP BY co.person_id, p.birth_datetime
HAVING MIN(co.condition_start_date) >= (p.birth_datetime + INTERVAL '18 years');