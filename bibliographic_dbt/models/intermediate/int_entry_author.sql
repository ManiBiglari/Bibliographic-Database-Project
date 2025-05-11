{{ config(materialized='table') }}

WITH base_entries AS (
    SELECT DISTINCT
        id          AS source_id,
        doi,
        title,
        publisher,
        authors,
        CURRENT_TIMESTAMP    AS updated_at,
        {{ surrogate_key(["id", "doi", "title", "publisher"]) }} AS entry_id
    FROM {{ ref('stg_crossref') }}
    WHERE title IS NOT NULL
),

expanded_authors AS (
    SELECT
        be.entry_id,
        a.value,
        a.ordinality,
        be.updated_at
    FROM base_entries AS be
    CROSS JOIN LATERAL
        jsonb_array_elements(be.authors) WITH ORDINALITY AS a(value, ordinality)
),

final AS (
    SELECT
        entry_id,
        REGEXP_REPLACE(CAST(value->>'name' AS VARCHAR), '<[^>]+>', '', 'g') AS author_name,
        ordinality,
        updated_at
    FROM expanded_authors
    WHERE value->>'name' IS NOT NULL
),

dedup AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY entry_id, author_name, ordinality
            ORDER BY updated_at DESC
        ) AS rn
    FROM final
)

SELECT
    entry_id,
    author_name,
    ordinality,
    updated_at
FROM dedup
WHERE rn = 1