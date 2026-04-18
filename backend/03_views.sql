-- =============================================================
-- CORTE 3 · BDA · UP Chiapas
-- 03_views.sql
-- Vista principal: v_mascotas_vacunacion_pendiente
-- Vista auxiliar:  v_citas_detalle
-- =============================================================

-- -------------------------------------------------------------
-- VISTA: v_mascotas_vacunacion_pendiente
--
-- Lista mascotas que tienen vacunas con más de 12 meses desde
-- su última aplicación, o que nunca han sido vacunadas.
-- Incluye qué vacuna específica necesita refuerzo.
--
-- Lógica:
--   Para cada combinación (mascota, vacuna) en el inventario,
--   si la última aplicación fue hace más de 365 días (o nunca),
--   la mascota aparece en el resultado.
--
-- Esta vista es la más costosa — es la que se cachea en Redis.
-- -------------------------------------------------------------
CREATE OR REPLACE VIEW v_mascotas_vacunacion_pendiente AS
SELECT
    m.id                                        AS mascota_id,
    m.nombre                                    AS mascota_nombre,
    m.especie,
    d.nombre                                    AS dueno_nombre,
    d.telefono                                  AS dueno_telefono,
    iv.id                                       AS vacuna_id,
    iv.nombre                                   AS vacuna_nombre,
    MAX(va.fecha_aplicacion)                    AS ultima_aplicacion,
    CASE
        WHEN MAX(va.fecha_aplicacion) IS NULL
            THEN 'Nunca vacunada'
        ELSE TO_CHAR(MAX(va.fecha_aplicacion), 'DD/MM/YYYY')
    END                                         AS ultima_aplicacion_texto,
    CASE
        WHEN MAX(va.fecha_aplicacion) IS NULL
            THEN CURRENT_DATE
        ELSE MAX(va.fecha_aplicacion) + INTERVAL '365 days'
    END                                         AS fecha_vencimiento_estimada
FROM mascotas m
JOIN duenos d ON d.id = m.dueno_id
CROSS JOIN inventario_vacunas iv
LEFT JOIN vacunas_aplicadas va
    ON va.mascota_id = m.id
    AND va.vacuna_id = iv.id
-- Solo incluir vacunas relevantes por especie
WHERE (
    (m.especie = 'perro' AND iv.nombre ILIKE '%canin%')
    OR (m.especie = 'gato' AND iv.nombre ILIKE '%felin%')
    OR (m.especie NOT IN ('perro', 'gato'))
)
GROUP BY m.id, m.nombre, m.especie, d.nombre, d.telefono, iv.id, iv.nombre
-- Mostrar solo las que vencieron o nunca se han aplicado
HAVING
    MAX(va.fecha_aplicacion) IS NULL
    OR MAX(va.fecha_aplicacion) < CURRENT_DATE - INTERVAL '365 days'
ORDER BY
    fecha_vencimiento_estimada ASC,
    m.nombre ASC;


-- -------------------------------------------------------------
-- VISTA AUXILIAR: v_citas_detalle
-- Vista enriquecida de citas con nombres de mascota, dueño y vet.
-- Útil para el frontend y para la capa de recepción.
-- -------------------------------------------------------------
CREATE OR REPLACE VIEW v_citas_detalle AS
SELECT
    c.id                                        AS cita_id,
    c.fecha_hora,
    c.motivo,
    c.costo,
    c.estado,
    m.id                                        AS mascota_id,
    m.nombre                                    AS mascota_nombre,
    m.especie,
    d.nombre                                    AS dueno_nombre,
    d.telefono                                  AS dueno_telefono,
    v.id                                        AS veterinario_id,
    v.nombre                                    AS veterinario_nombre
FROM citas c
JOIN mascotas m   ON m.id = c.mascota_id
JOIN duenos d     ON d.id = m.dueno_id
JOIN veterinarios v ON v.id = c.veterinario_id
ORDER BY c.fecha_hora DESC;
