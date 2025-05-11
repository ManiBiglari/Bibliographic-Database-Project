-- This test checks if non-null, non-'unknown' DOIs generally follow
-- the common '10.' prefix format. This is a basic check and might
-- need refinement based on actual DOI patterns observed.
-- It passes if it returns 0 rows.

SELECT
    entry_id,
    doi
FROM
    {{ ref('entry') }} -- References dwh.entry table
WHERE
    doi IS NOT NULL
    AND doi <> 'unknown'
    AND doi NOT LIKE '10.%' -- Check if it starts with '10.'