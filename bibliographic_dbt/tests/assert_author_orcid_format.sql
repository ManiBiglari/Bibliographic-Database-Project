-- Checks if non-null ORCID values follow either the full URL format
-- OR the standard numerical format (XXXX-XXXX-XXXX-XXX[X]).
-- Passes if it returns 0 rows (i.e., all non-null ORCIDs match one of the patterns).

SELECT
    author_id,
    orcid
FROM
    {{ ref('author') }} -- References dwh.author table
WHERE
    orcid IS NOT NULL
    -- Check if the ORCID does NOT match either the URL pattern OR the numerical pattern
    AND NOT (
        -- Pattern 1: Full URL (allowing http or https)
        (orcid ~ '^https?://orcid\.org/\d{4}-\d{4}-\d{4}-\d{3}[\dX]$')
        OR
        -- Pattern 2: Just the numerical ID
        (orcid ~ '^\d{4}-\d{4}-\d{4}-\d{3}[\dX]$')
    )
