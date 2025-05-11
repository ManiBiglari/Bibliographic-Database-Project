-- Finds entries that HAVE authors linked, but none are marked as primary.
-- Assumes is_primary_author = TRUE indicates the primary author based on source order.
-- Note: This assumes that entries with authors *should* have a primary author.
-- It will NOT return entries that have no authors at all.
-- Passes if it returns 0 rows.

SELECT
    e.entry_id
FROM
    {{ ref('entry') }} e
LEFT JOIN
    {{ ref('entry_author') }} ea
    ON e.entry_id = ea.entry_id AND ea.is_primary_author = TRUE
WHERE
    -- Condition 1: Ensure the entry actually HAS authors linked in the junction table
    e.entry_id IN (SELECT DISTINCT entry_id FROM {{ ref('entry_author') }})
    -- Condition 2: Ensure that among those authors, none met the specific LEFT JOIN condition (is_primary_author = TRUE)
    AND ea.entry_id IS NULL