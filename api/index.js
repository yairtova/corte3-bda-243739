// =============================================================
// CORTE 3 · BDA · UP Chiapas
// api/index.js — Servidor Express principal
//
// HARDENING: Toda query con input de usuario usa parámetros
// posicionales ($1, $2, ...) del driver `pg`. NUNCA se concatena
// input del usuario en strings SQL.
//
// FIX RLS: set_config('app.current_vet_id', ..., true) es SET LOCAL
// — solo persiste dentro de una transacción abierta. Por eso
// getDbClient() hace BEGIN antes de set_vet_context() y cada
// endpoint hace COMMIT/ROLLBACK al terminar.
// =============================================================

require('dotenv').config();
const express  = require('express');
const cors     = require('cors');
const { pool, getClientForRole } = require('./db');
const { getCache, setCache, deleteCache } = require('./cache');

const app = express();
app.use(cors());
app.use(express.json());

app.use((req, res, next) => {
    console.log(`[${new Date().toISOString()}] ${req.method} ${req.path}`);
    next();
});

// =============================================================
// MIDDLEWARE: extraer rol y vet_id del header de sesión
// =============================================================
function extractSession(req, res, next) {
    const role  = req.headers['x-user-role'] || 'admin';
    const vetId = req.headers['x-vet-id']    || null;

    const validRoles = ['veterinario', 'recepcion', 'admin'];
    if (!validRoles.includes(role)) {
        return res.status(401).json({ error: 'Rol invalido.' });
    }

    if (role === 'veterinario') {
        const parsedVetId = parseInt(vetId, 10);
        if (isNaN(parsedVetId) || parsedVetId <= 0) {
            return res.status(401).json({ error: 'vet_id invalido para rol veterinario.' });
        }
        req.session = { role, vetId: parsedVetId };
    } else {
        req.session = { role, vetId: null };
    }
    next();
}

app.use(extractSession);

// =============================================================
// HELPER: obtener cliente de BD con contexto de vet establecido.
//
// Para veterinarios:
//   1. Obtiene cliente del pool del usuario de ese vet
//   2. Abre transacción explícita (BEGIN)
//   3. Llama set_vet_context() — que internamente hace
//      set_config('app.current_vet_id', id, true) = SET LOCAL
//      SET LOCAL requiere estar dentro de BEGIN para persistir.
//   4. Marca client._vetTxOpen = true para que el finally haga COMMIT/ROLLBACK
//
// Para recepcion/admin: solo devuelve cliente sin TX extra.
// =============================================================
async function getDbClient(session) {
    const client = await getClientForRole(session.role, session.vetId);

    if (session.role === 'veterinario') {
        await client.query('BEGIN');
        await client.query('SELECT set_vet_context($1)', [session.vetId]);
        client._vetTxOpen = true;
    }

    return client;
}

// Helper para cerrar TX si está abierta
async function releaseClient(client, error = false) {
    if (!client) return;
    try {
        if (client._vetTxOpen) {
            await client.query(error ? 'ROLLBACK' : 'COMMIT');
        }
    } catch (e) { /* ignorar error al cerrar TX */ }
    client.release();
}

// =============================================================
// ENDPOINTS
// =============================================================

// ---- GET /api/mascotas ----------------------------------------
// Búsqueda de mascotas. Parámetro opcional: ?nombre=...
//
// HARDENING — línea crítica (archivo: api/index.js ~línea 90):
//   client.query('... WHERE m.nombre ILIKE $1', [`%${nombre}%`])
//
// El input NUNCA se concatena al string SQL. El driver pg lo envía
// como parámetro separado al Extended Query Protocol de PostgreSQL.
// Un input como ' OR '1'='1 llega como texto de búsqueda literal.
// =============================================================
app.get('/api/mascotas', async (req, res) => {
    const { nombre } = req.query;
    let client;
    try {
        client = await getDbClient(req.session);

        let result;
        if (nombre && nombre.trim() !== '') {
            console.log(`[QUERY] Buscando nombre con parametro: ${JSON.stringify(nombre)}`);
            // *** LÍNEA QUE DEFIENDE CONTRA SQL INJECTION ***
            // El $1 es un parámetro posicional — nunca se interpreta como SQL
            result = await client.query(
                `SELECT m.id, m.nombre, m.especie, m.fecha_nacimiento,
                        d.nombre AS dueno_nombre, d.telefono
                 FROM mascotas m
                 JOIN duenos d ON d.id = m.dueno_id
                 WHERE m.nombre ILIKE $1
                 ORDER BY m.nombre`,
                [`%${nombre}%`]   // <-- input del usuario va aquí, nunca en el string SQL
            );
            console.log(`[QUERY] Rows devueltas: ${result.rowCount}`);
        } else {
            result = await client.query(
                `SELECT m.id, m.nombre, m.especie, m.fecha_nacimiento,
                        d.nombre AS dueno_nombre, d.telefono
                 FROM mascotas m
                 JOIN duenos d ON d.id = m.dueno_id
                 ORDER BY m.nombre`
            );
        }

        res.json({ ok: true, data: result.rows, count: result.rowCount });
        await releaseClient(client, false);
    } catch (err) {
        console.error('[ERROR] GET /api/mascotas:', err.message);
        res.status(500).json({ ok: false, error: err.message });
        await releaseClient(client, true);
    }
});

