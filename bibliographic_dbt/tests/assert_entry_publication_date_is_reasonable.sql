-- This test checks if any publication dates are suspiciously far in the future
-- or too far in the past (e.g., before 1900).
-- It passes if it returns 0 rows.

SELECT
    entry_id,
    publication_date
FROM
    {{ ref('entry') }} -- References dwh.entry table
WHERE
    publication_date > (CURRENT_DATE + interval '1 year') -- More than 1 year in the future?
    OR publication_date < '1900-01-01' -- Before the year 1900?