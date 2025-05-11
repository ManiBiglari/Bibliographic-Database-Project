{% macro surrogate_key(columns) %}
  abs(
    hashtext(
      concat(
        {%- for column in columns -%}
          coalesce(cast({{ column }} as text), '')
          {%- if not loop.last -%}, {% endif -%}
        {%- endfor -%}
      )
    )
  )
{% endmacro %}