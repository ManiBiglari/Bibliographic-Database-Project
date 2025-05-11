{{ config(materialized='table') }}

WITH extracted_organizations AS (
    SELECT DISTINCT
        CASE 
            WHEN jsonb_typeof(org) = 'object' THEN TRIM(org->>'name')
            ELSE TRIM(BOTH '"' FROM org::text)
        END AS organization_name,
        CURRENT_TIMESTAMP AS updated_at
    FROM {{ ref('stg_crossref') }},
         jsonb_array_elements(authors) AS author,
         LATERAL jsonb_array_elements(
             CASE 
                 WHEN jsonb_typeof(author->'affiliations') = 'array' THEN author->'affiliations'
                 ELSE jsonb_build_array(author->'affiliations')
             END
         ) AS org
    WHERE author->>'name' IS NOT NULL
      AND author->'affiliations' IS NOT NULL
)
SELECT
    {{ surrogate_key(["organization_name"]) }} AS organization_id,
    organization_name,
    updated_at
FROM extracted_organizations
WHERE organization_name IS NOT NULL
  AND organization_name <> 'null'