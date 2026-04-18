-- =============================================================
-- CORTE 3 · BDA · UP Chiapas
-- 01_procedures.sql
-- Procedure: sp_agendar_cita
-- Function:  fn_total_facturado
-- =============================================================

-- -------------------------------------------------------------
-- PROCEDURE: sp_agendar_cita
-- Registra una nueva cita validando:
--   1. Que la mascota exista
--   2. Que el veterinario exista y esté activo
--   3. Que la fecha no sea en el pasado
--   4. Que el veterinario no trabaje ese día (dias_descanso)
--   5. Que no haya traslape de citas para ese vet en esa hora
-- OUT p_cita_id devuelve el id de la cita creada, o -1 si falló.
-- -------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_agendar_cita(
    p_mascota_id     INT,
    p_veterinario_id INT,
    p_fecha_hora     TIMESTAMP,
    p_motivo         TEXT,
    OUT p_cita_id    INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_vet_activo      BOOLEAN;
    v_dias_descanso   VARCHAR(50);
    v_dia_semana      TEXT;
    v_conflicto       INT;
    v_mascota_existe  INT;
BEGIN
    p_cita_id := -1;

    -- 1. Validar que la mascota existe
    SELECT COUNT(*) INTO v_mascota_existe
    FROM mascotas
    WHERE id = p_mascota_id;

    IF v_mascota_existe = 0 THEN
        RAISE EXCEPTION 'La mascota con id % no existe.', p_mascota_id;
    END IF;

    -- 2. Validar que el veterinario existe y está activo
    SELECT activo, dias_descanso
    INTO v_vet_activo, v_dias_descanso
    FROM veterinarios
    WHERE id = p_veterinario_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El veterinario con id % no existe.', p_veterinario_id;
    END IF;

    IF NOT v_vet_activo THEN
        RAISE EXCEPTION 'El veterinario con id % está inactivo.', p_veterinario_id;
    END IF;

    -- 3. Validar que la fecha no sea en el pasado
    IF p_fecha_hora < NOW() THEN
        RAISE EXCEPTION 'No se puede agendar una cita en el pasado (%).', p_fecha_hora;
    END IF;

    -- 4. Validar días de descanso
    -- Convertir número de día a nombre en español (0=domingo...6=sábado)
    v_dia_semana := CASE EXTRACT(DOW FROM p_fecha_hora)
        WHEN 0 THEN 'domingo'
        WHEN 1 THEN 'lunes'
        WHEN 2 THEN 'martes'
        WHEN 3 THEN 'miércoles'
        WHEN 4 THEN 'jueves'
        WHEN 5 THEN 'viernes'
        WHEN 6 THEN 'sábado'
    END;

    -- Si dias_descanso contiene el día, rechazar
    IF v_dias_descanso <> '' AND v_dias_descanso ILIKE '%' || v_dia_semana || '%' THEN
        RAISE EXCEPTION 'El veterinario descansa los % y no puede tener citas ese día.', v_dia_semana;
    END IF;

    -- 5. Detectar traslape: cita en la misma hora ±30 minutos para el mismo vet
    SELECT COUNT(*) INTO v_conflicto
    FROM citas
    WHERE veterinario_id = p_veterinario_id
      AND estado <> 'CANCELADA'
      AND ABS(EXTRACT(EPOCH FROM (fecha_hora - p_fecha_hora))) < 1800; -- 30 min en segundos

    IF v_conflicto > 0 THEN
        RAISE EXCEPTION 'El veterinario ya tiene una cita dentro de los 30 minutos de la hora solicitada.';
    END IF;

    -- 6. Insertar la cita
    INSERT INTO citas (mascota_id, veterinario_id, fecha_hora, motivo, estado)
    VALUES (p_mascota_id, p_veterinario_id, p_fecha_hora, p_motivo, 'AGENDADA')
    RETURNING id INTO p_cita_id;

    -- El trigger trg_historial_cita se dispara automáticamente aquí

    RAISE NOTICE 'Cita agendada correctamente con id %.', p_cita_id;

EXCEPTION
    WHEN OTHERS THEN
        p_cita_id := -1;
        RAISE; -- Re-lanzar para que el cliente vea el mensaje
END;
$$;


-- -------------------------------------------------------------
-- FUNCTION: fn_total_facturado
-- Devuelve el total facturado para una mascota en un año dado.
-- Suma costo de citas COMPLETADAS + costo_cobrado de vacunas
-- aplicadas en ese año.
-- Devuelve 0.00 si no hay registros (nunca NULL).
-- -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_total_facturado(
    p_mascota_id INT,
    p_anio       INT
)
RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_total_citas   NUMERIC(10, 2) := 0;
    v_total_vacunas NUMERIC(10, 2) := 0;
BEGIN
    -- Total de citas completadas en el año
    SELECT COALESCE(SUM(costo), 0)
    INTO v_total_citas
    FROM citas
    WHERE mascota_id = p_mascota_id
      AND estado = 'COMPLETADA'
      AND EXTRACT(YEAR FROM fecha_hora) = p_anio;

    -- Total de vacunas aplicadas en el año
    SELECT COALESCE(SUM(costo_cobrado), 0)
    INTO v_total_vacunas
    FROM vacunas_aplicadas
    WHERE mascota_id = p_mascota_id
      AND EXTRACT(YEAR FROM fecha_aplicacion) = p_anio;

    RETURN v_total_citas + v_total_vacunas;
END;
$$;
