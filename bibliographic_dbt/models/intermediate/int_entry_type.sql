{{ config(materialized='table') }}

WITH distinct_types AS (
    SELECT DISTINCT
        LOWER(type) AS type
    FROM {{ ref('stg_crossref') }}
),
new_types AS (
    SELECT
        type
    FROM distinct_types
    LEFT JOIN {{ source('DWH', 'entry_type') }} et
    ON distinct_types.type = et.entry_type_name
    WHERE et.entry_type_id IS NULL
),
max_id AS (
    SELECT COALESCE(MAX(entry_type_id), 0) AS max_id
    FROM {{ source('DWH', 'entry_type') }}
)
SELECT
    ROW_NUMBER() OVER (ORDER BY type) + (SELECT max_id FROM max_id) AS entry_type_id,
    type AS entry_type_name,
    NULL AS entry_type_desc
FROM new_types