{{ config(materialized='table') }}

WITH distinct_authors AS (
    SELECT DISTINCT
        author->>'name' AS name,
        author->>'orcid' AS orcid,
        author->>'affiliations' AS organizations,
        CURRENT_TIMESTAMP AS updated_at
    FROM {{ ref('stg_crossref') }},
         jsonb_array_elements(authors) AS author
    WHERE author->>'name' IS NOT NULL
)
SELECT
    {{ surrogate_key(["name", "orcid", "organizations"]) }} AS author_id,
    name,
    orcid,
    organizations,
    updated_at
FROM distinct_authors
WHERE name IS NOT NULL