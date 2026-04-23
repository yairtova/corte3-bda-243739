-- =============================================================
-- CORTE 3 · BDA · UP Chiapas
-- 05_rls.sql
--
-- Row-Level Security sobre 3 tablas:
--   mascotas          — vet ve solo las suyas, recepcion/admin ven todo
--   citas             — vet ve solo las propias, recepcion/admin ven todo
--   vacunas_aplicadas — vet ve solo las de sus mascotas, recepcion NO accede
--
-- Mecanismo para identificar al vet actual:
--   SET LOCAL app.current_vet_id = '3';
--   La API hace este SET al inicio de cada transacción.
--   La política lee: current_setting('app.current_vet_id', true)
--
-- Por qué SET LOCAL y no session_user:
--   - No creamos un usuario de BD por cada veterinario real
--   - El backend usa un pool de conexiones (1 user de BD por rol)
--   - SET LOCAL es seguro: se revierte automáticamente al terminar la TX
--   - El vector de ataque (usuario inyecta su propio vet_id) se previene
--     validando el vet_id en la capa de autenticación del backend ANTES
--     de hacer el SET. Documentado en README pregunta 2.
-- =============================================================

-- -------------------------------------------------------------
-- HABILITAR RLS en las tablas sensibles
-- -------------------------------------------------------------
ALTER TABLE mascotas          ENABLE ROW LEVEL SECURITY;
ALTER TABLE citas             ENABLE ROW LEVEL SECURITY;
ALTER TABLE vacunas_aplicadas ENABLE ROW LEVEL SECURITY;

-- FORCE RLS también para el dueño de la tabla (superuser lo salta por defecto,
-- pero para rol_admin que no es superuser, FORCE asegura que las políticas apliquen)
-- NOTA: rol_admin tiene política permisiva que deja pasar todo — ver abajo.
ALTER TABLE mascotas          FORCE ROW LEVEL SECURITY;
ALTER TABLE citas             FORCE ROW LEVEL SECURITY;
ALTER TABLE vacunas_aplicadas FORCE ROW LEVEL SECURITY;

-- -------------------------------------------------------------
-- LIMPIAR políticas anteriores (idempotente)
-- -------------------------------------------------------------
DROP POLICY IF EXISTS pol_mascotas_vet       ON mascotas;
DROP POLICY IF EXISTS pol_mascotas_recepcion ON mascotas;
DROP POLICY IF EXISTS pol_mascotas_admin     ON mascotas;

DROP POLICY IF EXISTS pol_citas_vet          ON citas;
DROP POLICY IF EXISTS pol_citas_recepcion    ON citas;
DROP POLICY IF EXISTS pol_citas_admin        ON citas;

DROP POLICY IF EXISTS pol_vacunas_vet        ON vacunas_aplicadas;
DROP POLICY IF EXISTS pol_vacunas_admin      ON vacunas_aplicadas;

-- =============================================================
-- POLÍTICAS: tabla mascotas
-- =============================================================

-- Veterinario: solo ve mascotas que aparecen en vet_atiende_mascota con su id
CREATE POLICY pol_mascotas_vet
    ON mascotas
    FOR ALL
    TO rol_veterinario
    USING (
        id IN (
            SELECT mascota_id
            FROM vet_atiende_mascota
            WHERE vet_id = current_setting('app.current_vet_id', true)::INT
              AND activa = TRUE
        )
    );
-- Explicación en README:
-- Cuando rol_veterinario consulta mascotas, PostgreSQL evalúa esta cláusula
-- USING por cada fila. Solo pasa la fila si mascota.id aparece en
-- vet_atiende_mascota para el vet_id de la sesión actual.

-- Recepción: ve todas las mascotas (sin restricción de filas)
CREATE POLICY pol_mascotas_recepcion
    ON mascotas
    FOR SELECT
    TO rol_recepcion
    USING (true);

-- Admin: ve y opera sobre todas las mascotas
CREATE POLICY pol_mascotas_admin
    ON mascotas
    FOR ALL
    TO rol_admin
    USING (true)
    WITH CHECK (true);

-- =============================================================
-- POLÍTICAS: tabla citas
-- =============================================================

