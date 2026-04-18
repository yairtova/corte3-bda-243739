-- =============================================================
-- CORTE 3 · BDA · UP Chiapas
-- 02_triggers.sql
-- Trigger 1: trg_historial_cita  — registra en historial_movimientos
-- Trigger 2: trg_alerta_stock    — alerta cuando stock_actual < stock_minimo
-- =============================================================

-- -------------------------------------------------------------
-- TRIGGER 1: trg_historial_cita
-- Se dispara AFTER INSERT en la tabla citas.
-- Registra un movimiento en historial_movimientos con:
--   tipo        = 'CITA_AGENDADA'
--   referencia_id = id de la cita nueva
--   descripcion = texto legible con mascota, vet y fecha
-- -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_registrar_historial_cita()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_nombre_mascota   VARCHAR(50);
    v_nombre_vet       VARCHAR(100);
BEGIN
    -- Obtener nombres para la descripción legible
    SELECT nombre INTO v_nombre_mascota
    FROM mascotas WHERE id = NEW.mascota_id;

    SELECT nombre INTO v_nombre_vet
    FROM veterinarios WHERE id = NEW.veterinario_id;

    INSERT INTO historial_movimientos (tipo, referencia_id, descripcion, fecha)
    VALUES (
        'CITA_AGENDADA',
        NEW.id,
        FORMAT(
            'Cita agendada: mascota "%s" (id=%s) con %s (id=%s) el %s. Motivo: %s',
            v_nombre_mascota,
            NEW.mascota_id,
            v_nombre_vet,
            NEW.veterinario_id,
            TO_CHAR(NEW.fecha_hora, 'DD/MM/YYYY HH24:MI'),
            COALESCE(NEW.motivo, 'Sin motivo especificado')
        ),
        NOW()
    );

    RETURN NEW;
END;
$$;

-- Crear el trigger (eliminar primero si ya existe para idempotencia)
DROP TRIGGER IF EXISTS trg_historial_cita ON citas;

CREATE TRIGGER trg_historial_cita
    AFTER INSERT ON citas
    FOR EACH ROW
    EXECUTE FUNCTION fn_registrar_historial_cita();


-- -------------------------------------------------------------
-- TRIGGER 2: trg_alerta_stock
-- Se dispara AFTER UPDATE en inventario_vacunas.
-- Si stock_actual cae por debajo de stock_minimo, inserta
-- una alerta en la tabla alertas.
-- Se usa cuando se aplica una vacuna y se descuenta del inventario.
-- -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_alerta_stock_vacuna()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- Solo actuar si el stock bajó Y está por debajo del mínimo
    IF NEW.stock_actual < NEW.stock_minimo AND NEW.stock_actual < OLD.stock_actual THEN
        INSERT INTO alertas (tipo, descripcion, fecha)
        VALUES (
            'STOCK_BAJO',
            FORMAT(
                'Alerta de stock: vacuna "%s" (id=%s) — stock actual %s unidades, mínimo requerido %s.',
                NEW.nombre,
                NEW.id,
                NEW.stock_actual,
                NEW.stock_minimo
            ),
            NOW()
        );

        RAISE NOTICE 'ALERTA: Stock bajo para vacuna "%" (actual=%, mínimo=%).',
            NEW.nombre, NEW.stock_actual, NEW.stock_minimo;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_alerta_stock ON inventario_vacunas;

CREATE TRIGGER trg_alerta_stock
    AFTER UPDATE OF stock_actual ON inventario_vacunas
    FOR EACH ROW
    EXECUTE FUNCTION fn_alerta_stock_vacuna();


-- -------------------------------------------------------------
-- TRIGGER 3: trg_descontar_stock_vacuna
-- Se dispara AFTER INSERT en vacunas_aplicadas.
-- Descuenta 1 unidad del inventario automáticamente.
-- Esto a su vez puede disparar trg_alerta_stock si el stock baja.
-- -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_descontar_stock_vacuna()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE inventario_vacunas
    SET stock_actual = stock_actual - 1
    WHERE id = NEW.vacuna_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No se encontró la vacuna con id % en inventario.', NEW.vacuna_id;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_descontar_stock_vacuna ON vacunas_aplicadas;

CREATE TRIGGER trg_descontar_stock_vacuna
    AFTER INSERT ON vacunas_aplicadas
    FOR EACH ROW
    EXECUTE FUNCTION fn_descontar_stock_vacuna();
