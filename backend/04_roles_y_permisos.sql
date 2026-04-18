-- =============================================================
-- CORTE 3 · BDA · UP Chiapas
-- 04_roles_y_permisos.sql
--
-- Tres roles del sistema:
--   rol_veterinario  — ve y opera solo sobre sus mascotas asignadas
--   rol_recepcion    — ve todo lo administrativo, no ve datos médicos
--   rol_admin        — acceso total
--
-- IMPORTANTE: RLS filtra las filas DENTRO de las tablas.
-- GRANT/REVOKE controla el acceso a las tablas mismas.
-- Ambos se complementan: si recepcion no tiene GRANT sobre
-- vacunas_aplicadas, ni siquiera llega a la capa RLS.
-- =============================================================

-- -------------------------------------------------------------
-- 1. LIMPIAR roles anteriores (idempotente)
-- -------------------------------------------------------------
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'rol_veterinario') THEN
        DROP OWNED BY rol_veterinario;
        DROP ROLE rol_veterinario;
    END IF;
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'rol_recepcion') THEN
        DROP OWNED BY rol_recepcion;
        DROP ROLE rol_recepcion;
    END IF;
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'rol_admin') THEN
        DROP OWNED BY rol_admin;
        DROP ROLE rol_admin;
    END IF;
END
$$;

-- -------------------------------------------------------------
-- 2. CREAR ROLES BASE (sin login — son roles de grupo)
-- -------------------------------------------------------------
CREATE ROLE rol_veterinario  NOLOGIN;
CREATE ROLE rol_recepcion    NOLOGIN;
CREATE ROLE rol_admin        NOLOGIN;

-- -------------------------------------------------------------
-- 3. CREAR USUARIOS DE PRUEBA con los roles
-- Estos usuarios serán los que conecta el backend según el login.
-- -------------------------------------------------------------

-- Usuarios veterinarios (uno por veterinario real del schema)
-- Usamos el mismo nombre que la cédula para que la política RLS
-- pueda hacer SET app.current_vet_id al conectar.
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'vet_lopez') THEN
        CREATE USER vet_lopez PASSWORD 'vet_lopez_pass';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'vet_garcia') THEN
        CREATE USER vet_garcia PASSWORD 'vet_garcia_pass';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'vet_mendez') THEN
        CREATE USER vet_mendez PASSWORD 'vet_mendez_pass';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'usuario_recepcion') THEN
        CREATE USER usuario_recepcion PASSWORD 'recepcion_pass';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'usuario_admin') THEN
        CREATE USER usuario_admin PASSWORD 'admin_pass';
    END IF;
END
$$;

-- Asignar roles a usuarios
GRANT rol_veterinario TO vet_lopez, vet_garcia, vet_mendez;
GRANT rol_recepcion   TO usuario_recepcion;
GRANT rol_admin       TO usuario_admin;

-- -------------------------------------------------------------
-- 4. PERMISOS POR ROL
-- Principio: cada rol recibe SOLO lo que necesita para su función.
-- -------------------------------------------------------------

-- -------- ROL VETERINARIO --------
-- Ve sus mascotas (filtrado por RLS), sus citas, sus vacunas aplicadas.
-- Puede insertar citas y vacunas. No toca inventario ni historial.

GRANT USAGE ON SCHEMA public TO rol_veterinario;

-- Mascotas: SELECT solamente (RLS filtra cuáles)
GRANT SELECT ON mascotas TO rol_veterinario;

-- Dueños: SELECT para ver datos de contacto del dueño de sus mascotas
GRANT SELECT ON duenos TO rol_veterinario;

-- Citas: SELECT las suyas (RLS filtra) + INSERT para agendar
GRANT SELECT, INSERT ON citas TO rol_veterinario;
GRANT USAGE, SELECT ON SEQUENCE citas_id_seq TO rol_veterinario;

-- Vacunas aplicadas: SELECT las suyas (RLS filtra) + INSERT para aplicar
GRANT SELECT, INSERT ON vacunas_aplicadas TO rol_veterinario;
GRANT USAGE, SELECT ON SEQUENCE vacunas_aplicadas_id_seq TO rol_veterinario;