// ---- GET /api/mascotas/:id ------------------------------------
app.get('/api/mascotas/:id', async (req, res) => {
    const id = parseInt(req.params.id, 10);
    if (isNaN(id)) return res.status(400).json({ error: 'id invalido' });

    let client;
    try {
        client = await getDbClient(req.session);
        const result = await client.query(
            `SELECT m.*, d.nombre AS dueno_nombre, d.telefono, d.email
             FROM mascotas m JOIN duenos d ON d.id = m.dueno_id
             WHERE m.id = $1`,
            [id]
        );
        if (result.rowCount === 0) {
            await releaseClient(client, false);
            return res.status(404).json({ error: 'Mascota no encontrada o sin acceso.' });
        }
        res.json({ ok: true, data: result.rows[0] });
        await releaseClient(client, false);
    } catch (err) {
        console.error('[ERROR] GET /api/mascotas/:id:', err.message);
        res.status(500).json({ ok: false, error: err.message });
        await releaseClient(client, true);
    }
});

// ---- GET /api/vacunacion-pendiente ----------------------------
// Consulta costosa cacheada en Redis. TTL = 300s.
// Invalidación explícita en POST /api/vacunas-aplicadas.
// =============================================================
app.get('/api/vacunacion-pendiente', async (req, res) => {
    const CACHE_KEY = 'vacunacion_pendiente';
    const startTime = Date.now();

    try {
        const cached = await getCache(CACHE_KEY);
        if (cached) {
            const latency = Date.now() - startTime;
            console.log(`[CACHE HIT] ${CACHE_KEY} — latencia ${latency}ms`);
            return res.json({ ok: true, data: cached, fromCache: true, latencyMs: latency });
        }
    } catch (cacheErr) {
        console.warn('[CACHE] Redis no disponible, consultando BD directamente.');
    }

    let client;
    try {
        client = await getDbClient(req.session);
        const result = await client.query(`SELECT * FROM v_mascotas_vacunacion_pendiente`);
        const latency = Date.now() - startTime;
        console.log(`[CACHE MISS] ${CACHE_KEY} — BD consultada en ${latency}ms`);
        await setCache(CACHE_KEY, result.rows, 300);
        res.json({ ok: true, data: result.rows, fromCache: false, latencyMs: latency });
        await releaseClient(client, false);
    } catch (err) {
        console.error('[ERROR] GET /api/vacunacion-pendiente:', err.message);
        res.status(500).json({ ok: false, error: err.message });
        await releaseClient(client, true);
    }
});

// ---- POST /api/vacunas-aplicadas ------------------------------
app.post('/api/vacunas-aplicadas', async (req, res) => {
    const { mascota_id, vacuna_id, veterinario_id, costo_cobrado } = req.body;

    if (!Number.isInteger(+mascota_id) || !Number.isInteger(+vacuna_id) || !Number.isInteger(+veterinario_id)) {
        return res.status(400).json({ error: 'mascota_id, vacuna_id y veterinario_id deben ser enteros.' });
    }

    let client;
    try {
        client = await getDbClient(req.session);
        // Si es vet, el BEGIN ya está abierto desde getDbClient.
        // Si es admin/recepcion, abrimos TX manualmente.
        if (!client._vetTxOpen) await client.query('BEGIN');

        const result = await client.query(
            `INSERT INTO vacunas_aplicadas
                (mascota_id, vacuna_id, veterinario_id, fecha_aplicacion, costo_cobrado)
             VALUES ($1, $2, $3, CURRENT_DATE, $4)
             RETURNING id`,
            [+mascota_id, +vacuna_id, +veterinario_id, costo_cobrado ? +costo_cobrado : null]
        );

        await client.query('COMMIT');
        client._vetTxOpen = false; // ya se commitió manualmente

        await deleteCache('vacunacion_pendiente');
        console.log('[CACHE INVALIDADO] vacunacion_pendiente — nueva vacuna aplicada id=%s', result.rows[0].id);

        res.status(201).json({ ok: true, id: result.rows[0].id });
        client.release();
    } catch (err) {
        if (client) { await client.query('ROLLBACK').catch(() => {}); client.release(); }
        console.error('[ERROR] POST /api/vacunas-aplicadas:', err.message);
        res.status(500).json({ ok: false, error: err.message });
    }
});

