// =============================================================
// api/cache.js — Cliente Redis
//
// Estrategia: cache-aside (lazy loading)
//   1. El endpoint intenta leer de Redis primero.
//   2. Si hay HIT: devuelve datos cacheados (latencia ~5-20ms).
//   3. Si hay MISS: consulta BD, guarda en Redis con TTL, devuelve.
//   4. Al escribir datos nuevos (POST vacuna): invalidar clave.
//
// TTL: 300 segundos (5 minutos).
// Justificación: la vista v_mascotas_vacunacion_pendiente es cara
// (~100-300ms en BD) pero sus datos solo cambian cuando se aplica
// una vacuna. 5 min es un equilibrio entre frescura y rendimiento.
// Si fuera demasiado bajo (ej. 5s), casi nunca habría cache HIT
// y el Redis no aportaría valor. Si fuera demasiado alto (ej. 1h),
// habría un periodo largo con datos obsoletos si alguien vacuna.
// La invalidación explícita resuelve el problema de datos obsoletos.
// =============================================================

const { createClient } = require('redis');

let redisClient = null;
let redisConnected = false;

async function getRedisClient() {
    if (redisClient && redisConnected) return redisClient;

    redisClient = createClient({
        url: process.env.REDIS_URL || 'redis://localhost:6379',
    });

    redisClient.on('error', (err) => {
        console.error('[REDIS ERROR]', err.message);
        redisConnected = false;
    });

    redisClient.on('connect', () => {
        console.log('[REDIS] Conexión establecida');
        redisConnected = true;
    });

    redisClient.on('reconnecting', () => {
        console.log('[REDIS] Reconectando...');
    });

    await redisClient.connect();
    redisConnected = true;
    return redisClient;
}

/**
 * Intenta obtener un valor del caché.
 * @returns {any|null} - Datos parseados o null si no hay hit
 */
async function getCache(key) {
    try {
        const client = await getRedisClient();
        const raw = await client.get(key);
        if (raw === null) return null;
        return JSON.parse(raw);
    } catch (err) {
        console.error(`[CACHE] Error al leer clave "${key}":`, err.message);
        return null; // Degraded mode: si Redis falla, seguimos sin caché
    }
}

/**
 * Guarda un valor en caché con TTL en segundos.
 */
async function setCache(key, data, ttlSeconds = 300) {
    try {
        const client = await getRedisClient();
        await client.setEx(key, ttlSeconds, JSON.stringify(data));
        console.log(`[CACHE SET] "${key}" guardado con TTL=${ttlSeconds}s`);
    } catch (err) {
        console.error(`[CACHE] Error al escribir clave "${key}":`, err.message);
        // No lanzar — si Redis falla, la request sigue siendo válida
    }
}

/**
 * Elimina una clave del caché (invalidación explícita).
 */
async function deleteCache(key) {
    try {
        const client = await getRedisClient();
        const deleted = await client.del(key);
        if (deleted > 0) {
            console.log(`[CACHE DEL] "${key}" eliminado del caché (invalidación explícita)`);
        }
    } catch (err) {
        console.error(`[CACHE] Error al eliminar clave "${key}":`, err.message);
    }
}

// Inicializar conexión al arrancar
getRedisClient().catch(err => {
    console.warn('[REDIS] No se pudo conectar al inicio:', err.message);
    console.warn('[REDIS] La API funcionará sin caché hasta que Redis esté disponible.');
});

module.exports = { getCache, setCache, deleteCache };