-- Veterinario: solo ve citas donde él es el veterinario asignado
CREATE POLICY pol_citas_vet
    ON citas
    FOR ALL
    TO rol_veterinario
    USING (
        veterinario_id = current_setting('app.current_vet_id', true)::INT
    )
    WITH CHECK (
        veterinario_id = current_setting('app.current_vet_id', true)::INT
    );
-- WITH CHECK garantiza que al insertar, el vet solo pueda crear citas para sí mismo.

-- Recepción: ve todas las citas (puede agendar para cualquier vet)
CREATE POLICY pol_citas_recepcion
    ON citas
    FOR ALL
    TO rol_recepcion
    USING (true)
    WITH CHECK (true);

-- Admin: todo
CREATE POLICY pol_citas_admin
    ON citas
    FOR ALL
    TO rol_admin
    USING (true)
    WITH CHECK (true);

-- =============================================================
-- POLÍTICAS: tabla vacunas_aplicadas
-- =============================================================
-- NOTA: recepcion NO tiene GRANT sobre esta tabla (04_roles.sql),
-- así que nunca llega a la capa RLS. La doble defensa es intencional.

-- Veterinario: solo ve vacunas aplicadas a mascotas que atiende
CREATE POLICY pol_vacunas_vet
    ON vacunas_aplicadas
    FOR ALL
    TO rol_veterinario
    USING (
        mascota_id IN (
            SELECT mascota_id
            FROM vet_atiende_mascota
            WHERE vet_id = current_setting('app.current_vet_id', true)::INT
              AND activa = TRUE
        )
    )
    WITH CHECK (
        mascota_id IN (
            SELECT mascota_id
            FROM vet_atiende_mascota
            WHERE vet_id = current_setting('app.current_vet_id', true)::INT
              AND activa = TRUE
        )
    );

-- Admin: todo
CREATE POLICY pol_vacunas_admin
    ON vacunas_aplicadas
    FOR ALL
    TO rol_admin
    USING (true)
    WITH CHECK (true);

-- =============================================================
-- FUNCIÓN HELPER: set_vet_context
-- El backend llama esta función al inicio de cada TX para establecer
-- el contexto del veterinario actual de forma segura.
-- Devuelve void. Si vet_id no existe o está inactivo, lanza excepción.
-- =============================================================
CREATE OR REPLACE FUNCTION set_vet_context(p_vet_id INT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_activo BOOLEAN;
BEGIN
    -- Validar que el veterinario existe y está activo
    SELECT activo INTO v_activo
    FROM veterinarios
    WHERE id = p_vet_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Veterinario con id % no encontrado.', p_vet_id;
    END IF;

    IF NOT v_activo THEN
        RAISE EXCEPTION 'Veterinario con id % está inactivo.', p_vet_id;
    END IF;

    -- Establecer variable de sesión LOCAL (se revierte al fin de la TX)
    PERFORM set_config('app.current_vet_id', p_vet_id::TEXT, true);
END;
$$;

-- El rol_veterinario necesita ejecutar esta función para establecer su contexto
GRANT EXECUTE ON FUNCTION set_vet_context(INT) TO rol_veterinario;
GRANT EXECUTE ON FUNCTION set_vet_context(INT) TO rol_admin;

-- =============================================================
-- VERIFICACIÓN
-- =============================================================
DO $$
BEGIN
    RAISE NOTICE '=== RLS CONFIGURADO ===';
    RAISE NOTICE 'Tabla mascotas:          RLS habilitado';
    RAISE NOTICE '  pol_mascotas_vet:      filtra por vet_atiende_mascota WHERE vet_id = app.current_vet_id';
    RAISE NOTICE '  pol_mascotas_recepcion: USING(true) — ve todo';
    RAISE NOTICE '  pol_mascotas_admin:     USING(true) — ve todo';
    RAISE NOTICE 'Tabla citas:             RLS habilitado';
    RAISE NOTICE '  pol_citas_vet:          filtra WHERE veterinario_id = app.current_vet_id';
    RAISE NOTICE 'Tabla vacunas_aplicadas: RLS habilitado';
    RAISE NOTICE '  pol_vacunas_vet:        filtra mascotas asignadas al vet';
    RAISE NOTICE '  (recepcion bloqueada por GRANT, nunca llega a RLS)';
    RAISE NOTICE '========================';
END
$$;