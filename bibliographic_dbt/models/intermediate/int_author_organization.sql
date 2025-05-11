{{ config(materialized='table') }}

WITH base_authors AS (
    SELECT DISTINCT
        a.author_id,
        a.name AS author_name,
        a.organizations::jsonb AS organizations, -- Cast organizations to jsonb
        CURRENT_TIMESTAMP AS updated_at
    FROM {{ ref('int_author') }} a
    WHERE organizations IS NOT NULL
),
expanded_organizations AS (
    SELECT
        ba.author_id,
        org.value AS organization,
        org.ordinality,
        ba.updated_at
    FROM base_authors ba
    CROSS JOIN LATERAL jsonb_array_elements(
        CASE
            WHEN jsonb_typeof(ba.organizations) = 'array' THEN ba.organizations
            WHEN jsonb_typeof(ba.organizations) = 'string' THEN jsonb_build_array(ba.organizations)
            ELSE '[]'::jsonb
        END
    ) WITH ORDINALITY AS org(value, ordinality)
),
final AS (
    SELECT
        author_id,
        REGEXP_REPLACE(CAST(organization AS VARCHAR), '<[^>]+>', '', 'g') AS organization_name,
        ordinality,
        updated_at
    FROM expanded_organizations
    WHERE organization IS NOT NULL
),
dedup AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY author_id, organization_name, ordinality
            ORDER BY updated_at DESC
        ) AS rn
    FROM final
)
SELECT
    author_id,
    REGEXP_REPLACE(CAST(organization_name AS VARCHAR), '["]', '', 'g') AS organization_name, -- Remove double quotes
    updated_at,
    ordinality,
    {{ surrogate_key(["author_id", "organization_name", "ordinality"]) }} AS author_organization_surrogate_id
FROM dedup
WHERE rn = 1