-- Inventario vacunas: SELECT para saber qué vacunas hay disponibles
-- UPDATE lo maneja solo el trigger trg_descontar_stock_vacuna, no el rol
GRANT SELECT ON inventario_vacunas TO rol_veterinario;

-- vet_atiende_mascota: SELECT para que RLS pueda consultarla
GRANT SELECT ON vet_atiende_mascota TO rol_veterinario;

-- Vista de pendientes: útil para el veterinario ver qué mascotas suyas necesitan vacuna
GRANT SELECT ON v_mascotas_vacunacion_pendiente TO rol_veterinario;
GRANT SELECT ON v_citas_detalle TO rol_veterinario;

-- Historial: NO — el vet no necesita ver el historial técnico de operaciones
-- NO se otorga GRANT sobre historial_movimientos ni alertas


-- -------- ROL RECEPCION --------
-- Ve TODAS las mascotas y dueños. Puede agendar citas.
-- NO ve vacunas aplicadas (información médica, confidencial).
-- NO toca inventario (eso es del admin).

GRANT USAGE ON SCHEMA public TO rol_recepcion;

-- Mascotas: SELECT todas (sin RLS — recepción ve todo el catálogo)
GRANT SELECT ON mascotas TO rol_recepcion;

-- Dueños: SELECT y UPDATE (puede actualizar teléfono/email)
GRANT SELECT, UPDATE (telefono, email) ON duenos TO rol_recepcion;

-- Citas: SELECT todas + INSERT para agendar
GRANT SELECT, INSERT ON citas TO rol_recepcion;
GRANT USAGE, SELECT ON SEQUENCE citas_id_seq TO rol_recepcion;

-- vet_atiende_mascota: SELECT para saber a qué vet asignar
GRANT SELECT ON vet_atiende_mascota TO rol_recepcion;

-- Veterinarios: SELECT para mostrar en dropdown al agendar
GRANT SELECT ON veterinarios TO rol_recepcion;

-- Vista de citas: útil para la pantalla de agenda
GRANT SELECT ON v_citas_detalle TO rol_recepcion;

-- NO se otorga: vacunas_aplicadas, inventario_vacunas, historial_movimientos, alertas


-- -------- ROL ADMIN --------
-- Acceso total. Puede hacer cualquier operación sobre todas las tablas.

GRANT USAGE ON SCHEMA public TO rol_admin;

GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA public TO rol_admin;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO rol_admin;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO rol_admin;

-- Admin puede ejecutar el procedure de agendar cita
GRANT EXECUTE ON PROCEDURE sp_agendar_cita(INT, INT, TIMESTAMP, TEXT, INT) TO rol_admin;
GRANT EXECUTE ON FUNCTION  fn_total_facturado(INT, INT)                     TO rol_admin;

-- Tambien damos EXECUTE al vet y recepcion para sp_agendar_cita
GRANT EXECUTE ON PROCEDURE sp_agendar_cita(INT, INT, TIMESTAMP, TEXT, INT) TO rol_veterinario;
GRANT EXECUTE ON PROCEDURE sp_agendar_cita(INT, INT, TIMESTAMP, TEXT, INT) TO rol_recepcion;
GRANT EXECUTE ON FUNCTION  fn_total_facturado(INT, INT)                     TO rol_veterinario;

-- -------------------------------------------------------------
-- 5. VERIFICACIÓN: mostrar permisos creados
-- -------------------------------------------------------------
DO $$
BEGIN
    RAISE NOTICE '=== ROLES CREADOS ===';
    RAISE NOTICE 'rol_veterinario: SELECT mascotas/citas/vacunas_aplicadas (filtrado por RLS), INSERT citas/vacunas';
    RAISE NOTICE 'rol_recepcion:   SELECT todas mascotas/citas, INSERT citas, UPDATE contacto duenos';
    RAISE NOTICE 'rol_admin:       ALL PRIVILEGES en todo el schema';
    RAISE NOTICE '=====================';
END
$$;