// ---- POST /api/citas ------------------------------------------
app.post('/api/citas', async (req, res) => {
    const { mascota_id, veterinario_id, fecha_hora, motivo } = req.body;
    if (!mascota_id || !veterinario_id || !fecha_hora) {
        return res.status(400).json({ error: 'mascota_id, veterinario_id y fecha_hora son requeridos.' });
    }
    const fechaDate = new Date(fecha_hora);
    if (isNaN(fechaDate.getTime())) {
        return res.status(400).json({ error: 'fecha_hora no es una fecha valida.' });
    }

    let client;
    try {
        client = await getDbClient(req.session);
        await client.query(
            `CALL sp_agendar_cita($1, $2, $3, $4, NULL)`,
            [+mascota_id, +veterinario_id, fechaDate.toISOString(), motivo || null]
        );
        res.status(201).json({ ok: true, message: 'Cita agendada correctamente.' });
        await releaseClient(client, false);
    } catch (err) {
        console.error('[ERROR] POST /api/citas:', err.message);
        res.status(400).json({ ok: false, error: err.message });
        await releaseClient(client, true);
    }
});

// ---- GET /api/citas -------------------------------------------
app.get('/api/citas', async (req, res) => {
    let client;
    try {
        client = await getDbClient(req.session);
        const result = await client.query(`SELECT * FROM v_citas_detalle`);
        res.json({ ok: true, data: result.rows });
        await releaseClient(client, false);
    } catch (err) {
        console.error('[ERROR] GET /api/citas:', err.message);
        res.status(500).json({ ok: false, error: err.message });
        await releaseClient(client, true);
    }
});

// ---- GET /api/veterinarios ------------------------------------
app.get('/api/veterinarios', async (req, res) => {
    try {
        const result = await pool.query(
            `SELECT id, nombre, cedula, dias_descanso, activo FROM veterinarios ORDER BY nombre`
        );
        res.json({ ok: true, data: result.rows });
    } catch (err) {
        res.status(500).json({ ok: false, error: err.message });
    }
});

// ---- GET /api/inventario-vacunas ------------------------------
app.get('/api/inventario-vacunas', async (req, res) => {
    let client;
    try {
        client = await getDbClient(req.session);
        const result = await client.query(
            `SELECT id, nombre, stock_actual, stock_minimo, costo_unitario FROM inventario_vacunas ORDER BY nombre`
        );
        res.json({ ok: true, data: result.rows });
        await releaseClient(client, false);
    } catch (err) {
        res.status(500).json({ ok: false, error: err.message });
        await releaseClient(client, true);
    }
});

// ---- POST /api/auth/login -------------------------------------
app.post('/api/auth/login', async (req, res) => {
    const { usuario, password } = req.body;

    const usuarios = {
        'vet_lopez':         { role: 'veterinario', vetId: 1, nombre: 'Dr. Fernando Lopez Castro' },
        'vet_garcia':        { role: 'veterinario', vetId: 2, nombre: 'Dra. Sofia Garcia Velasco' },
        'vet_mendez':        { role: 'veterinario', vetId: 3, nombre: 'Dr. Andres Mendez Bravo' },
        'usuario_recepcion': { role: 'recepcion',   vetId: null, nombre: 'Personal de Recepcion' },
        'usuario_admin':     { role: 'admin',        vetId: null, nombre: 'Administrador' },
    };
    const passwordMap = {
        'vet_lopez':         'vet_lopez_pass',
        'vet_garcia':        'vet_garcia_pass',
        'vet_mendez':        'vet_mendez_pass',
        'usuario_recepcion': 'recepcion_pass',
        'usuario_admin':     'admin_pass',
    };

    if (!usuarios[usuario] || passwordMap[usuario] !== password) {
        return res.status(401).json({ ok: false, error: 'Credenciales invalidas.' });
    }

    const session = usuarios[usuario];
    res.json({
        ok: true,
        role:   session.role,
        vetId:  session.vetId,
        nombre: session.nombre,
        token:  Buffer.from(JSON.stringify(session)).toString('base64'),
    });
});

// =============================================================
const PORT = process.env.PORT || 3001;
app.listen(PORT, () => {
    console.log(`[SERVER] Clinica Vet API corriendo en http://localhost:${PORT}`);
    console.log(`[SERVER] FIX: BEGIN abierto antes de set_vet_context para que SET LOCAL persista`);
});

module.exports = app;